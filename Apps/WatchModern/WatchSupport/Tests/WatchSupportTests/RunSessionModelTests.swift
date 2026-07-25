import XCTest
import ORAlerts
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// A feed the test drives by hand, standing in for HealthKit + CoreLocation + CoreMotion.
///
/// It records whether it is still running, which is what makes NFR-8 assertable: "no
/// timer, location update, or wake lock remains active once the session ends" becomes
/// "the one object that owns all three was stopped".
@MainActor
final class FakeSensorFeed: RunSensorFeed {
    var onSample: ((EngineInput) -> Void)?

    private(set) var isRunning = false
    private(set) var isPausedByCaller = false
    private(set) var stopCallCount = 0
    private(set) var startedActivity: RunActivityKind?

    var capabilities = SensorCapabilities(
        hasAltimeter: true, hasGPS: true, hasAlwaysOnDisplay: true,
        supportsNativeActivitySegmentation: true, supportsDoubleTap: true
    )

    func start(activity: RunActivityKind) throws {
        isRunning = true
        startedActivity = activity
    }

    func pause() { isPausedByCaller = true }
    func resume() { isPausedByCaller = false }

    func stop() async throws -> RunSummary {
        stopCallCount += 1
        isRunning = false
        onSample = nil
        return RunSummary(
            distanceMetres: 0, activeSeconds: 0, averagePace: nil, averageHeartRate: nil,
            maxHeartRate: nil, elevationGainMetres: 0,
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count)
        )
    }

    /// Emits a tick, exactly as a real feed's 1 Hz callback would.
    func emit(_ input: EngineInput) { onSample?(input) }
}

final class RecordingHaptics: HapticPlaying {
    private(set) var played: [HapticPattern] = []
    func play(_ pattern: HapticPattern) { played.append(pattern) }
}

/// A store on a volume reporting no free space, for DEG-6.
func makeFullDiskStore(directory: URL) -> SampleStore {
    SampleStore(directory: directory, freeBytes: { _ in 0 })
}

@MainActor
final class RunSessionModelTests: XCTestCase {

    /// A unique scratch directory, cleaned up when the test finishes.
    ///
    /// Deliberately **not** a stored property assigned in `setUp()`/`tearDown()`.
    /// `XCTestCase`'s `setUp()` and `tearDown()` are `nonisolated`, so overriding them in
    /// a `@MainActor` class and touching main-actor-isolated state from inside is an
    /// isolation violation. Some Swift versions accept it and some reject it — this
    /// compiled locally and failed CI — so the portable shape is to allocate per test in
    /// an already-isolated context and register cleanup with `addTeardownBlock`, which
    /// runs regardless of whether the test passes, fails, or throws.
    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunSessionModelTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Harness

    private struct Harness {
        let model: RunSessionModel
        let feed: FakeSensorFeed
        let haptics: RecordingHaptics
        let backend: FakeWorkoutBackend
        let store: SampleStore
        /// Exposed so a test can open a *second* store over the same directory, which is
        /// how a relaunch discovering an orphan is simulated.
        let directory: URL
    }

    /// `store` is a factory rather than a value because the directory is allocated here —
    /// a caller wanting a special store still needs it pointed at this test's scratch
    /// directory.
    private func makeHarness(
        runType: RunType = .tempo,
        profile: RunnerProfile? = nil,
        store: ((URL) -> SampleStore)? = nil
    ) -> Harness {
        let directory = makeScratchDirectory()
        let feed = FakeSensorFeed()
        let haptics = RecordingHaptics()
        let backend = FakeWorkoutBackend()
        let sampleStore = store?(directory) ?? SampleStore(directory: directory)

        let plan = runType.isStructured
            ? WorkoutPresets.intervals(reps: 4, workMetres: 400, recoveryMetres: 200)
            : WorkoutPresets.continuousRun(runType: runType)

        let resolvedProfile = profile ?? RunnerProfile(
            tempoPace: Pace(minutesPerMile: 8),
            easyPace: Pace(minutesPerMile: 9.5),
            longPace: Pace(minutesPerMile: 9)
        )

        let model = RunSessionModel(
            plan: runType == .vo2max ? WorkoutPresets.vo2Max4x1000() : plan,
            profile: resolvedProfile,
            feed: feed,
            store: sampleStore,
            session: WorkoutSessionController(backend: backend),
            haptics: haptics
        )
        return Harness(
            model: model, feed: feed, haptics: haptics, backend: backend,
            store: sampleStore, directory: directory
        )
    }

    /// Walks a run forward at 1 Hz at a steady pace.
    private func run(
        _ harness: Harness,
        seconds: Int,
        metresPerSecond: Double = 3.35,
        from startSecond: Int = 0
    ) {
        for second in startSecond..<(startSecond + seconds) {
            harness.feed.emit(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: Double(second) * metresPerSecond,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5, longitude: -0.12,
                    altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0,
                heartRate: 155,
                distanceSource: .healthKit
            ))
        }
    }

    // MARK: - T-037: a simulated run drives state end to end

    func testASimulatedRunProducesStateSamplesAndAScreen() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertEqual(harness.feed.startedActivity, .outdoorRun)

        run(harness, seconds: 300)

        XCTAssertEqual(harness.model.samplesRecorded, 300)
        XCTAssertNotNil(harness.model.output)
        XCTAssertNotNil(harness.model.screen)
        XCTAssertEqual(harness.model.output?.activeElapsed ?? 0, 299, accuracy: 1e-6)
    }

    /// The run opens neutral and then settles onto a judged zone — the settling window
    /// working through the whole stack, not just in `Core`'s own tests.
    func testZoneChangesPropagateToTheRenderedScreen() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        run(harness, seconds: 1)
        XCTAssertEqual(harness.model.screen?.zone, .neutral, "a run must not judge its first tick")

        run(harness, seconds: 400, from: 1)
        XCTAssertEqual(harness.model.screen?.zone, .onTarget)
    }

    func testPauseAndResumeMoveThePhaseAndReachTheFeedAndSession() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 100)

        await harness.model.pause()
        XCTAssertEqual(harness.model.phase, .paused)
        XCTAssertTrue(harness.feed.isPausedByCaller)
        let afterPause = await harness.backend.calls
        XCTAssertEqual(afterPause.last, .pause)

        await harness.model.resume()
        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertFalse(harness.feed.isPausedByCaller)
        let afterResume = await harness.backend.calls
        XCTAssertEqual(afterResume.last, .resume)
    }

    /// While paused, the zone is neutral — the app has nothing honest to say about the
    /// pace of a runner who is standing still.
    func testTicksWhilePausedRenderNeutral() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 400)
        XCTAssertEqual(harness.model.screen?.zone, .onTarget)

        await harness.model.pause()
        run(harness, seconds: 5, from: 400)

        XCTAssertEqual(harness.model.screen?.zone, .neutral)
    }

    // MARK: - NFR-8: nothing survives the end of a run

    /// T-037's Done-when, stated directly. The feed is the single owner of every timer,
    /// location subscription, and wake lock in this tier, so "was the feed stopped?" is
    /// the whole assertion — and the model clears `onSample` too, so a late callback
    /// from a sensor already in flight cannot resurrect the run.
    func testEndingARunTearsDownEverySubscription() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 120)

        _ = try await harness.model.end()

        XCTAssertEqual(harness.model.phase, .ended)
        XCTAssertFalse(harness.feed.isRunning, "the feed was left running after the run ended")
        XCTAssertEqual(harness.feed.stopCallCount, 1)
        XCTAssertNil(harness.feed.onSample, "a stale callback could still fire")
        XCTAssertNil(harness.model.presentation)
    }

    /// A tick arriving after the end — a sensor callback already queued when End was
    /// tapped — must be ignored rather than recorded into a finished run.
    func testTicksArrivingAfterTheEndAreIgnored() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 60)
        let recorded = harness.model.samplesRecorded

        _ = try await harness.model.end()
        harness.model.ingest(EngineInput(timestamp: 61, cumulativeDistance: 205))

        XCTAssertEqual(harness.model.samplesRecorded, recorded)
    }

    func testEndingIsSafeToCallTwice() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 30)

        _ = try await harness.model.end()
        _ = try await harness.model.end()

        XCTAssertEqual(harness.feed.stopCallCount, 1, "the second End re-stopped the feed")
    }

    /// A clean end leaves no orphan for the next launch to find (T-038).
    func testACleanEndLeavesNoOrphan() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 90)
        _ = try await harness.model.end()

        let freshStore = SampleStore(directory: harness.directory)
        XCTAssertNil(freshStore.detectOrphan())
    }

    /// …whereas a run that never ends does leave one, bounded by the flush interval.
    func testAnInterruptedRunLeavesARecoverableOrphan() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 200)
        // No end() — this is the crash.

        let orphan = SampleStore(directory: harness.directory).detectOrphan()
        XCTAssertNotNil(orphan)
        XCTAssertGreaterThanOrEqual(orphan?.sampleCount ?? 0, 170, "lost more than 30 s")
    }

    // MARK: - DEG-6: a doomed run never starts

    func testARunIsRefusedWhenStorageIsInsufficient() async {
        let harness = makeHarness(store: { makeFullDiskStore(directory: $0) })

        do {
            try await harness.model.start(activity: .outdoorRun)
            XCTFail("the run started on a full disk")
        } catch let refusal as RunStartRefusal {
            guard case .insufficientStorage = refusal else {
                return XCTFail("wrong refusal: \(refusal)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(harness.model.phase, .idle)
        XCTAssertFalse(harness.feed.isRunning, "sensors started for a refused run")
        // The refusal must land before HealthKit is even asked.
        let calls = await harness.backend.calls
        XCTAssertTrue(calls.isEmpty, "authorization was requested for a run that could not start")
    }

    func testStartingTwiceIsRefused() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        do {
            try await harness.model.start(activity: .outdoorRun)
            XCTFail("started twice")
        } catch let refusal as RunStartRefusal {
            XCTAssertEqual(refusal, .alreadyRunning)
        }
    }

    // MARK: - AC-FR-D-1-7: denial records locally

    func testAuthorizationDenialStillRunsTheRun() async throws {
        let harness = makeHarness()
        await harness.backend.setAuthorizationResult(.denied)

        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 120)

        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertEqual(harness.model.samplesRecorded, 120)

        _ = try await harness.model.end()
        let calls = await harness.backend.calls
        XCTAssertFalse(calls.contains(.endAndSave), "wrote to Health without authorization")
    }

    // MARK: - Haptics (T-042)

    /// A run held far off target long enough fires the matching pattern — and the run
    /// screen shows the warning at the same time.
    func testASustainedTooSlowPaceFiresTheSpeedUpPatternAndAWarning() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        // Well off target: 8:00 target, running about 11:00 per mile.
        run(harness, seconds: 600, metresPerSecond: 2.44)

        XCTAssertTrue(
            harness.haptics.played.contains(.speedUp),
            "a sustained slow pace fired no haptic, got \(harness.haptics.played)"
        )
        XCTAssertGreaterThan(harness.haptics.played.count, 0)
    }

    /// FR-C-4 through the whole stack: VO2 max fires transition haptics and never a pace
    /// haptic, whatever the pace. This is the requirement most likely to rot into
    /// interval behaviour, so it is asserted end to end rather than only on the mapping.
    func testVO2MaxFiresTransitionHapticsButNeverPaceHaptics() async throws {
        let harness = makeHarness(runType: .vo2max)
        try await harness.model.start(activity: .outdoorRun)

        // Deliberately erratic: sprinting, jogging, and standing still, cycling over a
        // full session. Distance accumulates — a cumulative figure that fell would be a
        // sensor impossibility and would exercise the wrong path.
        var distance = 0.0
        for second in 0..<3_000 {
            let speed: Double = switch second % 400 {
            case 0..<100: 5.5     // sprinting
            case 100..<200: 1.8   // jogging
            case 200..<300: 0.0   // stopped
            default: 3.3
            }
            distance += speed
            harness.feed.emit(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: distance,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5, longitude: -0.12,
                    altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0, heartRate: 170, distanceSource: .healthKit
            ))
            // The plan opens with an open-goal warmup, which by design never ends on its
            // own (AC-FR-C-3): without this the session would never reach a rep, and the
            // test would pass for the wrong reason — no transitions because there were
            // no steps, not because haptics were suppressed.
            if second == 60 { harness.model.requestManualAdvance() }
        }

        XCTAssertFalse(harness.haptics.played.contains(.slowDown), "VO2 max fired a pace haptic")
        XCTAssertFalse(harness.haptics.played.contains(.speedUp), "VO2 max fired a pace haptic")
        XCTAssertTrue(
            harness.haptics.played.contains(.stepTransition),
            "VO2 max fired no transition haptic"
        )
        XCTAssertFalse(harness.model.screen?.appliesZoneColour ?? true)
    }

    /// AC-FR-B-1-7 — pace haptics off leaves interval haptics working.
    func testDisablingPaceHapticsLeavesTransitionHapticsWorking() async throws {
        var profile = RunnerProfile(tempoPace: Pace(minutesPerMile: 8))
        profile.paceHapticsEnabled = false

        let harness = makeHarness(runType: .interval, profile: profile)
        try await harness.model.start(activity: .outdoorRun)

        // Past the open-goal warmup, then far enough off target for long enough that a
        // pace haptic would certainly have fired if it were still enabled.
        run(harness, seconds: 60, metresPerSecond: 2.2)
        harness.model.requestManualAdvance()
        run(harness, seconds: 1_140, metresPerSecond: 2.2, from: 60)

        XCTAssertFalse(harness.haptics.played.contains(.slowDown))
        XCTAssertFalse(harness.haptics.played.contains(.speedUp))
        XCTAssertTrue(
            harness.haptics.played.contains(.stepTransition),
            "disabling pace haptics also silenced interval haptics"
        )
    }

    // MARK: - Luminance

    /// A wrist raise re-renders immediately rather than waiting for the next tick — up
    /// to a second of stale dimmed colour would be visible.
    func testChangingLuminanceRerendersWithoutWaitingForATick() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 400)

        let bright = try XCTUnwrap(harness.model.screen)
        harness.model.luminance = .dimmed
        let dim = try XCTUnwrap(harness.model.screen)

        XCTAssertNotEqual(bright.background, dim.background)
        XCTAssertTrue(dim.isDimmed)
    }

    // MARK: - Manual advance

    func testATapOnAClosedGoalStepDoesNothing() async throws {
        let harness = makeHarness(runType: .interval)
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 60)

        // The warmup is open-goal, so advance once to reach a closed 400 m rep.
        harness.model.requestManualAdvance()
        run(harness, seconds: 2, from: 60)
        let stepAfterAdvance = harness.model.output?.step.step?.index

        harness.model.requestManualAdvance()
        run(harness, seconds: 2, from: 62)

        XCTAssertEqual(
            harness.model.output?.step.step?.index, stepAfterAdvance,
            "a tap ended a closed-goal rep early"
        )
    }

    func testPaletteChangesMidRunDoNotResetEngineState() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 400)

        let elapsedBefore = try XCTUnwrap(harness.model.output?.activeElapsed)
        var updated = harness.model.profile
        updated.palette = .colorVisionDeficiency
        harness.model.apply(profile: updated)

        run(harness, seconds: 5, from: 400)

        XCTAssertGreaterThan(try XCTUnwrap(harness.model.output?.activeElapsed), elapsedBefore)
        XCTAssertEqual(harness.model.screen?.zone, .onTarget, "a palette change reset the engine")
    }
}
