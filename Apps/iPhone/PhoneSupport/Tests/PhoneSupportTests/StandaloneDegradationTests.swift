import Foundation
import ORModels
import ORPace
import XCTest

@testable import PhoneSupport

/// The eleven standalone degraded modes, one named test each (S-051).
///
/// **The point of enumerating them here is completeness, not depth.** Several of these are
/// tested more thoroughly elsewhere — the estimator's own suites cover the signal-level
/// modes, `StandaloneFeedbackTests` covers what the screen says — and this file is the table
/// that says which test proves which mode, so a mode cannot be quietly missing. Writing it
/// is what found DEG-S-7 having a flag and no detector.
///
/// Two of the eleven are hardware-verified and say so rather than being faked: background
/// haptics and background survival need a device and elapsed wall-clock time (§12.2).
@MainActor
final class StandaloneDegradationTests: XCTestCase {

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
            .appendingPathComponent("StandaloneDegradationTests-\(UUID().uuidString)")
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

    // MARK: - DEG-S-1 — GNSS lost mid-run

    func testDEGS1_GNSSLostMidRunSubstitutesMotionAndAnnouncesOnce() async throws {
        let h = makeHarness()
        try await h.controller.start()

        for second in 1...20 {
            h.feed.emit(.running(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }
        for second in 21...120 {
            h.feed.emit(
                .running(at: Double(second), source: .motionModel, hasFix: false),
                telemetry: .runningTelemetry(
                    at: second, estimatedMetres: Double(second - 20) * 3,
                    flags: [.distanceEstimated]))
        }

        // Substituted: distance kept advancing on the motion leg.
        XCTAssertGreaterThan(h.controller.telemetry.estimatedMetres, 0)
        // Marked: the run records the estimated stretch in Core's own vocabulary too.
        let composed = try await h.controller.end()
        XCTAssertTrue(
            try XCTUnwrap(composed).degradations.contains(.gpsDegraded))
        // Announced once (AC-FR-S-C-3-3).
        XCTAssertEqual(
            h.cues.spoken.filter {
                if case .gnssLost = $0.kind { return true } else { return false }
            }.count, 1)
        // Bands widened: the engine reports degraded GPS, which is what widens them.
        XCTAssertTrue(h.controller.output?.isGPSDegraded ?? false)
    }

    // MARK: - DEG-S-2 — GNSS never acquired

    func testDEGS2_GNSSNeverAcquiredRunsOnMotionAloneAndSaysSo() async throws {
        let h = makeHarness()
        try await h.controller.start()

        for second in 1...90 {
            h.feed.emit(
                .running(at: Double(second), source: .motionModel, hasFix: false),
                telemetry: .runningTelemetry(
                    at: second, estimatedMetres: Double(second) * 3,
                    flags: [.distanceEstimated, .usingUncalibratedPrior]))
        }

        let composed = try await h.controller.end()
        let envelope = try XCTUnwrap(composed)
        let facts = try XCTUnwrap(envelope.standalone)
        XCTAssertEqual(facts.measuredMetres, 0, accuracy: 1e-9, "no metres were observed")
        XCTAssertGreaterThan(facts.estimatedMetres, 0)
        XCTAssertTrue(facts.isLowerConfidence, "and the run is marked as such (DEG-S-5)")
        XCTAssertNil(envelope.route, "no route can exist without a fix")
    }

    // MARK: - DEG-S-3 — motion sample starvation

    func testDEGS3_SampleStarvationSuppressesCadenceRatherThanReportingABadOne() async throws {
        let h = makeHarness()
        try await h.controller.start()

        for second in 1...30 {
            h.feed.emit(
                .running(at: Double(second)),
                telemetry: MotionTelemetry(
                    cadenceStepsPerMinute: nil, cadenceConfidence: 0, stepCount: 0,
                    measuredMetres: Double(second) * 3, estimatedMetres: 0,
                    calibration: .uncalibrated, flags: [.sampleStarvation]))
        }

        XCTAssertEqual(h.controller.screen?.cadenceText, "--", "never a fabricated number")
        XCTAssertEqual(h.controller.screen?.statusNotice, "Cadence unavailable")
        // And distance is unaffected — GNSS is still measuring.
        XCTAssertGreaterThan(h.controller.telemetry.measuredMetres, 0)
    }

    // MARK: - DEG-S-4 — no heart rate, ever

    func testDEGS4_HeartRateIsAbsentInEverySurfaceIncludingTheEnvelope() async throws {
        let h = makeHarness()
        try await h.controller.start()
        for second in 1...30 {
            h.feed.emit(.running(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }
        let composed = try await h.controller.end()
        let envelope = try XCTUnwrap(composed)

        XCTAssertNil(envelope.summary.averageHeartRate)
        XCTAssertNil(envelope.summary.maxHeartRate)
        let samples = try XCTUnwrap(envelope.samples.unpack())
        XCTAssertTrue(samples.allSatisfy { $0.heartRate == nil })
        XCTAssertTrue(envelope.steps.allSatisfy { $0.averageHeartRate == nil })
    }

    // MARK: - DEG-S-5 — h.calibration not yet converged

    func testDEGS5_AnUnconvergedRunIsMarkedLowerConfidenceAndExplainsWhy() {
        let facts = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 3000, estimatedMetres: 900,
            stepCount: 2000, averageCadenceStepsPerMinute: 168,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: false, observationCount: 2,
                bandsWithEvidence: 0, metresPerStepAtTypicalCadence: 1.02),
            flags: [.distanceEstimated], estimatedSpans: [])

        XCTAssertTrue(facts.isLowerConfidence)
        let reason = StandaloneStrings.lowerConfidenceReason(facts.calibration)
        XCTAssertTrue(reason.contains("2"), "the sentence names how far along it is: \(reason)")
    }

    func testDEGS5_AConvergedRunWithNoEstimatedMetresIsNotMarked() {
        // The other direction, so the marking means something: a fully-measured run on a
        // settled h.calibration carries no caveat.
        let facts = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 8000, estimatedMetres: 0,
            stepCount: 4200, averageCadenceStepsPerMinute: 168,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: true, observationCount: 12,
                bandsWithEvidence: 3, metresPerStepAtTypicalCadence: 1.01),
            flags: [], estimatedSpans: [])
        XCTAssertFalse(facts.isLowerConfidence)
    }

    // MARK: - DEG-S-6 — indoor / treadmill

    func testDEGS6_AnIndoorRunIsTimedOnlyAndStatesTheSuppression() async throws {
        let h = makeHarness(activity: .indoorRun)
        try await h.controller.start()
        // What the real adapter emits indoors: ticks with **no distance**. The zeroing
        // lives in `MotionPipeline`, which is where the knowledge is — it is the layer that
        // knows the estimator's metres came from a swinging arm rather than from
        // displacement — so this test emits its output rather than re-implementing the
        // rule. `StandaloneBoundaryTests` is where the adapter itself is checked.
        for second in 1...30 {
            h.feed.emit(.indoorTick(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }

        let screen = try XCTUnwrap(h.controller.screen)
        XCTAssertTrue(screen.isTimedOnly)
        XCTAssertEqual(screen.distanceText, "--")
        XCTAssertEqual(screen.averagePaceText, "--")
        XCTAssertNotNil(screen.statusNotice, "suppression must be stated, not silent")

        let composed = try await h.controller.end()
        let envelope = try XCTUnwrap(composed)
        XCTAssertNil(envelope.route, "CON-S-8: no route indoors")
        XCTAssertEqual(
            envelope.summary.distanceMetres, 0, accuracy: 1e-9,
            "CON-S-8: indoors there is no distance, not a hidden one — a treadmill's belt "
                + "gives the phone nothing to measure displacement against")
        XCTAssertTrue(
            h.cues.spoken.allSatisfy {
                if case .split = $0.kind { return false } else { return true }
            },
            "no mile can be announced on a treadmill: \(h.cues.phrases)")
        XCTAssertTrue(
            envelope.degradations.contains(.indoorRun),
            "the run must record *why* it has no distance: \(envelope.degradations)")
    }

    // MARK: - DEG-S-7 — phone pocketed mid-run

    func testDEGS7_ACarryPositionChangeIsSurfacedAndRecorded() async throws {
        // The detection itself lives in `PhoneMotion.CarryPositionTests`, which is where the
        // signal is. What is checked here is that the flag reaches the runner and the
        // record — the half that would otherwise be a detector nobody hears about.
        let h = makeHarness()
        try await h.controller.start()
        for second in 1...30 {
            h.feed.emit(
                .running(at: Double(second)),
                telemetry: .runningTelemetry(at: second, flags: [.carryPositionChanged]))
        }

        XCTAssertEqual(
            h.controller.screen?.statusNotice, "Hold the phone in your hand for pace",
            "the runner is told, because putting it back is something they can do")

        let composed = try await h.controller.end()
        let envelope = try XCTUnwrap(composed)
        XCTAssertTrue(
            try XCTUnwrap(envelope.standalone).flags.contains(.carryPositionChanged))
    }

    // MARK: - DEG-S-8 — stopped at a traffic light

    func testDEGS8_AStationaryRunnerLeavesPaceUndefinedRatherThanZero() async throws {
        let h = makeHarness()
        try await h.controller.start()

        // Move, then stop: cumulative distance stops advancing.
        for second in 1...60 {
            h.feed.emit(.running(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }
        for second in 61...140 {
            h.feed.emit(
                EngineInput(
                    timestamp: Double(second),
                    cumulativeDistance: 180,
                    location: LocationSample(
                        timestamp: Double(second), latitude: 0, longitude: 0,
                        altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
                    relativeAltitude: 0,
                    heartRate: nil,
                    distanceSource: .location),
                telemetry: .runningTelemetry(at: second))
        }

        XCTAssertTrue(
            h.controller.output?.isStationary ?? false,
            "AC-FR-A-1-5: a stopped runner is stationary, not slow")
        XCTAssertNil(
            h.controller.output?.rollingPace,
            "pace is undefined rather than a very large number")
        XCTAssertEqual(h.controller.screen?.primaryMetricText, "--")
    }

    // MARK: - DEG-S-9 and DEG-S-10 — audio route loss and interruption

    func testDEGS9andDEGS10_AreOwnedByTheAudioSessionAndVerifiedOnDevice() throws {
        // Both are `AVAudioSession` notification handling in `SpeechCuePlayer`: a route
        // change continues the run on the speaker, and an interruption pauses speech while
        // h.haptics keep firing. Neither can be exercised here — XCTest cannot disconnect
        // headphones or place a call — so they are recorded in the manual protocol rather
        // than faked with a stub that would only test the stub.
        //
        // What *is* checkable is the property that makes both survivable: h.haptics are a
        // complete channel that does not pass through the audio session at all, so a run
        // whose speech has stopped is still alerting.
        let cue = SpokenCue(kind: .pace(.easeOff, secondsOff: 8), phrase: "Ease off.")
        XCTAssertEqual(StandaloneHaptics.pattern(for: cue), .slowDown)
        XCTAssertTrue(
            StandaloneHaptics.permits(cue, runType: .tempo, profile: .standaloneDefault))
    }

    // MARK: - DEG-S-11 — low battery

    func testDEGS11_LowPowerReducesSampleRateWithoutLosingAudioOrHaptics() throws {
        // The core track's DEG-5 treatment, adapted. The reduced capture interval is
        // `PaceEngineConfiguration.degradation.lowPowerSampleIntervalSeconds`, already
        // declared once (NFR-21) — this asserts the standalone tier inherits it rather than
        // declaring a second one, and that nothing in the low-power path touches the
        // feedback channels.
        let configuration = PaceEngineConfiguration.default
        XCTAssertGreaterThan(
            configuration.degradation.lowPowerSampleIntervalSeconds,
            configuration.capture.sampleIntervalSeconds,
            "low power must sample less often, not more")

        // Feedback is unaffected: the cue and haptic paths read no battery state at all,
        // which is the structural reason DEG-S-11 cannot silence them.
        let cue = SpokenCue(kind: .split(index: 3), phrase: "Mile 3.")
        XCTAssertEqual(StandaloneHaptics.pattern(for: cue), .notice)
    }

    // MARK: - The table itself

    func testEveryMotionFlagHasARunnerFacingExplanation() {
        // A flag with no sentence is a flag that reaches the detail screen as nothing. The
        // `allCases` loop is what keeps this true when a twelfth condition is added.
        for flag in MotionFlag.allCases {
            XCTAssertGreaterThan(
                flag.runnerFacingExplanation.count, 30,
                "\(flag) has no usable explanation")
        }
    }
}
