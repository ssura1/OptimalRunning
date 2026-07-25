import Foundation
import Observation
import ORAlerts
import ORColor
import ORIntervals
import ORModels
import ORPace

/// Why a run refused to start.
public enum RunStartRefusal: Error, Equatable, Sendable {
    /// DEG-6: not enough free space, refused *before* recording anything.
    case insufficientStorage(freeBytesRequired: Int64)
    case alreadyRunning
}

/// The state a run screen renders from.
public enum RunPhase: String, Sendable, Hashable {
    case idle
    case running
    case paused
    case ended
}

/// Owns the feed, the engine, the sample store, and the workout session for one run,
/// and exposes the rendered screen to SwiftUI (T-037).
///
/// **What this type does not do.** It computes no zone, no colour, no alert timing, no
/// step transition, and no grade adjustment. Every one of those arrives from
/// `RunEngine` inside a single `EngineOutput`, and this class's job is to move it to
/// the screen, the store, and the haptic engine. The rule from ADR-001 restated at the
/// tier boundary: sensor events in, `Core` value types out, `Core`'s answers rendered.
///
/// `@MainActor` because SwiftUI observes it and because the alternative — a class
/// mutated from a sensor callback thread — is the classic source of torn reads on a
/// screen refreshing at 1 Hz. Sensor callbacks hop here; nothing else needs to.
@MainActor
@Observable
public final class RunSessionModel {

    // MARK: Rendered state

    public private(set) var phase: RunPhase = .idle
    public private(set) var output: EngineOutput?
    public private(set) var screen: MetricsScreen?
    public private(set) var presentation: AlertPresentation?
    /// Set when the workout finished on its own (the plan ran out), so the UI can go
    /// to the summary rather than waiting for a manual End.
    public private(set) var didCompleteWorkout = false

    /// Driven by the view's `isLuminanceReduced` environment value. Assigning it
    /// re-renders the screen with dimmed swatches immediately, rather than at the
    /// next sensor tick — a wrist raise must not wait up to a second to brighten.
    public var luminance: LuminanceState = .normal {
        didSet {
            guard luminance != oldValue else { return }
            rebuildScreen()
            // A warning that was up when the wrist dropped is dismissed, not held
            // (AC-FR-B-2-5).
            presenter.tick(now: lastTimestamp, isLuminanceReduced: luminance == .dimmed)
            presentation = presenter.visible
        }
    }

    public let plan: WorkoutPlan
    public private(set) var profile: RunnerProfile
    public private(set) var samplesRecorded = 0

    // MARK: Collaborators

    private let configuration: PaceEngineConfiguration
    private let feed: RunSensorFeed
    private let store: SampleStore
    private let session: WorkoutSessionController
    private let haptics: HapticPlaying

    private var engine: RunEngine
    private var presenter: AlertPresenter

    /// Control flags this model owns rather than the feed.
    ///
    /// Pause and manual-advance are *user* facts, not sensor facts: they originate in
    /// the UI, and a feed that reported them would have to be told by this class
    /// first, then asked back. So the feed reports only what it measures, and these
    /// are merged into each `EngineInput` on arrival. It also keeps the fake feed in
    /// tests honest — it cannot accidentally satisfy a pause assertion it knows
    /// nothing about.
    private var isPaused = false
    private var pendingManualAdvance = false
    private var lastTimestamp: TimeInterval = 0
    private var runID = UUID()

    public init(
        plan: WorkoutPlan,
        profile: RunnerProfile,
        configuration: PaceEngineConfiguration = .default,
        feed: RunSensorFeed,
        store: SampleStore,
        session: WorkoutSessionController,
        haptics: HapticPlaying
    ) {
        self.plan = plan
        self.profile = profile
        self.configuration = configuration
        self.feed = feed
        self.store = store
        self.session = session
        self.haptics = haptics
        self.engine = RunEngine(configuration: configuration, plan: plan, profile: profile)
        self.presenter = AlertPresenter(config: configuration.presentation)
    }

    // MARK: - Lifecycle

    /// Starts a run, or refuses it.
    ///
    /// The storage check happens *first*, before authorization and before the session,
    /// because DEG-6's whole point is that a doomed run must never begin. Failing at
    /// minute forty with a full disk loses the run; refusing at second zero loses
    /// nothing but the runner's patience.
    public func start(activity: RunActivityKind) async throws {
        guard phase == .idle else { throw RunStartRefusal.alreadyRunning }

        let required = configuration.capture.minimumFreeBytesToStart
        guard store.hasSufficientStorage(minimumBytes: required) else {
            throw RunStartRefusal.insufficientStorage(freeBytesRequired: required)
        }

        runID = UUID()
        store.startRun(runID: runID)
        try await session.start(locationType: activity == .indoorRun ? .indoor : .outdoor, now: 0)

        // Delivered synchronously on the main actor — `RunSensorFeed` is `@MainActor`
        // precisely so ticks cannot reorder on their way here.
        feed.onSample = { [weak self] input in self?.ingest(input) }
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
        // Synchronous, and that is load-bearing: the session's clock and the engine's
        // must see the same tick sequence in the same order or their active-time
        // figures diverge (AC-FR-D-1-3).
        session.tick(now: merged.timestamp)

        store.append(out.sample, flushIntervalSeconds: configuration.capture.flushIntervalSeconds)
        samplesRecorded += 1

        if let alert = out.alert { deliver(alert, at: out.activeElapsed) }

        presenter.tick(now: out.activeElapsed, isLuminanceReduced: luminance == .dimmed)
        presentation = presenter.visible
        rebuildScreen()

        if case .workoutComplete = out.alert { didCompleteWorkout = true }
    }

    public func pause() async {
        guard phase == .running else { return }
        isPaused = true
        phase = .paused
        feed.pause()
        await session.pause(now: lastTimestamp)
        // A pause flushes rather than waiting out the interval: pausing is the most
        // likely moment for a runner to also stop the app, and the samples up to here
        // are already earned.
        store.flush()
    }

    public func resume() async {
        guard phase == .paused else { return }
        isPaused = false
        phase = .running
        feed.resume()
        await session.resume(now: lastTimestamp)
    }

    /// Ends the run and tears down every resource (NFR-8).
    ///
    /// Order matters and is the reason this is not three lines: the feed stops first so
    /// no tick can arrive mid-teardown, then the engine closes its step machine, then
    /// the store is finalized so the next launch does not see an orphan, and only then
    /// is the HealthKit session saved. A save that throws must still leave the feed
    /// stopped — hence `defer`-free explicit ordering with the throwing call last.
    @discardableResult
    public func end() async throws -> RunSummary? {
        guard phase == .running || phase == .paused else { return nil }

        feed.onSample = nil
        let summary = try? await feed.stop()

        engine.end()
        store.finalizeRun()
        presenter.reset()
        presentation = nil
        phase = .ended

        _ = try await session.end(now: lastTimestamp)
        return summary
    }

    // MARK: - Interaction

    /// A tap on the metrics page (AC-FR-C-3). Only open-goal steps advance, and that
    /// decision is `Core`'s — a tap on a closed step is deliberately inert rather than
    /// disabled, so a mistaken tap does nothing instead of ending a rep early.
    public func requestManualAdvance() {
        guard let output, IntervalPresentation.tapAdvances(output.step) else { return }
        pendingManualAdvance = true
    }

    /// FR-C-6. Returns whether anything was undone, so the UI can avoid flashing an
    /// affordance for a no-op.
    @discardableResult
    public func undoManualAdvance() -> Bool {
        engine.undoManualAdvance()
    }

    /// Tap or crown rotation on a warning screen (CON-1: never a crown press).
    public func dismissPresentation() {
        presenter.dismiss()
        presentation = nil
    }

    /// Applies a settings change mid-run. The engine is rebuilt only for changes it
    /// actually reads; a palette or unit change is pure presentation and must not
    /// discard the run's accumulated engine state.
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
    private func merge(_ input: EngineInput) -> EngineInput {
        EngineInput(
            timestamp: input.timestamp,
            cumulativeDistance: input.cumulativeDistance,
            location: input.location,
            relativeAltitude: input.relativeAltitude,
            heartRate: input.heartRate,
            isPaused: isPaused,
            manualAdvanceRequested: pendingManualAdvance,
            distanceSource: input.distanceSource
        )
    }

    private func deliver(_ alert: AlertCommand, at now: TimeInterval) {
        guard HapticDispatcher.permits(alert, runType: plan.runType) else { return }
        haptics.play(HapticDispatcher.pattern(for: alert))
        presenter.offer(
            alert,
            now: now,
            isLuminanceReduced: luminance == .dimmed,
            unit: profile.units
        )
    }

    private func rebuildScreen() {
        guard let output else { return }
        screen = MetricsScreen.make(
            output: output,
            runType: plan.runType,
            profile: profile,
            luminance: luminance,
            presentation: configuration.presentation
        )
    }
}
