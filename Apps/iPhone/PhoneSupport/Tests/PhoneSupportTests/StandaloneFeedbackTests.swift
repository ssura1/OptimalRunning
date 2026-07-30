import Foundation
import ORAlerts
import ORColor
import ORIntervals
import ORModels
import ORPace
import XCTest

@testable import PhoneSupport

/// The three feedback channels (S-041 … S-044).
///
/// Every requirement in FR-S-D is either about *what is said*, *when it is said*, or *which
/// channels carry it* — and all three are decisions rather than rendering, which is why they
/// are testable here at all. What is deliberately not tested: whether a cue is audible over
/// wind, whether a haptic is perceptible in the hand, and whether the system voice reads
/// "7:58" the way a runner expects. Those need a runner and are on the manual protocol.
@MainActor
final class StandaloneFeedbackTests: XCTestCase {

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
            .appendingPathComponent("StandaloneFeedbackTests-\(UUID().uuidString)")
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

    // MARK: - The cue vocabulary (S-041, design.md §9.2)

    func testAPaceCueNamesTheDirectionAndTheMagnitudeButNotTheSign() throws {
        let cue = try XCTUnwrap(
            CueComposer.cue(
                for: .paceTooFast(
                    current: Pace(minutesPerMile: 7.8), target: Pace(minutesPerMile: 8)),
                runType: .tempo, unit: .miles))

        guard case let .pace(direction, seconds) = cue.kind else {
            return XCTFail("expected a pace cue, got \(cue.kind)")
        }
        XCTAssertEqual(direction, .easeOff)
        XCTAssertEqual(seconds, 12)
        XCTAssertEqual(cue.phrase, "Ease off. 12 seconds fast.")
        XCTAssertFalse(
            cue.phrase.contains("-"),
            "the direction is carried by the verb; a signed number would have to be decoded")
    }

    func testATooSlowCueSaysPickItUp() throws {
        let cue = try XCTUnwrap(
            CueComposer.cue(
                for: .paceTooSlow(
                    current: Pace(minutesPerMile: 8.15), target: Pace(minutesPerMile: 8)),
                runType: .easy, unit: .miles))
        XCTAssertEqual(cue.phrase, "Pick it up. 9 seconds slow.")
    }

    func testVO2MaxNeverProducesAPaceCue() {
        // FR-C-4, restated for audio. `RunEngine` already suppresses these; asserting it
        // again on the way out makes a future refactor that breaks the suppression fail
        // here rather than ship.
        let alert = AlertCommand.paceTooFast(
            current: Pace(minutesPerMile: 6), target: Pace(minutesPerMile: 8))
        XCTAssertNil(CueComposer.cue(for: alert, runType: .vo2max, unit: .miles))
        XCTAssertNotNil(CueComposer.cue(for: alert, runType: .tempo, unit: .miles))
    }

    func testAStepTransitionCueNamesTheStepAndItsGoal() throws {
        let transition = StepTransition(
            from: ResolvedStep(
                index: 0, kind: .work, goal: .distance(metres: 1000), target: nil,
                repIndex: 1, repCount: 4),
            to: ResolvedStep(
                index: 1, kind: .recovery, goal: .distance(metres: 400), target: nil,
                repIndex: 1, repCount: 4),
            wasAutomatic: true, completedDistanceMetres: 1000,
            completedActiveSeconds: 240, atActiveElapsed: 240)

        let cue = try XCTUnwrap(
            CueComposer.cue(for: .stepTransition(transition), runType: .interval, unit: .miles))
        XCTAssertEqual(cue.phrase, "Recovery. 400 metres.")
    }

    func testAnOpenGoalStepAnnouncesItsNameAndNothingElse() throws {
        // Announcing "until you tap" would be telling the runner to look at a screen this
        // whole tier is designed around them not looking at.
        let transition = StepTransition(
            from: ResolvedStep(
                index: 0, kind: .work, goal: .distance(metres: 1000), target: nil,
                repIndex: 1, repCount: 1),
            to: ResolvedStep(
                index: 1, kind: .cooldown, goal: .open, target: nil,
                repIndex: 1, repCount: 1),
            wasAutomatic: true, completedDistanceMetres: 1000,
            completedActiveSeconds: 240, atActiveElapsed: 240)

        let cue = try XCTUnwrap(
            CueComposer.cue(for: .stepTransition(transition), runType: .interval, unit: .miles))
        XCTAssertEqual(cue.phrase, "Cool down.")
    }

    func testEveryCueKindHasADistinguishableHapticPattern() {
        // AC-FR-S-D-2-1: distinguishable *by direction*. The two pace directions must not
        // collide, and neither may collide with the structural patterns.
        let easeOff = SpokenCue(kind: .pace(.easeOff, secondsOff: 5), phrase: "")
        let pickUp = SpokenCue(kind: .pace(.pickItUp, secondsOff: 5), phrase: "")
        let step = SpokenCue(kind: .stepTransition(.work), phrase: "")
        let complete = SpokenCue(kind: .workoutComplete, phrase: "")

        let patterns = [easeOff, pickUp, step, complete].map(StandaloneHaptics.pattern(for:))
        XCTAssertEqual(
            Set(patterns).count, 4,
            "the four commands must feel different from each other")
        XCTAssertEqual(StandaloneHaptics.pattern(for: easeOff), .slowDown)
        XCTAssertEqual(StandaloneHaptics.pattern(for: pickUp), .speedUp)
    }

    // MARK: - Channel independence (AC-FR-S-D-1-7, AC-FR-S-D-2-4)

    func testDisablingSpokenCuesLeavesHapticsAsACompleteChannel() async throws {
        var profile = RunnerProfile.standaloneDefault
        profile.spokenCuesEnabled = false
        let h = makeHarness(profile: profile)
        try await h.controller.start()

        driveUntilAnAlertFires(h)

        XCTAssertTrue(h.cues.spoken.isEmpty, "nothing may be spoken")
        XCTAssertFalse(h.haptics.played.isEmpty, "h.haptics must still carry the alert")
    }

    func testDisablingPaceHapticsLeavesIntervalHapticsWorking() async throws {
        var profile = RunnerProfile.standaloneDefault
        profile.paceHapticsEnabled = false
        let h = makeHarness(plan: .intervals(), profile: profile)
        try await h.controller.start()

        for tick in 1...400 {
            h.feed.emit(
                .running(at: Double(tick), metresPerSecond: 4.0),
                telemetry: .runningTelemetry(at: tick))
        }

        XCTAssertFalse(
            h.haptics.played.contains(.slowDown) || h.haptics.played.contains(.speedUp),
            "pace h.haptics are off")
        XCTAssertTrue(
            h.haptics.played.contains(.stepTransition),
            "interval h.haptics must be unaffected: \(h.haptics.played)")
    }

    func testDisablingSplitAnnouncementsLeavesPaceCuesSpeaking() async throws {
        var profile = RunnerProfile.standaloneDefault
        profile.splitAnnouncementsEnabled = false
        let h = makeHarness(profile: profile)
        try await h.controller.start()

        driveUntilAnAlertFires(h)

        XCTAssertFalse(
            h.cues.spoken.contains { if case .split = $0.kind { return true } else { return false } },
            "splits are off")
        XCTAssertTrue(
            h.cues.spoken.contains { if case .pace = $0.kind { return true } else { return false } },
            "pace h.cues are a different channel and must be unaffected")
    }

    // MARK: - Splits (S-042)

    func testSplitsFireAtExactUnitBoundariesInTheRunnersUnits() {
        var announcer = SplitAnnouncer(profile: .standaloneDefault)  // miles
        var fired: [Int] = []

        // Three miles at a steady 3 m/s.
        for second in 1...1700 {
            let produced = announcer.tick(
                cumulativeDistance: Double(second) * 3.0,
                activeElapsed: Double(second),
                averagePace: Pace(minutesPerMile: 8.9))
            for cue in produced {
                if case let .split(index) = cue.kind { fired.append(index) }
            }
        }

        XCTAssertEqual(fired, [1, 2, 3], "one announcement per boundary, in order")
    }

    func testSplitsUseKilometresWhenThatIsTheRunnersPreference() {
        var profile = RunnerProfile.standaloneDefault
        profile.units = .kilometres
        var announcer = SplitAnnouncer(profile: profile)
        var phrases: [String] = []

        for second in 1...700 {
            phrases += announcer.tick(
                cumulativeDistance: Double(second) * 3.0,
                activeElapsed: Double(second),
                averagePace: Pace(minutesPerKilometre: 5.5)
            ).map(\.phrase)
        }

        XCTAssertEqual(phrases.count, 2)
        XCTAssertTrue(phrases[0].hasPrefix("Kilometre 1."), phrases[0])
    }

    func testASplitIsNotAnnouncedTwiceWhenDistanceStalls() {
        var announcer = SplitAnnouncer(profile: .standaloneDefault)
        let mile = UnitPreference.miles.metresPerUnit
        var count = 0

        // Cross the boundary, then hover on it for a minute — a stationary runner at a
        // traffic light one metre past mile one.
        for second in 1...60 {
            count += announcer.tick(
                cumulativeDistance: mile + 1,
                activeElapsed: Double(second),
                averagePace: Pace(minutesPerMile: 9)).count
        }
        XCTAssertEqual(count, 1)
    }

    func testAJumpPastSeveralBoundariesAnnouncesEachOne() {
        // A GNSS re-anchor after a long outage can advance cumulative distance past more
        // than one boundary in a tick. Announcing only the latest would silently skip a
        // mile from the runner's record of what was said.
        var announcer = SplitAnnouncer(profile: .standaloneDefault)
        let mile = UnitPreference.miles.metresPerUnit

        let produced = announcer.tick(
            cumulativeDistance: mile * 3.5, activeElapsed: 1500,
            averagePace: Pace(minutesPerMile: 8))
        let indices = produced.compactMap { cue -> Int? in
            if case let .split(index) = cue.kind { return index }
            return nil
        }
        XCTAssertEqual(indices, [1, 2, 3])
    }

    func testSplitsAndPaceAlertsDoNotSuppressEachOther() async throws {
        // ADR-S-05's reason for the separate channel, as a test: a runner who crosses a
        // mile boundary while drifting fast needs both sentences.
        let h = makeHarness()
        try await h.controller.start()

        let mile = UnitPreference.miles.metresPerUnit
        // Run fast enough to earn a pace alert, far enough to cross a mile.
        for second in 1...700 {
            h.feed.emit(
                .running(at: Double(second), metresPerSecond: mile / 420),
                telemetry: .runningTelemetry(at: second))
        }

        let hasSplit = h.cues.spoken.contains {
            if case .split = $0.kind { return true } else { return false }
        }
        let hasPace = h.cues.spoken.contains {
            if case .pace = $0.kind { return true } else { return false }
        }
        XCTAssertTrue(hasSplit, "the mile boundary must be announced: \(h.cues.phrases)")
        XCTAssertTrue(hasPace, "the pace excursion must be announced: \(h.cues.phrases)")
    }

    func testTimeAnnouncementsAreOffByDefaultAndWorkWhenTurnedOn() {
        var off = SplitAnnouncer(profile: .standaloneDefault)
        let silent = (1...1000).flatMap { second in
            off.tick(
                cumulativeDistance: 0, activeElapsed: Double(second),
                averagePace: nil)
        }
        XCTAssertTrue(silent.isEmpty, "AC-FR-S-D-1-5: off by default")

        var profile = RunnerProfile.standaloneDefault
        profile.splitAnnouncementsEnabled = false
        profile.timeAnnouncementIntervalSeconds = 300
        var on = SplitAnnouncer(profile: profile)
        let spoken = (1...1000).flatMap { second in
            on.tick(
                cumulativeDistance: Double(second) * 3, activeElapsed: Double(second),
                averagePace: Pace(minutesPerMile: 9))
        }
        XCTAssertEqual(spoken.count, 3, "every five minutes over sixteen and a half")
    }

    // MARK: - The GNSS notice, said once (AC-FR-S-C-3-3)

    func testTheGNSSNoticeIsSaidOncePerTransitionAndNotRepeatedly() async throws {
        let h = makeHarness()
        try await h.controller.start()

        // Twenty seconds of good fixes, then two minutes without one.
        for second in 1...20 {
            h.feed.emit(.running(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }
        for second in 21...140 {
            h.feed.emit(
                .running(at: Double(second), source: .motionModel, hasFix: false),
                telemetry: .runningTelemetry(
                    at: second, estimatedMetres: Double(second - 20) * 3,
                    flags: [.distanceEstimated]))
        }

        let lost = h.cues.spoken.filter {
            if case .gnssLost = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(lost.count, 1, "said once, not once a second: \(h.cues.phrases.count) h.cues")
        XCTAssertEqual(lost.first?.phrase, "GPS signal lost. Pace is estimated.")

        // And once more when it comes back.
        for second in 141...200 {
            h.feed.emit(.running(at: Double(second)), telemetry: .runningTelemetry(at: second))
        }
        let restored = h.cues.spoken.filter {
            if case .gnssRestored = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(restored.count, 1)
    }

    // MARK: - The screen (S-044)

    func testEveryZoneRendersAGlyphAndAColourWithNoNewLiteral() {
        for zone in PaceZone.allCases {
            let screen = StandaloneMetricsScreen.make(
                output: .stub(zone: zone),
                telemetry: .runningTelemetry(at: 10),
                runType: .tempo,
                profile: .standaloneDefault,
                activity: .outdoorRun)

            XCTAssertFalse(
                screen.glyphSymbolName.isEmpty,
                "\(zone) must carry a non-colour channel (FR-J-1)")
            // The swatch came from ORColor's verified palette; asserting it matches that
            // palette's own value is what makes "no new colour literal" checkable.
            let expected = ZonePalette.palette(for: .standard).swatch(for: zone).background
            XCTAssertEqual(screen.background, expected)
        }
    }

    func testTheLayoutDoesNotReflowBetweenZones() {
        // AC-FR-S-D-3-3 — glance targets must not move. The structural form of that
        // requirement is that no metric field is ever absent: an empty value formats to
        // `--`, it does not disappear.
        for zone in PaceZone.allCases {
            let screen = StandaloneMetricsScreen.make(
                output: .stub(zone: zone, rollingPace: nil, effectiveTarget: nil),
                telemetry: .empty,
                runType: .tempo,
                profile: .standaloneDefault,
                activity: .outdoorRun)

            XCTAssertFalse(screen.primaryMetricText.isEmpty)
            XCTAssertFalse(screen.elapsedText.isEmpty)
            XCTAssertFalse(screen.distanceText.isEmpty)
            XCTAssertFalse(screen.averagePaceText.isEmpty)
            XCTAssertFalse(screen.targetPaceText.isEmpty)
            XCTAssertFalse(screen.cadenceText.isEmpty)
            XCTAssertEqual(screen.cadenceText, "--", "absent cadence is `--`, never 0")
        }
    }

    func testTheSignedDeltaAccompaniesEveryDirectionalZone() {
        let directional = PaceZone.allCases.filter(\.isFarOff)
        // A `for … where` loop over an empty set passes without asserting anything, which
        // is the shape of test that reports coverage it does not have.
        XCTAssertFalse(directional.isEmpty)

        for zone in directional {
            let screen = StandaloneMetricsScreen.make(
                output: .stub(
                    zone: zone,
                    rollingPace: Pace(minutesPerMile: 7.8),
                    effectiveTarget: Pace(minutesPerMile: 8)),
                telemetry: .runningTelemetry(at: 5),
                runType: .tempo,
                profile: .standaloneDefault,
                activity: .outdoorRun)
            XCTAssertNotNil(screen.signedDeltaText, "\(zone) must show a signed delta")
        }
    }

    func testVO2MaxRendersNeutralAtEveryPace() {
        for zone in PaceZone.allCases {
            let screen = StandaloneMetricsScreen.make(
                output: .stub(zone: zone),
                telemetry: .runningTelemetry(at: 5),
                runType: .vo2max,
                profile: .standaloneDefault,
                activity: .outdoorRun)
            XCTAssertFalse(screen.appliesZoneColour)
            XCTAssertEqual(screen.zone, .neutral)
        }
    }

    func testCadenceIsShownAsAFirstClassMetric() {
        let screen = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget),
            telemetry: .runningTelemetry(at: 5),
            runType: .tempo,
            profile: .standaloneDefault,
            activity: .outdoorRun)
        XCTAssertEqual(screen.cadenceText, "168")
    }

    // MARK: - Degraded modes on screen

    func testAnIndoorRunShowsTheTimedOnlyTreatmentAndSaysWhy() {
        // DEG-S-6, CON-S-8. The requirement is not "hide distance" — it is "suppressed and
        // *stated* as suppressed", because a blank field reads as a bug.
        let screen = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget),
            telemetry: .empty,
            runType: .easy,
            profile: .standaloneDefault,
            activity: .indoorRun)

        XCTAssertTrue(screen.isTimedOnly)
        XCTAssertEqual(screen.distanceText, "--")
        XCTAssertEqual(screen.averagePaceText, "--")
        XCTAssertEqual(screen.primaryMetricCaption, "Elapsed")
        XCTAssertFalse(screen.appliesZoneColour, "there is no pace to judge")
        let notice = try? XCTUnwrap(screen.statusNotice)
        XCTAssertTrue(notice?.contains("Indoor") ?? false, "\(screen.statusNotice ?? "nil")")
        XCTAssertNil(screen.signedDeltaText)
    }

    func testALostFixIsStatedDifferentlyDependingOnWhetherThereIsACalibration() {
        // DEG-S-1 versus DEG-S-2: with a h.calibration the run continues on estimated
        // distance; without one there is no distance at all, and saying "pace estimated"
        // would be claiming an estimate that does not exist (ADR-S-06).
        let calibrated = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget, isGPSDegraded: true),
            telemetry: .runningTelemetry(at: 5, flags: [.distanceEstimated]),
            runType: .tempo, profile: .standaloneDefault, activity: .outdoorRun)
        XCTAssertEqual(calibrated.statusNotice, "GPS lost — pace estimated")
        XCTAssertTrue(calibrated.isPaceEstimated)

        let uncalibrated = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget, isGPSDegraded: true),
            telemetry: .empty,
            runType: .tempo, profile: .standaloneDefault, activity: .outdoorRun)
        XCTAssertEqual(uncalibrated.statusNotice, "GPS lost — no distance")
    }

    func testACarryPositionChangeIsSurfacedAheadOfEverythingElse() {
        // DEG-S-7. It outranks the GPS notice because it is the only one the runner can
        // act on — putting the phone back in their hand restores the signal.
        let screen = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget, isGPSDegraded: true),
            telemetry: .runningTelemetry(at: 5, flags: [.carryPositionChanged]),
            runType: .tempo, profile: .standaloneDefault, activity: .outdoorRun)
        XCTAssertEqual(screen.statusNotice, "Hold the phone in your hand for pace")
    }

    func testSampleStarvationSuppressesCadenceRatherThanShowingABadOne() {
        // DEG-S-3 / AC-FR-S-B-1-4.
        let screen = StandaloneMetricsScreen.make(
            output: .stub(zone: .onTarget),
            telemetry: MotionTelemetry(
                cadenceStepsPerMinute: nil, cadenceConfidence: 0, stepCount: 12,
                measuredMetres: 100, estimatedMetres: 0,
                calibration: .uncalibrated, flags: [.sampleStarvation]),
            runType: .tempo, profile: .standaloneDefault, activity: .outdoorRun)

        XCTAssertEqual(screen.cadenceText, "--")
        XCTAssertEqual(screen.statusNotice, "Cadence unavailable")
    }

    // MARK: - Helpers

    /// Runs fast enough, for long enough, that `AlertPolicy`'s dwell is satisfied.
    private func driveUntilAnAlertFires(_ h: Harness) {
        for second in 1...120 {
            h.feed.emit(
                .running(at: Double(second), metresPerSecond: 4.5),
                telemetry: .runningTelemetry(at: second))
        }
    }
}

// MARK: - Output stubs

extension EngineOutput {

    /// A rendered-state stub. Reaching a specific zone by driving a real engine would mean
    /// searching for input that lands on it, which tests presentation *through* the
    /// engine's correctness rather than independently of it — the reason `EngineOutput`'s
    /// memberwise initializer is public.
    static func stub(
        zone: PaceZone,
        rollingPace: Pace? = Pace(minutesPerMile: 8.2),
        effectiveTarget: Pace? = Pace(minutesPerMile: 8),
        isGPSDegraded: Bool = false,
        activeElapsed: TimeInterval = 600,
        cumulativeDistance: Double = 2000
    ) -> EngineOutput {
        EngineOutput(
            zone: zone,
            rollingPace: rollingPace,
            averagePace: Pace(minutesPerMile: 8.1),
            rawTarget: effectiveTarget,
            effectiveTarget: effectiveTarget,
            gradeFactor: .identity,
            smoothedGrade: 0,
            isGradeSignificant: false,
            isGradeAvailable: true,
            isGPSDegraded: isGPSDegraded,
            isStationary: false,
            isSettling: false,
            progress: 0.5,
            activeElapsed: activeElapsed,
            cumulativeDistance: cumulativeDistance,
            heartRate: nil,
            step: StepState(
                phase: .running, step: nil, stepDistanceMetres: 0, stepActiveSeconds: 0,
                distanceRemainingMetres: nil, timeRemainingSeconds: nil,
                isCountingDown: false, canAdvanceManually: false, isUndoAvailable: false),
            stepTransition: nil,
            alert: nil,
            degradations: [],
            sample: RunSample(
                timestamp: activeElapsed,
                cumulativeDistance: cumulativeDistance,
                rollingPace: rollingPace,
                heartRate: nil,
                relativeAltitude: 0,
                smoothedGrade: 0,
                gradeFactor: .identity,
                rawTarget: effectiveTarget,
                effectiveTarget: effectiveTarget,
                zone: zone))
    }
}
