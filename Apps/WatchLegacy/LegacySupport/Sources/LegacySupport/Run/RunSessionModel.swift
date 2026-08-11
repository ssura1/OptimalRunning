import Combine
import Foundation
import ORAlerts
import ORIntervals
import ORModels
import ORPace
import ORStats

/// The run screen's state, driven by one `EngineOutput` per tick — Legacy tier (T-065, FR-D-1,
/// FR-D-2, FR-D-6).
///
/// ## `ObservableObject`, not `@Observable`
///
/// The tier matrix's first row (design.md §8.1). `@Observable` requires watchOS 10; this tier
/// targets watchOS 8, so observation is `ObservableObject` + `@Published` and SwiftUI subscribes via
/// `@ObservedObject`. That is a genuine platform divergence, not a stylistic one, and it is the
/// reason `LegacySupport`'s manifest declares a watchOS 8 floor while `WatchSupport` declares 10.
///
/// The practical difference to watch for: `@Published` fires on *every* assignment, whereas
/// `@Observable` tracks which properties a view actually reads. On a 1 Hz update loop feeding the
/// slowest supported hardware (NFR-1, NFR-2), that distinction is a real frame-budget risk — so the
/// published surface here is one aggregate `screen` value rather than a dozen individual metrics,
/// and it is only assigned when it changes.
///
/// `@MainActor` for the same tick-ordering reason `WorkoutSessionController` is: `ActiveClock`
/// over-counts active time when two ticks arrive out of order, so ingestion must be a synchronous
/// call that cannot reorder.
@MainActor
public final class RunSessionModel: ObservableObject {

    public enum Phase: Sendable, Hashable {
        case idle
        /// Refused before starting because the volume is too full (DEG-6).
        case refusedInsufficientStorage
        case running
        case paused
        case finished
    }

    // MARK: Published surface

    @Published public private(set) var phase: Phase = .idle
    /// The whole metrics page as one value. See the note above on `@Published` granularity.
    @Published public private(set) var screen: MetricsScreen?
    @Published public private(set) var alert: AlertPresentation?
    /// A run left behind by a previous launch, awaiting save-or-discard (DEG-7).
    @Published public private(set) var orphan: SampleStore.OrphanedRun?

    // MARK: Collaborators

    private let store: SampleStore
    private let session: WorkoutSessionController
    private let haptics: HapticPlaying
    private let config: PaceEngineConfiguration
    private var presenter: AlertPresenter

    private var engine: RunEngine?
    private var accumulator = StepSummaryAccumulator()
    private var plan: WorkoutPlan?
    private var profile: RunnerProfile?
    private var runID: UUID?
    private var samples: [RunSample] = []
    private var zones: [PaceZone] = []
    /// The run's path, for the Health workout's map ([legacy] T-107). `RunSample` carries
    /// distance but no coordinates, so without this the route is unrecoverable after the
    /// fact — which is why this tier has never written one.
    private var route: [RoutePoint] = []
    private var lastOutput: EngineOutput?

    /// Whether the display is on. Series 3 has no dimmed state — the screen is on or off — so this
    /// is driven by the extension's active/inactive lifecycle. See `AlertPresenter`.
    public var isScreenVisible = true

    public init(
        store: SampleStore,
        session: WorkoutSessionController,
        haptics: HapticPlaying,
        config: PaceEngineConfiguration = .default
    ) {
        self.store = store
        self.session = session
        self.haptics = haptics
        self.config = config
        self.presenter = AlertPresenter(config: config.presentation)
    }

    // MARK: - Orphan recovery (DEG-7)

    /// Called once at launch, before any run starts.
    public func checkForOrphanedRun() {
        orphan = store.detectOrphan()
    }

    /// Returns the recovered samples so the caller can build an envelope from them, then clears the
    /// marker. Returning them rather than uploading here keeps this type free of transport.
    public func recoverOrphan() -> [RunSample]? {
        guard let orphan else { return nil }
        let recovered = store.loadOrphan(runID: orphan.runID)
        store.discardOrphan(runID: orphan.runID)
        self.orphan = nil
        return recovered
    }

    public func discardOrphan() {
        guard let orphan else { return }
        store.discardOrphan(runID: orphan.runID)
        self.orphan = nil
    }

    // MARK: - Lifecycle

    /// Starts a run, or refuses it.
    ///
    /// The storage check happens *before* anything else (DEG-6, AC-FR-D-6): refusing up front is the
    /// difference between "not today" and a run that dies at minute 40 with the data already lost.
    /// Series 3's 8 GB makes this a realistic path rather than a defensive one.
    public func start(
        plan: WorkoutPlan,
        profile: RunnerProfile,
        activity: RunActivityKind,
        now: TimeInterval = 0
    ) async throws {
        guard store.hasSufficientStorage(minimumBytes: config.capture.minimumFreeBytesToStart) else {
            phase = .refusedInsufficientStorage
            return
        }

        let runID = UUID()
        self.runID = runID
        self.plan = plan
        self.profile = profile
        self.engine = RunEngine(configuration: config, plan: plan, profile: profile)
        self.accumulator = StepSummaryAccumulator()
        self.samples = []
        self.zones = []
        self.presenter.reset()

        store.startRun(runID: runID)
        try await session.start(
            locationType: activity == .indoorRun ? .indoor : .outdoor, now: now
        )
        phase = .running
    }

    /// One tick. The single entry point for engine output — everything published flows from here.
    public func ingest(_ input: EngineInput) {
        guard phase == .running || phase == .paused, var engine, let profile, let plan else { return }

        let output = engine.tick(input)
        self.engine = engine
        lastOutput = output

        if let location = input.location {
            route.append(RoutePoint(
                timestamp: input.timestamp,
                latitude: location.latitude,
                longitude: location.longitude,
                altitudeMetres: location.altitudeMetres
            ))
        }

        session.tick(now: input.timestamp)
        record(output, plan: plan, profile: profile)
    }

    /// Applies one already-computed output. Separated from `ingest` so a replay-driven test can push
    /// engine output through the exact publishing path the app uses.
    func record(_ output: EngineOutput, plan: WorkoutPlan, profile: RunnerProfile) {
        samples.append(output.sample)
        zones.append(output.zone)
        store.append(output.sample, flushIntervalSeconds: config.capture.flushIntervalSeconds)

        accumulator.ingest(output)

        // Step boundaries become HKWorkoutEvent(.segment) — this tier's stand-in for Modern's native
        // activity segmentation (AC-FR-D-1-6). The engine decides where they fall; this only relays.
        if output.stepTransition != nil {
            let now = output.sample.timestamp
            Task { await session.markStepBoundary(now: now) }
        }

        if let command = output.alert,
           HapticDispatcher.permits(command, runType: plan.runType) {
            haptics.play(HapticDispatcher.pattern(for: command))
            presenter.offer(
                command, now: output.sample.timestamp,
                isScreenVisible: isScreenVisible, unit: profile.units
            )
        }
        presenter.tick(now: output.sample.timestamp, isScreenVisible: isScreenVisible)

        let next = MetricsScreen.make(output: output, runType: plan.runType, profile: profile)
        if next != screen { screen = next }
        if presenter.visible != alert { alert = presenter.visible }
    }

    public func pause(now: TimeInterval) async {
        guard phase == .running else { return }
        phase = .paused
        await session.pause(now: now)
        // Flush on pause rather than waiting for the interval: a pause is the most likely moment for
        // the app to be backgrounded and killed.
        store.flush()
    }

    public func resume(now: TimeInterval) async {
        guard phase == .paused else { return }
        phase = .running
        await session.resume(now: now)
    }

    /// Ends the run and returns its summary plus per-step table, for the envelope builder.
    @discardableResult
    public func end(now: TimeInterval) async throws -> (summary: RunSummary, steps: [StepSummary]) {
        accumulator.finish(with: lastOutput)
        try await session.end(now: now)
        // After the save, because a route attaches to a workout that already exists
        // ([legacy] T-107).
        await session.saveRoute(route)
        store.finalizeRun()
        phase = .finished

        let timeline = ZoneTimeline.encode(zones: zones)
        let summary = RunSummaryBuilder.build(
            samples: samples,
            activeSeconds: session.activeElapsed,
            zoneTimeline: timeline,
            config: config.stats
        )
        return (summary, accumulator.completed)
    }

    /// Dismisses a visible interruption (AC-FR-B-2-4).
    public func dismissAlert() {
        presenter.dismiss()
        alert = nil
    }

    /// Records that the runner asked to advance the step (tap or crown detent, T-069).
    ///
    /// Latched for the *next* tick rather than acted on immediately, and that is the important part:
    /// `StepMachine` decides whether an advance is permitted, from a tick that carries
    /// `manualAdvanceRequested`. Advancing here would be this tier deciding for itself, which is
    /// exactly what AC-FR-C-3 must not be re-implemented per tier — and the request is dropped by the
    /// engine, correctly, on any step with a distance or time goal.
    public func requestManualAdvance() {
        pendingManualAdvance = true
    }

    /// Whether the runner has a pending advance request, consumed by the next `ingest`.
    private var pendingManualAdvance = false

    /// Takes and clears the latch, for the feed to fold into the next `EngineInput`.
    public func consumeManualAdvanceRequest() -> Bool {
        defer { pendingManualAdvance = false }
        return pendingManualAdvance
    }

    // MARK: - Read-only accessors for the envelope builder

    public var capturedSamples: [RunSample] { samples }
    public var capturedZones: [PaceZone] { zones }
    public var currentRunID: UUID? { runID }
    public var savedWorkoutID: UUID? { session.savedWorkoutID }
    public var recordedSegments: [WorkoutSegment] { session.recordedSegments }
}
