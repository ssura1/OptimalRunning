import Foundation
import ORAlerts
import ORIntervals
import ORModels
import ORPace
import XCTest

@testable import PhoneSupport

// MARK: - Doubles

/// A feed that reports exactly what a test tells it to, and records what was asked of it.
///
/// Deliberately knows nothing about pause or manual advance: those are the run controller's
/// to merge in (`StandaloneRunController.merge`), and a fake that tracked them could
/// accidentally satisfy an assertion the real feed never satisfies.
@MainActor
final class FakeStandaloneFeed: MotionTelemetryReporting, CalibrationProducing {

    var onSample: ((EngineInput) -> Void)?
    var onTelemetry: ((MotionTelemetry) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var isRunning = false

    var calibrationPayload: Data? = Data("calibrated".utf8)
    var averageCadenceStepsPerMinute: Double? = 168
    var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] = []

    var capabilities = SensorCapabilities(
        hasAltimeter: true,
        hasGPS: true,
        hasAlwaysOnDisplay: false,
        supportsNativeActivitySegmentation: false,
        supportsDoubleTap: false,
        distance: .measuredWithEstimatedFallback,
        workoutSession: .builderOnly)

    func start(activity: RunActivityKind) throws {
        startCount += 1
        isRunning = true
    }

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    func stop() async throws -> RunSummary {
        stopCount += 1
        isRunning = false
        return RunSummary(
            distanceMetres: 0, activeSeconds: 0, averagePace: nil, averageHeartRate: nil,
            maxHeartRate: nil, elevationGainMetres: 0,
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count))
    }

    /// Drives one tick as the real feed would: sample first, telemetry second.
    func emit(_ input: EngineInput, telemetry: MotionTelemetry = .empty) {
        onSample?(input)
        onTelemetry?(telemetry)
    }

    /// Whether every subscription this feed hands out has been released (NFR-S-6).
    var isFullyReleased: Bool { onSample == nil && onTelemetry == nil && !isRunning }
}

@MainActor
final class SpyCueSpeaker: CueSpeaking {
    private(set) var spoken: [SpokenCue] = []
    private(set) var stopCount = 0
    private(set) var prepared: [SpeechSettings] = []
    func prepare(_ settings: SpeechSettings) { prepared.append(settings) }
    func speak(_ cue: SpokenCue) { spoken.append(cue) }
    func stop() { stopCount += 1 }
    var phrases: [String] { spoken.map(\.phrase) }
}

@MainActor
final class SpyHapticPlayer: HapticPlaying {
    private(set) var played: [StandaloneHapticPattern] = []
    func play(_ pattern: StandaloneHapticPattern) { played.append(pattern) }
}

final class SpyWorkoutWriter: StandaloneWorkoutWriting, @unchecked Sendable {
    var authorization: AuthorizationOutcome = .authorized
    private(set) var saveCount = 0
    private(set) var lastEvents: [WorkoutEventMark] = []
    private(set) var lastRoute: [RoutePoint] = []
    var savedUUID: UUID? = UUID()

    func requestAuthorization() async -> AuthorizationOutcome { authorization }

    func save(
        startedAt: Date, endedAt: Date, distanceMetres: Double, activeSeconds: TimeInterval,
        route: [RoutePoint], events: [WorkoutEventMark]
    ) async throws -> UUID? {
        saveCount += 1
        lastEvents = events
        lastRoute = route
        return savedUUID
    }
}

final class InMemoryCalibrationStore: CalibrationStoring, @unchecked Sendable {
    private var storage: [CarryPosition: Data] = [:]
    private(set) var saveCount = 0

    func loadCalibration(for position: CarryPosition) -> Data? { storage[position] }

    func saveCalibration(_ payload: Data?, for position: CarryPosition) {
        saveCount += 1
        storage[position] = payload
    }
}

// MARK: - Tests

@MainActor
final class StandaloneRunControllerTests: XCTestCase {

    /// A unique scratch directory, cleaned up when the test finishes.
    ///
    /// Deliberately **not** a stored property assigned in `setUp()`/`tearDown()`, and the
    /// reason is recorded in `WatchSupport`'s `RunSessionModelTests` because that suite hit
    /// it first: `XCTestCase`'s `setUp` is `nonisolated`, so touching main-actor state from
    /// an override in a `@MainActor` class is an isolation violation that **some Swift
    /// versions accept and some reject**. This suite reproduced the whole sequence — the
    /// stored-property form compiled on Xcode 26 and failed CI's Xcode 16.4;
    /// `MainActor.assumeIsolated` inverted it and failed locally with "sending 'self' risks
    /// causing data races". Allocating per test in an already-isolated context is the shape
    /// that compiles on both.
    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StandaloneRunControllerTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Everything one standalone run needs, built together so a test names only what it
    /// asserts on.
    private struct Harness {
        let controller: StandaloneRunController
        let feed: FakeStandaloneFeed
        let store: StandaloneSampleStore
        let cues: SpyCueSpeaker
        let haptics: SpyHapticPlayer
        let workout: SpyWorkoutWriter
        let calibration: InMemoryCalibrationStore
        /// Exposed so a test can open a *second* store over the same directory, which is how
        /// a relaunch discovering an orphan is simulated.
        let directory: URL
    }

    private func makeHarness(
        plan: WorkoutPlan = .steady(.tempo),
        profile: RunnerProfile = .standaloneDefault,
        activity: RunActivityKind = .outdoorRun,
        store: ((URL) -> StandaloneSampleStore)? = nil
    ) -> Harness {
        let directory = makeScratchDirectory()
        let feed = FakeStandaloneFeed()
        let sampleStore = store?(directory) ?? StandaloneSampleStore(directory: directory)
        let cues = SpyCueSpeaker()
        let haptics = SpyHapticPlayer()
        let workout = SpyWorkoutWriter()
        let calibration = InMemoryCalibrationStore()

        return Harness(
            controller: StandaloneRunController(
                plan: plan, activity: activity, profile: profile, feed: feed,
                store: sampleStore, cues: cues, haptics: haptics, workout: workout,
                calibrationStore: calibration, appVersion: "1.0-test"),
            feed: feed,
            store: sampleStore,
            cues: cues,
            haptics: haptics,
            workout: workout,
            calibration: calibration,
            directory: directory)
    }

    // MARK: - Lifecycle (S-032)

    func testASimulatedRunDrivesStateEndToEnd() async throws {
        let h = makeHarness()
        XCTAssertEqual(h.controller.phase, .idle)

        try await h.controller.start()
        XCTAssertEqual(h.controller.phase, .running)
        XCTAssertEqual(h.feed.startCount, 1)

        for tick in 1...30 {
            h.feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }

        XCTAssertEqual(h.controller.samplesRecorded, 30)
        XCTAssertNotNil(h.controller.output)
        XCTAssertNotNil(h.controller.screen)
        XCTAssertEqual(h.controller.telemetry.stepCount, 30 * 3)

        let envelope = try await h.controller.end()
        XCTAssertEqual(h.controller.phase, .ended)
        let unwrapped = try XCTUnwrap(envelope)
        XCTAssertEqual(unwrapped.deviceTier, .phoneStandalone)
        XCTAssertNotNil(unwrapped.standalone)
    }

    func testEndReleasesEverySubscriptionAndStopsEveryChannel() async throws {
        // AC-FR-S-A-2-3 / NFR-S-6, the standalone analogue of NFR-8's teardown test. The
        // properties checked are the ones that cost battery if they survive: a live sensor
        // subscription, and an audio session held open by a speaking cue engine.
        let h = makeHarness()
        try await h.controller.start()
        h.feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))

        _ = try await h.controller.end()

        XCTAssertEqual(h.feed.stopCount, 1, "the h.feed must be stopped exactly once")
        XCTAssertTrue(h.feed.isFullyReleased, "no callback may outlive the run")
        XCTAssertEqual(h.cues.stopCount, 1, "the cue channel must be stopped, not left idle")
    }

    func testATickArrivingAfterEndIsIgnored() async throws {
        // The failure this prevents is a late CoreLocation callback appending a sample to a
        // run that has already been composed, which would make the stored envelope and the
        // in-memory outputs disagree.
        let h = makeHarness()
        try await h.controller.start()
        h.feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))
        _ = try await h.controller.end()

        let recorded = h.controller.samplesRecorded
        h.controller.ingest(EngineInput.running(at: 99))
        XCTAssertEqual(h.controller.samplesRecorded, recorded)
    }

    func testPauseAndResumeReachTheFeedAndTheEngine() async throws {
        let h = makeHarness()
        try await h.controller.start()
        h.feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))

        await h.controller.pause()
        XCTAssertEqual(h.controller.phase, .paused)
        XCTAssertEqual(h.feed.pauseCount, 1)

        // The engine's active clock stops while paused — the whole point of merging
        // `isPaused` into the input rather than letting the h.feed report it.
        //
        // Asserted from the second post-pause tick onwards, not the first, because
        // `ActiveClock` credits an interval that *began* while running: pausing between two
        // ticks forfeits at most one second, which its own comment records as deliberate.
        // Asserting no advance at all would be asserting against Core's documented
        // behaviour and would fail for a correct implementation.
        h.feed.emit(.running(at: 2), telemetry: .runningTelemetry(at: 2))
        let afterFirstPausedTick = h.controller.output?.activeElapsed ?? 0
        h.feed.emit(.running(at: 3), telemetry: .runningTelemetry(at: 3))
        h.feed.emit(.running(at: 4), telemetry: .runningTelemetry(at: 4))
        XCTAssertEqual(
            h.controller.output?.activeElapsed ?? 0, afterFirstPausedTick, accuracy: 1e-9,
            "active time must not accrue across a pause")

        await h.controller.resume()
        XCTAssertEqual(h.controller.phase, .running)
        XCTAssertEqual(h.feed.resumeCount, 1)
    }

    func testARunRefusesToStartWithoutEnoughStorage() async throws {
        // DEG-6 at second zero rather than minute forty.
        let h = makeHarness(store: { StandaloneSampleStore(directory: $0, freeBytes: { _ in 0 }) })

        do {
            try await h.controller.start()
            XCTFail("expected a refusal")
        } catch let refusal as StandaloneRunRefusal {
            guard case .insufficientStorage = refusal else {
                return XCTFail("wrong refusal: \(refusal)")
            }
        }
        XCTAssertEqual(h.feed.startCount, 0, "no sensor may be started for a doomed run")
        XCTAssertEqual(h.controller.phase, .idle)
    }

    func testStartingTwiceIsRefusedRatherThanRestarting() async throws {
        let h = makeHarness()
        try await h.controller.start()
        do {
            try await h.controller.start()
            XCTFail("expected a refusal")
        } catch let refusal as StandaloneRunRefusal {
            XCTAssertEqual(refusal, .alreadyRunning)
        }
        XCTAssertEqual(h.feed.startCount, 1)
    }

    // MARK: - Durability (NFR-S-13, AC-FR-S-A-2-4)

    func testAKillMidRunLosesNoMoreThanTheFlushInterval() async throws {
        let h = makeHarness()
        try await h.controller.start()

        let flush = PaceEngineConfiguration.default.capture.flushIntervalSeconds
        // Run past two flush boundaries so at least one write has definitely landed.
        for tick in 1...Int(flush * 2 + 5) {
            h.feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }

        // No `end()` — this is the termination case.
        let orphan = try XCTUnwrap(h.store.detectOrphan(), "a killed run must leave an orphan")
        let recovered = try XCTUnwrap(h.store.loadOrphan(runID: orphan.runID))

        let lastRecovered = try XCTUnwrap(recovered.samples.last).timestamp
        let lastEmitted = Double(Int(flush * 2 + 5))
        XCTAssertLessThanOrEqual(
            lastEmitted - lastRecovered, flush,
            "at most one flush interval may be lost (NFR-S-13)")
        XCTAssertEqual(recovered.runType, .tempo)
    }

    func testACleanlyEndedRunLeavesNoOrphan() async throws {
        let h = makeHarness()
        try await h.controller.start()
        for tick in 1...40 {
            h.feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        _ = try await h.controller.end()

        XCTAssertNil(h.store.detectOrphan(), "a finished run must not be offered for recovery")
    }

    func testARecoveredOrphanCarriesTheStandaloneFactsAndNotJustSamples() async throws {
        // The reason this h.store is not the watch's: a recovered standalone run that lost
        // its provenance would come back claiming a distance with nothing to say about
        // where the distance came from.
        //
        // Driven entirely through the **h.controller**, with no direct `h.store.append`. An
        // earlier version wrote the facts itself and passed while the h.controller wrote them
        // only in `end()` — where `finalizeRun()` deletes the very file orphan recovery
        // reads. A test that supplies the thing under test is a test of nothing.
        let h = makeHarness()
        try await h.controller.start()

        let flush = PaceEngineConfiguration.default.capture.flushIntervalSeconds
        for tick in 1...Int(flush * 2 + 5) {
            h.feed.emit(
                .running(at: Double(tick), source: .motionModel, hasFix: false),
                telemetry: .runningTelemetry(
                    at: tick, estimatedMetres: Double(tick) * 3, flags: [.distanceEstimated]))
        }
        // No `end()` — this is the termination case, which is the only case that reads the
        // facts back.

        let orphan = try XCTUnwrap(h.store.detectOrphan())
        let facts = try XCTUnwrap(
            orphan.facts, "a recovered run must know where its distance came from")
        XCTAssertGreaterThan(facts.estimatedMetres, 0)
        XCTAssertEqual(facts.flags, [.distanceEstimated])
        XCTAssertEqual(facts.carryPosition, .handHeld)
        XCTAssertEqual(facts.averageCadenceStepsPerMinute, 168)
    }

    // MARK: - Calibration persistence (AC-FR-S-C-2-2)

    func testTheCalibrationIsPersistedWhenTheRunEnds() async throws {
        let h = makeHarness()
        try await h.controller.start()
        h.feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))
        _ = try await h.controller.end()

        XCTAssertEqual(h.calibration.saveCount, 1)
        XCTAssertEqual(
            h.calibration.loadCalibration(for: .handHeld), Data("calibrated".utf8),
            "the opaque payload must round-trip byte for byte")
    }

    // MARK: - HealthKit (S-033)

    func testAWorkoutIsSavedWithItsRouteAndStepBoundaries() async throws {
        let h = makeHarness(plan: .intervals())
        try await h.controller.start()
        for tick in 1...400 {
            h.feed.emit(
                .running(at: Double(tick), metresPerSecond: 4.0),
                telemetry: .runningTelemetry(at: tick))
        }
        let envelope = try await h.controller.end()

        XCTAssertEqual(h.workout.saveCount, 1)
        XCTAssertFalse(h.workout.lastEvents.isEmpty, "interval steps must be recorded as events")
        XCTAssertEqual(try XCTUnwrap(envelope).healthKitWorkoutUUID, h.workout.savedUUID)
    }

    func testDeclinedHealthAuthorizationStillRecordsTheRunAndSaysSo() async throws {
        // AC-FR-S-A-4-4. Denial is a handled state, not an error path.
        let h = makeHarness()
        h.workout.authorization = .denied
        try await h.controller.start()
        XCTAssertTrue(h.controller.healthKitWriteDeclined)

        for tick in 1...10 {
            h.feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        let envelope = try await h.controller.end()

        XCTAssertEqual(h.workout.saveCount, 0, "nothing may be written to Health")
        let unwrapped = try XCTUnwrap(envelope, "the run must still be recorded locally")
        XCTAssertNil(unwrapped.healthKitWorkoutUUID)
        XCTAssertGreaterThan(unwrapped.summary.distanceMetres, 0)
    }

    func testNoHeartRateSampleIsEverWritten() async throws {
        // AC-FR-S-A-4-3, checked at the seam: the writer protocol has no parameter that
        // could carry one, and the composed envelope carries none either.
        let h = makeHarness()
        try await h.controller.start()
        for tick in 1...20 {
            h.feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        let composed = try await h.controller.end()
        let envelope = try XCTUnwrap(composed)

        XCTAssertNil(envelope.summary.averageHeartRate)
        XCTAssertNil(envelope.summary.maxHeartRate)
        let unpacked = try XCTUnwrap(envelope.samples.unpack())
        XCTAssertFalse(unpacked.isEmpty)
        XCTAssertTrue(unpacked.allSatisfy { $0.heartRate == nil })
    }
}

// MARK: - Fixtures

extension EngineInput {

    /// A steady tick at a plausible running speed.
    static func running(
        at seconds: TimeInterval,
        metresPerSecond: Double = 3.0,
        source: DistanceSource = .location,
        hasFix: Bool = true
    ) -> EngineInput {
        EngineInput(
            timestamp: seconds,
            cumulativeDistance: seconds * metresPerSecond,
            location: hasFix
                ? LocationSample(
                    timestamp: seconds,
                    latitude: 0, longitude: 0, altitudeMetres: 0,
                    horizontalAccuracy: 5, verticalAccuracy: 5)
                : nil,
            relativeAltitude: 0,
            heartRate: nil,
            distanceSource: source)
    }

    /// One indoor tick, as `MotionPipeline` produces them: elapsed time advances and
    /// distance does not (CON-S-8).
    static func indoorTick(at seconds: TimeInterval) -> EngineInput {
        EngineInput(
            timestamp: seconds,
            cumulativeDistance: 0,
            location: nil,
            relativeAltitude: nil,
            heartRate: nil,
            distanceSource: .motionModel)
    }
}

extension MotionTelemetry {
    static func runningTelemetry(
        at tick: Int, estimatedMetres: Double = 0, flags: Set<MotionFlag> = []
    ) -> MotionTelemetry {
        MotionTelemetry(
            cadenceStepsPerMinute: 168,
            cadenceConfidence: 0.9,
            stepCount: tick * 3,
            measuredMetres: Double(tick) * 3.0 - estimatedMetres,
            estimatedMetres: estimatedMetres,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: true, observationCount: 6,
                bandsWithEvidence: 2, metresPerStepAtTypicalCadence: 1.01),
            flags: flags)
    }
}

extension RunnerProfile {
    /// A profile with paces set, so runs are actually judged rather than neutral.
    static let standaloneDefault = RunnerProfile(
        tempoPace: Pace(minutesPerMile: 8),
        easyPace: Pace(minutesPerMile: 10),
        longPace: Pace(minutesPerMile: 9.5),
        units: .miles,
        heightMetres: 1.77)
}

extension WorkoutPlan {
    static func steady(_ type: RunType) -> WorkoutPlan {
        WorkoutPlan(runType: type, elements: [.step(WorkoutStep(kind: .work, goal: .open))])
    }

    static func intervals() -> WorkoutPlan {
        WorkoutPlan(
            runType: .interval,
            elements: [
                .step(WorkoutStep(kind: .warmup, goal: .distance(metres: 400))),
                .repeatBlock(
                    count: 2,
                    elements: [
                        .step(WorkoutStep(kind: .work, goal: .distance(metres: 400))),
                        .step(WorkoutStep(kind: .recovery, goal: .distance(metres: 200))),
                    ]),
                .step(WorkoutStep(kind: .cooldown, goal: .open)),
            ])
    }
}
