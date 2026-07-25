import XCTest
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-044, T-045 — the interval header and its countdown.
final class IntervalPresentationTests: XCTestCase {

    /// A `StepState` around a hand-built `ResolvedStep`.
    ///
    /// `rep` is **one-based**, matching `ResolvedStep.repIndex` as `WorkoutPlan.flatten`
    /// produces it. The original version of these tests defaulted it to 0 — a value the real
    /// resolver never emits — which let an off-by-one in the rep display pass for a whole wave.
    /// `resolvedState(...)` below now covers the same ground using the actual resolver, so the
    /// convention cannot drift again without a failure.
    private func state(
        kind: StepKind = .work,
        rep: Int = 1,
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

    /// A `StepState` wrapping a step the real resolver produced.
    private func resolvedState(
        _ step: ResolvedStep,
        distanceRemaining: Double? = 340,
        countingDown: Bool = false,
        canAdvance: Bool = false,
        undoAvailable: Bool = false
    ) -> StepState {
        StepState(
            phase: .running,
            step: step,
            stepDistanceMetres: 660,
            stepActiveSeconds: 150,
            distanceRemainingMetres: distanceRemaining,
            timeRemainingSeconds: nil,
            isCountingDown: countingDown,
            canAdvanceManually: canAdvance,
            isUndoAvailable: undoAvailable
        )
    }

    private func state(resolved step: ResolvedStep) -> StepState { resolvedState(step) }

    // MARK: - Step header

    func testARepeatedDistanceStepShowsKindRepAndDistanceRemaining() {
        let header = IntervalPresentation.stepHeader(for: state(rep: 3, of: 4), unit: .miles)
        XCTAssertEqual(header, "WORK · REP 3/4 · 340 m to go")
    }

    /// Rep numbers, checked against the numbering the **real plan resolver** produces.
    ///
    /// This is the test that should have caught the off-by-one and did not: it used to build
    /// `repIndex: 0` by hand and assert the display read "REP 1/4", which passed while the live
    /// app showed "REP 2/4" for the first rep and "REP 5/4" for the last. Driving it from
    /// `WorkoutPresets` means the convention is read from the source of truth rather than
    /// restated.
    func testRepNumbersMatchTheRealResolversNumbering() throws {
        let plan = WorkoutPresets.intervals(reps: 4, workMetres: 1_000, recoveryMetres: 1_000)
        let work = plan.resolvedSteps().filter { $0.kind == .work }
        XCTAssertEqual(work.count, 4)

        let rendered = try work.map { step in
            try XCTUnwrap(IntervalPresentation.repText(for: state(resolved: step)))
        }
        XCTAssertEqual(rendered, ["REP 1/4", "REP 2/4", "REP 3/4", "REP 4/4"])
    }

    /// The same, through the full step header.
    func testTheStepHeaderUsesTheRealResolversRepNumbering() throws {
        let plan = WorkoutPresets.intervals(reps: 3, workMetres: 400, recoveryMetres: 200)
        let firstWork = try XCTUnwrap(plan.resolvedSteps().first { $0.kind == .work })

        XCTAssertEqual(
            IntervalPresentation.stepHeader(for: state(resolved: firstWork), unit: .miles),
            "WORK · REP 1/3 · 340 m to go"
        )
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
