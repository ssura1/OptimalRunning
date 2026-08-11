import XCTest
import ORColor
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// The work/recovery marker (T-104).
///
/// The requested change was "single letter, distinct colours", and the note attached to it
/// was that this already satisfies FR-J-1 because the letterforms differ as well as the
/// colours — *confirm that, don't assume it*. So the redundancy is asserted here on the
/// values the view actually renders, not inferred from the design intent.
final class StepMarkerTests: XCTestCase {

    private func state(_ kind: StepKind, repIndex: Int = 3, repCount: Int = 4) -> StepState {
        StepState(
            phase: .running,
            step: ResolvedStep(
                index: 2, kind: kind, goal: .distance(metres: 1_000),
                target: nil, repIndex: repIndex, repCount: repCount
            ),
            stepDistanceMetres: 660,
            stepActiveSeconds: 150,
            distanceRemainingMetres: 340,
            timeRemainingSeconds: nil,
            isCountingDown: false,
            canAdvanceManually: false,
            isUndoAvailable: false
        )
    }

    // MARK: - The letterform channel

    /// The two labels differ as *strings*, which is the channel that survives every colour
    /// vision deficiency. If this ever collapsed — both becoming a bullet, say, or both an
    /// empty string with only the chip carrying meaning — colour would silently become the
    /// only channel and FR-J-1 would be violated with every other test still green.
    func testWorkAndRecoveryRenderDifferentLetters() {
        let work = RunStrings.stepKindCompact(.work)
        let recovery = RunStrings.stepKindCompact(.recovery)

        XCTAssertEqual(work, "W")
        XCTAssertEqual(recovery, "R")
        XCTAssertNotEqual(work, recovery, "the letterform channel has collapsed")
        XCTAssertFalse(work.isEmpty)
        XCTAssertFalse(recovery.isEmpty)
    }

    /// Warm-up keeps its words, so a bare `W` never means two different things.
    func testWarmupAndCooldownKeepTheirWords() {
        XCTAssertEqual(RunStrings.stepKindCompact(.warmup), "WARM UP")
        XCTAssertEqual(RunStrings.stepKindCompact(.cooldown), "COOL DOWN")
        XCTAssertNotEqual(
            RunStrings.stepKindCompact(.warmup), RunStrings.stepKindCompact(.work),
            "warm-up abbreviated to W would collide with work")
    }

    /// Only the alternating pair gets a chip.
    func testOnlyWorkAndRecoveryTakeAChip() {
        XCTAssertEqual(RunStrings.accentKind(for: .work), .work)
        XCTAssertEqual(RunStrings.accentKind(for: .recovery), .recovery)
        XCTAssertNil(RunStrings.accentKind(for: .warmup))
        XCTAssertNil(RunStrings.accentKind(for: .cooldown))
    }

    // MARK: - The colour channel, as the screen resolves it

    /// The screen hands the view a resolved chip for work and recovery, and none for the
    /// steps that render as plain words.
    func testTheScreenResolvesAChipForTheAlternatingSteps() {
        for (kind, expected) in [(StepKind.work, "W"), (.recovery, "R")] {
            let screen = MetricsScreen.make(
                output: TestOutput.make(step: state(kind)),
                runType: .interval, profile: TestOutput.profile(), luminance: .normal
            )
            XCTAssertEqual(screen.stepKindLabel, expected)
            XCTAssertNotNil(screen.stepAccent, "\(kind) should carry a chip")
        }

        for kind in [StepKind.warmup, .cooldown] {
            let screen = MetricsScreen.make(
                output: TestOutput.make(step: state(kind)),
                runType: .interval, profile: TestOutput.profile(), luminance: .normal
            )
            XCTAssertNil(screen.stepAccent, "\(kind) should render as plain text")
        }
    }

    /// The two chips the runner sees in one workout are actually different colours, and
    /// each is legible where it lands. `DataChecks.palettes()` proves this across every
    /// palette and luminance state; this proves the *screen* is wired to that machinery
    /// rather than resolving both kinds to the same swatch.
    func testTheTwoChipsAreDifferentAndLegibleOnTheSameScreen() throws {
        let work = try XCTUnwrap(MetricsScreen.make(
            output: TestOutput.make(step: state(.work)),
            runType: .interval, profile: TestOutput.profile(), luminance: .normal).stepAccent)
        let recovery = try XCTUnwrap(MetricsScreen.make(
            output: TestOutput.make(step: state(.recovery)),
            runType: .interval, profile: TestOutput.profile(), luminance: .normal).stepAccent)

        XCTAssertNotEqual(work.fill, recovery.fill)
        XCTAssertGreaterThanOrEqual(ColorScience.deltaE(work.fill, recovery.fill), 25)
        XCTAssertGreaterThanOrEqual(work.letterContrastRatio, 4.5)
        XCTAssertGreaterThanOrEqual(recovery.letterContrastRatio, 4.5)
    }

    /// The chip is resolved against the background it will actually sit on, in both
    /// luminance states. A chip picked against the normal swatch and drawn on the dimmed
    /// one is the always-on bug this guards.
    func testTheChipIsResolvedAgainstTheScreenItSitsOn() {
        for luminance in LuminanceState.allCases {
            let screen = MetricsScreen.make(
                output: TestOutput.make(step: state(.work)),
                runType: .interval, profile: TestOutput.profile(), luminance: luminance
            )
            guard let accent = screen.stepAccent else { return XCTFail("no chip") }
            XCTAssertGreaterThanOrEqual(
                accent.fillContrastRatio(against: screen.background), 3.0,
                "the \(luminance) chip does not read on the \(luminance) background")
        }
    }

    // MARK: - The header the chip came out of

    /// The kind is removed from the detail line, and nothing else is.
    func testTheDetailLineCarriesEverythingButTheKind() {
        XCTAssertEqual(
            IntervalPresentation.stepDetail(for: state(.work), unit: .miles),
            "REP 3/4 · 340 m to go")
    }

    /// VoiceOver still hears the whole words. "W, REP 3 of 4" is a worse thing to hear than
    /// it is to see, so `stepHeaderText` is deliberately unchanged.
    func testSpokenHeaderStillUsesFullWords() {
        XCTAssertEqual(
            IntervalPresentation.stepHeader(for: state(.recovery), unit: .miles),
            "RECOVERY · REP 3/4 · 340 m to go")
    }
}

/// Shared fixture, kept out of the test bodies so the assertions stay readable.
enum TestOutput {

    static func profile() -> RunnerProfile {
        RunnerProfile(tempoPace: Pace(minutesPerMile: 8))
    }

    static func make(step: StepState) -> EngineOutput {
        let sample = RunSample(
            timestamp: 1_500, cumulativeDistance: 5_000, rollingPace: Pace(minutesPerMile: 8),
            heartRate: 158, relativeAltitude: 0, smoothedGrade: 0, gradeFactor: .identity,
            rawTarget: nil, effectiveTarget: nil, zone: .onTarget
        )
        return EngineOutput(
            zone: .onTarget, rollingPace: Pace(minutesPerMile: 8),
            averagePace: Pace(minutesPerMile: 8.2), rawTarget: nil, effectiveTarget: nil,
            gradeFactor: .identity, smoothedGrade: 0, isGradeSignificant: false,
            isGradeAvailable: true, isGPSDegraded: false, isStationary: false,
            isSettling: false, progress: 0.5, activeElapsed: 1_500, cumulativeDistance: 5_000,
            heartRate: 158, step: step, stepTransition: nil, alert: nil,
            degradations: [], sample: sample
        )
    }
}
