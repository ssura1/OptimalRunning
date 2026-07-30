import Foundation
import Observation
import ORAlerts
import ORColor
import ORIntervals
import ORModels
import ORPace

/// Why a standalone run refused to start.
public enum StandaloneRunRefusal: Error, Equatable, Sendable {
    /// DEG-6, refused *before* recording anything.
    case insufficientStorage(freeBytesRequired: Int64)
    case alreadyRunning
    /// AC-FR-S-A-1-6 — neither location nor motion is available, so there is nothing to
    /// measure a paced run with. Named rather than generic so the message can say what is
    /// needed and why.
    case noSensorsAuthorized
}

public enum StandaloneRunPhase: String, Sendable, Hashable {
    case idle
    case running
    case paused
    case ended
}

/// Owns the feed, the engine, the store, the cue channel and the haptics for one
/// standalone run (S-032).
///
/// **What this type does not do.** It computes no zone, no colour, no alert timing, no step
/// transition, no grade adjustment, and no distance. Every one of those arrives from
/// `RunEngine` in a single `EngineOutput`, or from the feed in a single `MotionTelemetry`.
/// Its job is to move them to the screen, the store, the speaker and the Taptic Engine.
///
/// **And what it deliberately cannot see.** There is no `import PhoneMotion` here and there
/// could not be — `Tools/check-phonemotion-isolation.sh` fails the build on one. That is
/// the point of the whole arrangement: when S-063 changes the amplitude exponent and S-064
/// fixes the calibration over-read, the numbers this class publishes change and this file
/// does not. The acceptance test for that claim swaps the estimator's configuration and
/// asserts exactly it.
///
/// `@MainActor` because SwiftUI observes it and because the alternative — a class mutated
/// from a sensor callback thread — is the classic source of torn reads on a screen
/// refreshing at 1 Hz.
@MainActor
@Observable
public final class StandaloneRunController {

    // MARK: Rendered state

    public private(set) var phase: StandaloneRunPhase = .idle
    public private(set) var output: EngineOutput?
    public private(set) var telemetry: MotionTelemetry = .empty
    public private(set) var screen: StandaloneMetricsScreen?
    public private(set) var samplesRecorded = 0
    /// Set when the workout finished on its own, so the UI can go to the summary rather
    /// than waiting for a manual End.
    public private(set) var didCompleteWorkout = false
    /// AC-FR-S-A-4-4 — Health was not written, and the runner is told rather than left to
    /// discover it.
    public private(set) var healthKitWriteDeclined = false

    public let plan: WorkoutPlan
    public let activity: RunActivityKind
    public private(set) var profile: RunnerProfile

    // MARK: Collaborators

    private let configuration: PaceEngineConfiguration
    private let feed: any RunSensorFeed
    private let store: StandaloneSampleStore
    private let cues: any CueSpeaking
    private let haptics: any HapticPlaying
    private let workout: any StandaloneWorkoutWriting
    private let calibrationStore: any CalibrationStoring
    private let carryPosition: CarryPosition
    private let appVersion: String
    private let now: @Sendable () -> Date

    private var engine: RunEngine
    private var splits: SplitAnnouncer

    // MARK: Run state

    private var isPaused = false
    private var pendingManualAdvance = false
    private var lastTimestamp: TimeInterval = 0
    private var runID = UUID()
    private var startedAt = Date()
    private var outputs: [EngineOutput] = []
    private var route: [RoutePoint] = []
    private var stepMarks: [WorkoutEventMark] = []
    /// AC-FR-S-C-3-3 — the GNSS notice is said *once* at each transition, not repeatedly.
    /// Held here rather than in the composer because "has this already been said" is run
    /// state, and the composer is a pure function of one event.
    private var wasGPSDegraded = false

    public init(
        plan: WorkoutPlan,
        activity: RunActivityKind = .outdoorRun,
        profile: RunnerProfile,
        configuration: PaceEngineConfiguration = .default,
        feed: any RunSensorFeed,
        store: StandaloneSampleStore,
        cues: any CueSpeaking,
        haptics: any HapticPlaying,
        workout: any StandaloneWorkoutWriting,
        calibrationStore: any CalibrationStoring,
        carryPosition: CarryPosition = .handHeld,
        appVersion: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.plan = plan
        self.activity = activity
        self.profile = profile
        self.configuration = configuration
        self.feed = feed
        self.store = store
        self.cues = cues
        self.haptics = haptics
        self.workout = workout
        self.calibrationStore = calibrationStore
        self.carryPosition = carryPosition
        self.appVersion = appVersion
        self.now = now
        self.engine = RunEngine(configuration: configuration, plan: plan, profile: profile)
        self.splits = SplitAnnouncer(profile: profile)
    }

    // MARK: - Lifecycle

    /// Starts a run, or refuses it.
    ///
    /// The storage check happens *first*, before authorization and before any sensor, for
    /// the reason DEG-6 exists: a doomed run must never begin.
    public func start() async throws {
        guard phase == .idle else { throw StandaloneRunRefusal.alreadyRunning }

        let required = configuration.capture.minimumFreeBytesToStart
        guard store.hasSufficientStorage(minimumBytes: required) else {
            throw StandaloneRunRefusal.insufficientStorage(freeBytesRequired: required)
        }

        runID = UUID()
        startedAt = now()
        outputs.removeAll()
        route.removeAll()
        stepMarks.removeAll()
        samplesRecorded = 0
        didCompleteWorkout = false
        wasGPSDegraded = false
        store.startRun(runID: runID, startedAt: startedAt, runType: plan.runType)

        // AC-FR-S-A-4-4: a declined write is a handled state. The run starts either way —
        // refusing to record because Health said no would lose the run to a permission the
        // run does not need.
        healthKitWriteDeclined = await workout.requestAuthorization() == .denied

        // Delivered synchronously on the main actor — `RunSensorFeed` is `@MainActor`
        // precisely so ticks cannot reorder on their way here.
        feed.onSample = { [weak self] input in self?.ingest(input) }
        // `let`, not `var`: `MotionTelemetryReporting` refines a class-bound protocol, so
        // this binds the reference and the assignment reaches the object rather than a copy.
        if let reporting = feed as? any MotionTelemetryReporting {
            reporting.onTelemetry = { [weak self] telemetry in self?.ingest(telemetry) }
        }
        try feed.start(activity: activity)
        phase = .running
    }

    /// One tick. Everything the run does, in the order it must happen.
    public func ingest(_ input: EngineInput) {
        guard phase == .running || phase == .paused else { return }

        let merged = merge(input)
        lastTimestamp = merged.timestamp
        pendingManualAdvance = false

        let out = engine.tick(merged)
        output = out
        outputs.append(out)
        samplesRecorded += 1

        if let location = merged.location {
            route.append(RoutePoint(
                timestamp: location.timestamp,
                latitude: location.latitude,
                longitude: location.longitude,
                altitudeMetres: location.altitudeMetres))
        }

        if let transition = out.stepTransition, let next = transition.to {
            stepMarks.append(WorkoutEventMark(
                atSeconds: transition.atActiveElapsed,
                kind: next.kind,
                repIndex: next.repIndex,
                repCount: next.repCount))
        }

        if let alert = out.alert { deliver(alert) }
        announceGNSSTransitionIfNeeded(out)

        // Splits are their own channel and are evaluated even while a pace alert fired on
        // the same tick (ADR-S-05) — a mile boundary does not wait for a cooldown.
        if !isPaused {
            for cue in splits.tick(
                cumulativeDistance: out.cumulativeDistance,
                activeElapsed: out.activeElapsed,
                averagePace: out.averagePace)
            {
                deliver(cue)
            }
        }

        // The facts go in on **every** tick, not at the end.
        //
        // Writing them in `end()` was the first version and it was useless: `finalizeRun()`
        // deletes the in-progress file, so facts written just before it are written to a
        // file about to be removed. The only reader of that file is orphan recovery — which
        // by definition happens when `end()` was never reached — so the facts have to be
        // current at every flush or they are never there when they are wanted.
        store.append(
            out.sample,
            routePoint: route.last,
            facts: makeFacts(),
            flushIntervalSeconds: configuration.capture.flushIntervalSeconds)

        rebuildScreen()
        if case .workoutComplete = out.alert { didCompleteWorkout = true }
    }

    /// Telemetry for the same tick, delivered after the sample.
    public func ingest(_ incoming: MotionTelemetry) {
        telemetry = incoming
        rebuildScreen()
    }

    public func pause() async {
        guard phase == .running else { return }
        isPaused = true
        phase = .paused
        feed.pause()
        // A pause flushes rather than waiting out the interval: pausing is the most likely
        // moment for a runner to also leave the app, and the samples up to here are
        // already earned.
        store.flush()
    }

    public func resume() async {
        guard phase == .paused else { return }
        isPaused = false
        phase = .running
        feed.resume()
    }

    /// Ends the run, tears down every resource, writes the workout, and returns the
    /// envelope for the hub to ingest.
    ///
    /// Order matters and is the reason this is not five lines. The feed stops first so no
    /// tick can arrive mid-teardown; the cue channel stops next so nothing is spoken into a
    /// session about to be deactivated (AC-FR-S-A-2-3); the calibration is persisted before
    /// anything that can throw, because a learned calibration is the most expensive thing
    /// in the run to reacquire; the store is finalized so the next launch sees no orphan;
    /// and only then is HealthKit written, which is the one step allowed to fail without
    /// costing the run.
    @discardableResult
    public func end() async throws -> RunEnvelope? {
        guard phase == .running || phase == .paused else { return nil }

        feed.onSample = nil
        if let reporting = feed as? any MotionTelemetryReporting { reporting.onTelemetry = nil }
        _ = try? await feed.stop()

        cues.stop()
        engine.end()
        phase = .ended

        if let calibrating = feed as? any CalibrationProducing {
            calibrationStore.saveCalibration(
                calibrating.calibrationPayload, for: carryPosition)
        }

        store.finalizeRun()

        guard !outputs.isEmpty else { return nil }

        var healthKitUUID: UUID?
        if !healthKitWriteDeclined {
            healthKitUUID = try? await workout.save(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(lastTimestamp),
                distanceMetres: outputs.last?.cumulativeDistance ?? 0,
                activeSeconds: outputs.last?.activeElapsed ?? 0,
                route: route,
                events: stepMarks)
        }

        return StandaloneWorkoutComposer.build(
            runID: runID,
            outputs: outputs,
            telemetry: telemetry,
            startedAt: startedAt,
            runType: plan.runType,
            plan: plan.runType.isStructured ? plan : nil,
            profile: profile,
            configuration: configuration,
            activity: activity,
            route: activity == .outdoorRun ? route : nil,
            healthKitWorkoutUUID: healthKitUUID,
            carryPosition: carryPosition,
            averageCadenceStepsPerMinute: averageCadence,
            estimatedSpans: estimatedSpans,
            appVersion: appVersion)
    }

    // MARK: - Interaction

    /// A tap on the run screen. Only open-goal steps advance, and that decision is
    /// `Core`'s — a tap on a closed step is deliberately inert rather than disabled, so a
    /// mistaken tap does nothing instead of ending a rep early (AC-FR-C-3-4).
    public func requestManualAdvance() {
        guard let output, output.step.canAdvanceManually else { return }
        pendingManualAdvance = true
    }

    @discardableResult
    public func undoManualAdvance() -> Bool {
        engine.undoManualAdvance()
    }

    /// Applies a settings change mid-run. The engine is rebuilt only for changes it
    /// actually reads; a palette, unit or cue-preference change is presentation and must
    /// not discard the run's accumulated engine state.
    public func apply(profile updated: RunnerProfile) {
        let engineAffecting = updated.paceHapticsEnabled != profile.paceHapticsEnabled
            || updated.basePace(for: plan.runType) != profile.basePace(for: plan.runType)
        profile = updated
        if engineAffecting, phase == .idle {
            engine = RunEngine(configuration: configuration, plan: plan, profile: updated)
        }
        rebuildScreen()
    }

    // MARK: - Private

    /// Folds this class's control flags into the feed's measurement-only input.
    ///
    /// Pause and manual advance are *user* facts, not sensor facts: they originate in the
    /// UI, and a feed that reported them would have to be told by this class first and then
    /// asked back. It also keeps the fake feed in tests honest — it cannot accidentally
    /// satisfy a pause assertion it knows nothing about.
    private func merge(_ input: EngineInput) -> EngineInput {
        EngineInput(
            timestamp: input.timestamp,
            cumulativeDistance: input.cumulativeDistance,
            location: input.location,
            relativeAltitude: input.relativeAltitude,
            heartRate: input.heartRate,
            isPaused: isPaused,
            manualAdvanceRequested: pendingManualAdvance,
            distanceSource: input.distanceSource)
    }

    /// Takes no timestamp, deliberately.
    ///
    /// Every timing question — has the runner dwelt long enough, is this a nag, is this run
    /// type one that judges pace at all — was answered by `AlertPolicy` inside `RunEngine`,
    /// which suppresses the alert at source. An `AlertCommand` arriving here has already
    /// earned the right to fire, and a clock on this side would be the beginning of a second
    /// policy (ADR-S-05).
    private func deliver(_ alert: AlertCommand) {
        guard let cue = CueComposer.cue(
            for: alert, runType: plan.runType, unit: profile.units)
        else { return }
        deliver(cue)
    }

    /// The one place a cue reaches hardware, so the two channels cannot get out of step.
    ///
    /// Speech and haptics are gated independently and neither gate is the other's: turning
    /// off spoken cues leaves haptics a complete channel (AC-FR-S-D-1-7), and turning off
    /// pace haptics leaves interval haptics working (AC-FR-S-D-2-4). Both switches are
    /// read here rather than at the composer, so a disabled channel still *composes* its
    /// cue — which is what makes "would this have been said?" testable independently of
    /// whether it was.
    private func deliver(_ cue: SpokenCue) {
        if StandaloneHaptics.permits(cue, runType: plan.runType, profile: profile) {
            haptics.play(StandaloneHaptics.pattern(for: cue))
        }
        guard profile.spokenCuesEnabled else { return }
        if case .split = cue.kind, !profile.splitAnnouncementsEnabled { return }
        cues.speak(cue)
    }

    /// AC-FR-S-C-3-3 — said once at the transition, in each direction, and never again
    /// until the state changes back.
    private func announceGNSSTransitionIfNeeded(_ out: EngineOutput) {
        guard activity == .outdoorRun else { return }
        guard out.isGPSDegraded != wasGPSDegraded else { return }
        wasGPSDegraded = out.isGPSDegraded
        // Nothing is announced for the very first tick of a run that has not acquired a
        // fix yet: "GPS signal lost" before it has ever been found is a confusing way to
        // say "still looking", and DEG-S-2 is the start-of-run message's job instead.
        guard out.activeElapsed > 0 else { return }
        deliver(out.isGPSDegraded ? CueComposer.gnssLost() : CueComposer.gnssRestored())
    }

    private func rebuildScreen() {
        guard let output else { return }
        screen = StandaloneMetricsScreen.make(
            output: output,
            telemetry: telemetry,
            runType: plan.runType,
            profile: profile,
            activity: activity)
    }

    private var averageCadence: Double? {
        (feed as? any CalibrationProducing)?.averageCadenceStepsPerMinute
    }

    private var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] {
        (feed as? any CalibrationProducing)?.estimatedSpans ?? []
    }

    private func makeFacts() -> StandaloneRunFacts {
        StandaloneRunFacts(
            carryPosition: carryPosition,
            measuredMetres: telemetry.measuredMetres,
            estimatedMetres: telemetry.estimatedMetres,
            stepCount: telemetry.stepCount,
            averageCadenceStepsPerMinute: averageCadence,
            calibration: telemetry.calibration,
            flags: telemetry.flags,
            estimatedSpans: estimatedSpans)
    }
}

/// The run-scoped facts a motion feed accumulates and hands over at the end.
///
/// Separate from `MotionTelemetryReporting` because these are whole-run totals read once,
/// not a per-tick stream — and because a feed that reports telemetry live but has no
/// calibration to persist (a future GNSS-only variant, say) is a coherent thing to be.
@MainActor
public protocol CalibrationProducing: AnyObject {
    /// Opaque bytes. See `CalibrationStoring` for why the shape is not named here.
    var calibrationPayload: Data? { get }
    var averageCadenceStepsPerMinute: Double? { get }
    var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] { get }
}
