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

    private var directory: URL!
    private var feed: FakeStandaloneFeed!
    private var store: StandaloneSampleStore!
    private var cues: SpyCueSpeaker!
    private var haptics: SpyHapticPlayer!
    private var workout: SpyWorkoutWriter!
    private var calibration: InMemoryCalibrationStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        feed = FakeStandaloneFeed()
        store = StandaloneSampleStore(directory: directory)
        cues = SpyCueSpeaker()
        haptics = SpyHapticPlayer()
        workout = SpyWorkoutWriter()
        calibration = InMemoryCalibrationStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        plan: WorkoutPlan = .steady(.tempo),
        profile: RunnerProfile = .standaloneDefault,
        activity: RunActivityKind = .outdoorRun
    ) -> StandaloneRunController {
        StandaloneRunController(
            plan: plan,
            activity: activity,
            profile: profile,
            feed: feed,
            store: store,
            cues: cues,
            haptics: haptics,
            workout: workout,
            calibrationStore: calibration,
            appVersion: "1.0-test")
    }

    // MARK: - Lifecycle (S-032)

    func testASimulatedRunDrivesStateEndToEnd() async throws {
        let controller = makeController()
        XCTAssertEqual(controller.phase, .idle)

        try await controller.start()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(feed.startCount, 1)

        for tick in 1...30 {
            feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }

        XCTAssertEqual(controller.samplesRecorded, 30)
        XCTAssertNotNil(controller.output)
        XCTAssertNotNil(controller.screen)
        XCTAssertEqual(controller.telemetry.stepCount, 30 * 3)

        let envelope = try await controller.end()
        XCTAssertEqual(controller.phase, .ended)
        let unwrapped = try XCTUnwrap(envelope)
        XCTAssertEqual(unwrapped.deviceTier, .phoneStandalone)
        XCTAssertNotNil(unwrapped.standalone)
    }

    func testEndReleasesEverySubscriptionAndStopsEveryChannel() async throws {
        // AC-FR-S-A-2-3 / NFR-S-6, the standalone analogue of NFR-8's teardown test. The
        // properties checked are the ones that cost battery if they survive: a live sensor
        // subscription, and an audio session held open by a speaking cue engine.
        let controller = makeController()
        try await controller.start()
        feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))

        _ = try await controller.end()

        XCTAssertEqual(feed.stopCount, 1, "the feed must be stopped exactly once")
        XCTAssertTrue(feed.isFullyReleased, "no callback may outlive the run")
        XCTAssertEqual(cues.stopCount, 1, "the cue channel must be stopped, not left idle")
    }

    func testATickArrivingAfterEndIsIgnored() async throws {
        // The failure this prevents is a late CoreLocation callback appending a sample to a
        // run that has already been composed, which would make the stored envelope and the
        // in-memory outputs disagree.
        let controller = makeController()
        try await controller.start()
        feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))
        _ = try await controller.end()

        let recorded = controller.samplesRecorded
        controller.ingest(EngineInput.running(at: 99))
        XCTAssertEqual(controller.samplesRecorded, recorded)
    }

    func testPauseAndResumeReachTheFeedAndTheEngine() async throws {
        let controller = makeController()
        try await controller.start()
        feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))

        await controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(feed.pauseCount, 1)

        // The engine's active clock stops while paused — the whole point of merging
        // `isPaused` into the input rather than letting the feed report it.
        //
        // Asserted from the second post-pause tick onwards, not the first, because
        // `ActiveClock` credits an interval that *began* while running: pausing between two
        // ticks forfeits at most one second, which its own comment records as deliberate.
        // Asserting no advance at all would be asserting against Core's documented
        // behaviour and would fail for a correct implementation.
        feed.emit(.running(at: 2), telemetry: .runningTelemetry(at: 2))
        let afterFirstPausedTick = controller.output?.activeElapsed ?? 0
        feed.emit(.running(at: 3), telemetry: .runningTelemetry(at: 3))
        feed.emit(.running(at: 4), telemetry: .runningTelemetry(at: 4))
        XCTAssertEqual(
            controller.output?.activeElapsed ?? 0, afterFirstPausedTick, accuracy: 1e-9,
            "active time must not accrue across a pause")

        await controller.resume()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(feed.resumeCount, 1)
    }

    func testARunRefusesToStartWithoutEnoughStorage() async throws {
        // DEG-6 at second zero rather than minute forty.
        let starved = StandaloneSampleStore(directory: directory, freeBytes: { _ in 0 })
        let controller = StandaloneRunController(
            plan: .steady(.tempo), profile: .standaloneDefault, feed: feed, store: starved,
            cues: cues, haptics: haptics, workout: workout, calibrationStore: calibration,
            appVersion: "1.0-test")

        do {
            try await controller.start()
            XCTFail("expected a refusal")
        } catch let refusal as StandaloneRunRefusal {
            guard case .insufficientStorage = refusal else {
                return XCTFail("wrong refusal: \(refusal)")
            }
        }
        XCTAssertEqual(feed.startCount, 0, "no sensor may be started for a doomed run")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testStartingTwiceIsRefusedRatherThanRestarting() async throws {
        let controller = makeController()
        try await controller.start()
        do {
            try await controller.start()
            XCTFail("expected a refusal")
        } catch let refusal as StandaloneRunRefusal {
            XCTAssertEqual(refusal, .alreadyRunning)
        }
        XCTAssertEqual(feed.startCount, 1)
    }

    // MARK: - Durability (NFR-S-13, AC-FR-S-A-2-4)

    func testAKillMidRunLosesNoMoreThanTheFlushInterval() async throws {
        let controller = makeController()
        try await controller.start()

        let flush = PaceEngineConfiguration.default.capture.flushIntervalSeconds
        // Run past two flush boundaries so at least one write has definitely landed.
        for tick in 1...Int(flush * 2 + 5) {
            feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }

        // No `end()` — this is the termination case.
        let orphan = try XCTUnwrap(store.detectOrphan(), "a killed run must leave an orphan")
        let recovered = try XCTUnwrap(store.loadOrphan(runID: orphan.runID))

        let lastRecovered = try XCTUnwrap(recovered.samples.last).timestamp
        let lastEmitted = Double(Int(flush * 2 + 5))
        XCTAssertLessThanOrEqual(
            lastEmitted - lastRecovered, flush,
            "at most one flush interval may be lost (NFR-S-13)")
        XCTAssertEqual(recovered.runType, .tempo)
    }

    func testACleanlyEndedRunLeavesNoOrphan() async throws {
        let controller = makeController()
        try await controller.start()
        for tick in 1...40 {
            feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        _ = try await controller.end()

        XCTAssertNil(store.detectOrphan(), "a finished run must not be offered for recovery")
    }

    func testARecoveredOrphanCarriesTheStandaloneFactsAndNotJustSamples() async throws {
        // The reason this store is not the watch's: a recovered standalone run that lost
        // its provenance would come back claiming a distance with nothing to say about
        // where the distance came from.
        //
        // Driven entirely through the **controller**, with no direct `store.append`. An
        // earlier version wrote the facts itself and passed while the controller wrote them
        // only in `end()` — where `finalizeRun()` deletes the very file orphan recovery
        // reads. A test that supplies the thing under test is a test of nothing.
        let controller = makeController()
        try await controller.start()

        let flush = PaceEngineConfiguration.default.capture.flushIntervalSeconds
        for tick in 1...Int(flush * 2 + 5) {
            feed.emit(
                .running(at: Double(tick), source: .motionModel, hasFix: false),
                telemetry: .runningTelemetry(
                    at: tick, estimatedMetres: Double(tick) * 3, flags: [.distanceEstimated]))
        }
        // No `end()` — this is the termination case, which is the only case that reads the
        // facts back.

        let orphan = try XCTUnwrap(store.detectOrphan())
        let facts = try XCTUnwrap(
            orphan.facts, "a recovered run must know where its distance came from")
        XCTAssertGreaterThan(facts.estimatedMetres, 0)
        XCTAssertEqual(facts.flags, [.distanceEstimated])
        XCTAssertEqual(facts.carryPosition, .handHeld)
        XCTAssertEqual(facts.averageCadenceStepsPerMinute, 168)
    }

    // MARK: - Calibration persistence (AC-FR-S-C-2-2)

    func testTheCalibrationIsPersistedWhenTheRunEnds() async throws {
        let controller = makeController()
        try await controller.start()
        feed.emit(.running(at: 1), telemetry: .runningTelemetry(at: 1))
        _ = try await controller.end()

        XCTAssertEqual(calibration.saveCount, 1)
        XCTAssertEqual(
            calibration.loadCalibration(for: .handHeld), Data("calibrated".utf8),
            "the opaque payload must round-trip byte for byte")
    }

    // MARK: - HealthKit (S-033)

    func testAWorkoutIsSavedWithItsRouteAndStepBoundaries() async throws {
        let controller = makeController(plan: .intervals())
        try await controller.start()
        for tick in 1...400 {
            feed.emit(
                .running(at: Double(tick), metresPerSecond: 4.0),
                telemetry: .runningTelemetry(at: tick))
        }
        let envelope = try await controller.end()

        XCTAssertEqual(workout.saveCount, 1)
        XCTAssertFalse(workout.lastEvents.isEmpty, "interval steps must be recorded as events")
        XCTAssertEqual(try XCTUnwrap(envelope).healthKitWorkoutUUID, workout.savedUUID)
    }

    func testDeclinedHealthAuthorizationStillRecordsTheRunAndSaysSo() async throws {
        // AC-FR-S-A-4-4. Denial is a handled state, not an error path.
        workout.authorization = .denied
        let controller = makeController()
        try await controller.start()
        XCTAssertTrue(controller.healthKitWriteDeclined)

        for tick in 1...10 {
            feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        let envelope = try await controller.end()

        XCTAssertEqual(workout.saveCount, 0, "nothing may be written to Health")
        let unwrapped = try XCTUnwrap(envelope, "the run must still be recorded locally")
        XCTAssertNil(unwrapped.healthKitWorkoutUUID)
        XCTAssertGreaterThan(unwrapped.summary.distanceMetres, 0)
    }

    func testNoHeartRateSampleIsEverWritten() async throws {
        // AC-FR-S-A-4-3, checked at the seam: the writer protocol has no parameter that
        // could carry one, and the composed envelope carries none either.
        let controller = makeController()
        try await controller.start()
        for tick in 1...20 {
            feed.emit(.running(at: Double(tick)), telemetry: .runningTelemetry(at: tick))
        }
        let composed = try await controller.end()
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
