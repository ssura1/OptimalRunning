import XCTest
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-044, T-045 — the interval header and its countdown.
final class IntervalPresentationTests: XCTestCase {

    private func state(
        kind: StepKind = .work,
        rep: Int = 0,
        of reps: Int = 1,
        goal: StepGoal = .distance(metres: 1_000),
        distanceRemaining: Double? = 340,
        timeRemaining: TimeInterval? = nil,
        countingDown: Bool = false,
        canAdvance: Bool = false,
        undoAvailable: Bool = false
    ) -> StepState {
        StepState(
            phase: .running,
            step: ResolvedStep(
                index: 0, kind: kind, goal: goal, target: nil, repIndex: rep, repCount: reps
            ),
            stepDistanceMetres: 660,
            stepActiveSeconds: 150,
            distanceRemainingMetres: distanceRemaining,
            timeRemainingSeconds: timeRemaining,
            isCountingDown: countingDown,
            canAdvanceManually: canAdvance,
            isUndoAvailable: undoAvailable
        )
    }

    // MARK: - Step header

    func testARepeatedDistanceStepShowsKindRepAndDistanceRemaining() {
        let header = IntervalPresentation.stepHeader(for: state(rep: 2, of: 4), unit: .miles)
        XCTAssertEqual(header, "WORK · REP 3/4 · 340 m to go")
    }

    /// Rep numbers are one-based on screen and zero-based in the model. Off-by-one here
    /// would be invisible in code review and glaring on the wrist.
    func testRepNumbersAreOneBasedOnScreen() {
        XCTAssertEqual(IntervalPresentation.repText(for: state(rep: 0, of: 4)), "REP 1/4")
        XCTAssertEqual(IntervalPresentation.repText(for: state(rep: 3, of: 4)), "REP 4/4")
    }

    func testAnUnrepeatedStepOmitsTheRepSegment() {
        let header = IntervalPresentation.stepHeader(for: state(kind: .warmup, of: 1), unit: .miles)
        XCTAssertEqual(header, "WARM UP · 340 m to go")
        XCTAssertNil(IntervalPresentation.repText(for: state(of: 1)))
    }

    func testAnOpenGoalStepShowsOnlyItsKind() {
        let header = IntervalPresentation.stepHeader(
            for: state(kind: .cooldown, goal: .open, distanceRemaining: nil), unit: .miles
        )
        XCTAssertEqual(header, "COOL DOWN")
    }

    func testATimeGoalStepShowsTimeRemaining() {
        let header = IntervalPresentation.stepHeader(
            for: state(
                kind: .recovery, goal: .time(seconds: 120),
                distanceRemaining: nil, timeRemaining: 80
            ),
            unit: .miles
        )
        XCTAssertEqual(header, "RECOVERY · 1:20 left")
    }

    /// Distance remaining stays in metres regardless of the runner's unit preference:
    /// interval steps are prescribed in metres by universal convention, and a rep
    /// counting down in miles would be unreadable.
    func testDistanceRemainingStaysInMetresForAMilesRunner() {
        XCTAssertEqual(
            IntervalPresentation.remainingText(for: state(), unit: .miles), "340 m to go"
        )
        XCTAssertEqual(
            IntervalPresentation.remainingText(for: state(), unit: .kilometres), "340 m to go"
        )
    }

    func testAnUnstructuredRunHasNoStepHeader() {
        XCTAssertNil(IntervalPresentation.stepHeader(for: .idle, unit: .miles))
    }

    // MARK: - Final-100 m countdown (AC-FR-C-4-5)

    func testTheCountdownAppearsOnlyWhenTheEngineSaysSo() {
        XCTAssertNil(IntervalPresentation.countdownText(for: state(distanceRemaining: 340)))
        XCTAssertEqual(
            IntervalPresentation.countdownText(
                for: state(distanceRemaining: 87, countingDown: true)
            ),
            "87"
        )
    }

    func testTheCountdownRoundsToWholeMetres() {
        XCTAssertEqual(
            IntervalPresentation.countdownText(
                for: state(distanceRemaining: 42.6, countingDown: true)
            ),
            "43"
        )
    }

    // MARK: - Tap and undo

    /// AC-FR-C-3 — a tap advances open-goal steps only, and that judgement is `Core`'s.
    /// A glove-tap must not be able to end a 1000 m rep early.
    func testTapAdvancesOnlyWhatCoreSaysCanAdvance() {
        XCTAssertFalse(IntervalPresentation.tapAdvances(state(canAdvance: false)))
        XCTAssertTrue(IntervalPresentation.tapAdvances(state(goal: .open, canAdvance: true)))
    }

    func testUndoVisibilityFollowsCoresWindow() {
        XCTAssertFalse(IntervalPresentation.showsUndo(state(undoAvailable: false)))
        XCTAssertTrue(IntervalPresentation.showsUndo(state(undoAvailable: true)))
    }
}
