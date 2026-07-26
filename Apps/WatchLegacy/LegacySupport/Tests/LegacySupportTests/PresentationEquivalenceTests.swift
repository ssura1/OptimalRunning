import XCTest
import ORIntervals
import ORModels
import ORPace
@testable import LegacySupport

/// **T-069 — cross-tier UI equivalence** (AC-FR-K-1-2, FR-C-2/3/4/6).
///
/// T-069's acceptance criterion is "a simulated 4×1000 m behaves identically to Modern". The weak
/// reading of that is a test asserting Legacy's interval screen "looks like intervals" — it would
/// pass with the wrong rep numbers, the countdown appearing at the wrong distance, or the undo
/// affordance living for the whole step. The strong reading, which is what this file implements, is
/// that Legacy renders **the same strings at the same ticks** as the reference tier, asserted
/// against the golden Modern generates.
///
/// Wave 3's `repIndex` bug is the case in point: both tiers incremented a one-based index and shipped
/// "REP 5/4" to the wrist. Nothing about either screen looked broken in isolation.
///
/// Every fixture replay here goes through the real `RunEngine` and the real `WorkoutPlan` resolver.
/// Nothing is hand-built — a test that constructed a `StepState` itself would be checking that
/// Legacy agrees with the test's idea of intervals, which is exactly how the `repIndex` bug survived
/// a full wave.
final class PresentationEquivalenceTests: XCTestCase {

    private static let fixtureName = "intervals-4x1000"

    private func recorded() throws -> PresentationGolden {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: Self.fixtureName))
        let replay = FixtureReplay.run(fixture)
        return PresentationGolden.record(
            fixtureName: fixture.name,
            outputs: replay.outputs,
            unit: fixture.profile.units
        )
    }

    // MARK: - The headline assertion

    /// Legacy's rendered interval presentation matches the Modern tier's committed golden exactly.
    ///
    /// Whole-struct equality, no tolerance: every recorded tick, every header string, every rep
    /// number, every countdown value, and both permission flags.
    func testTheRenderedPresentationMatchesTheModernTierGoldenExactly() throws {
        let produced = try recorded()
        let committed = try FixtureLocating.loadPresentationGolden(named: Self.fixtureName)

        // Compare row-by-row first, so a failure names the tick that diverged instead of dumping
        // two 39-row structures at the reader.
        XCTAssertEqual(
            produced.rows.count, committed.rows.count,
            "Legacy recorded \(produced.rows.count) presentation rows, Modern \(committed.rows.count)"
        )

        for (produced, expected) in zip(produced.rows, committed.rows) {
            XCTAssertEqual(
                produced, expected,
                """
                tick \(expected.tick): Legacy's interval screen diverged from the Modern tier.
                This is an AC-FR-K-1-2 failure — the two watch tiers would show different things
                for the same run. Do NOT regenerate: this tier cannot, deliberately.
                kind:      \(String(describing: produced.kind)) vs \(String(describing: expected.kind))
                rep:       \(String(describing: produced.repIndex))/\
                \(String(describing: produced.repCount)) vs \
                \(String(describing: expected.repIndex))/\(String(describing: expected.repCount))
                header:    \(String(describing: produced.header))
                       vs  \(String(describing: expected.header))
                countdown: \(String(describing: produced.countdown)) vs \
                \(String(describing: expected.countdown))
                tap:       \(produced.tapAdvances) vs \(expected.tapAdvances)
                undo:      \(produced.showsUndo) vs \(expected.showsUndo)
                """
            )
        }

        XCTAssertEqual(produced, committed)
    }

    /// Proof the comparison is not vacuous: the golden has real content, and a mutation is caught.
    ///
    /// Without this, an empty golden compared against an empty recording would pass while asserting
    /// nothing at all.
    func testTheComparisonWouldCatchADivergence() throws {
        let produced = try recorded()
        XCTAssertGreaterThan(produced.rows.count, 8, "too few rows to be meaningful")

        // Mutate one rep number the way the Wave 3 bug did, and confirm inequality is detected.
        var rows = produced.rows
        let index = try XCTUnwrap(rows.firstIndex { $0.kind == "WORK" && $0.repIndex != nil })
        let original = rows[index]
        rows[index] = PresentationGolden.Row(
            tick: original.tick,
            reason: original.reason,
            stepIndex: original.stepIndex,
            kind: original.kind,
            repIndex: (original.repIndex ?? 0) + 1,   // the off-by-one, reintroduced locally
            repCount: original.repCount,
            header: original.header,
            repText: original.repText,
            countdown: original.countdown,
            tapAdvances: original.tapAdvances,
            showsUndo: original.showsUndo
        )
        let mutated = PresentationGolden(fixture: produced.fixture, rows: rows)

        XCTAssertNotEqual(
            mutated, produced,
            "a one-off rep index compared equal, so this suite could not catch the Wave 3 bug"
        )
    }

    // MARK: - The specific T-069 claims, stated independently of the golden

    /// Four work reps, numbered one-based, with the same boundaries the engine golden records.
    ///
    /// Stated separately from the golden comparison because a golden only says "unchanged", never
    /// "correct". If both the golden and this tier were wrong in the same way, the comparison above
    /// would still pass — so the substantive claims get their own assertions, tied back to the
    /// *engine* golden's transition list, which `Core`'s own conformance suite also checks.
    func testFourOneBasedWorkRepsWithBoundariesMatchingTheEngineGolden() throws {
        let produced = try recorded()

        let workReps = produced.rows
            .filter { $0.kind == "WORK" && $0.reason == "change" }
            .compactMap { row -> String? in
                guard let index = row.repIndex, let count = row.repCount else { return nil }
                return "REP \(index)/\(count)"
            }

        XCTAssertEqual(
            Set(workReps), ["REP 1/4", "REP 2/4", "REP 3/4", "REP 4/4"],
            "work reps are not numbered 1…4 — the one-based repIndex regression"
        )

        // The step-transition ticks this tier renders must be the ticks the engine golden records.
        let engineGolden = try FixtureLocating.loadGolden(named: Self.fixtureName)
        let goldenTransitionCount = engineGolden.transitions.count
        let renderedStepChanges = Set(produced.rows.compactMap(\.stepIndex)).count

        XCTAssertEqual(
            renderedStepChanges, goldenTransitionCount + 1,
            """
            the screen showed \(renderedStepChanges) distinct steps but the engine golden records \
            \(goldenTransitionCount) transitions — the UI and the engine disagree about the plan
            """
        )
    }

    /// Tap advances **only** open-goal steps (T-069, AC-FR-C-3).
    ///
    /// The warmup and cooldown are open-goal and tappable; every work and recovery rep has a
    /// distance goal and must not be. A stray glove-tap ending a 1000 m rep early would corrupt the
    /// rep the runner is judged on.
    func testTapAdvancesOnlyOpenGoalStepsAcrossTheWholeRun() throws {
        let produced = try recorded()

        for row in produced.rows {
            switch row.kind {
            case "WARM UP", "COOL DOWN":
                XCTAssertTrue(
                    row.tapAdvances,
                    "tick \(row.tick): the open-goal \(row.kind ?? "") step is not tappable"
                )
            case "WORK", "RECOVERY":
                XCTAssertFalse(
                    row.tapAdvances,
                    "tick \(row.tick): a tap would end the distance-goal \(row.kind ?? "") step early"
                )
            default:
                break
            }
        }

        // Non-vacuity: both kinds actually occur in this fixture.
        let kinds = Set(produced.rows.compactMap(\.kind))
        XCTAssertTrue(kinds.contains("WARM UP"))
        XCTAssertTrue(kinds.contains("WORK"))
    }

    /// The crown detent carries exactly the same permission as a tap — Series 3's only two advance
    /// inputs (T-069), with no Double Tap path.
    func testTheCrownDetentAndTapAgreeOnEveryStep() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: Self.fixtureName))
        let replay = FixtureReplay.run(fixture)

        for output in replay.outputs {
            XCTAssertEqual(
                IntervalPresentation.crownDetentAdvances(output.step),
                IntervalPresentation.tapAdvances(output.step),
                "the crown and a tap disagree about whether this step may be advanced"
            )
        }
    }

    /// The undo affordance is offered, and then withdrawn (FR-C-6, AC-FR-C-6-1).
    ///
    /// This is the assertion that caught the Core bug: `isUndoAvailable` had been defined as "a
    /// manual advance happened during this step", so the affordance stayed on screen for the rest of
    /// the step — 231 s on this fixture — while `undo()` itself correctly expired after 5 s. A
    /// visible control that silently does nothing.
    func testTheUndoAffordanceIsWithdrawnAfterItsWindow() throws {
        let produced = try recorded()

        let undoRows = produced.rows.filter(\.showsUndo)
        XCTAssertFalse(undoRows.isEmpty, "undo was never offered, so this proves nothing")

        let firstOffered = try XCTUnwrap(undoRows.map(\.tick).min())
        let withdrawn = try XCTUnwrap(
            produced.rows.first { $0.tick > firstOffered && !$0.showsUndo }?.tick,
            "the undo affordance was never withdrawn"
        )

        let window = Double(withdrawn - firstOffered)
        XCTAssertLessThanOrEqual(
            window, IntervalConfiguration().undoWindowSeconds + 1,
            """
            the undo affordance stayed up for \(window) s after being offered at tick \
            \(firstOffered), which exceeds the \(IntervalConfiguration().undoWindowSeconds) s \
            window AC-FR-C-6-1 specifies
            """
        )
    }

    /// VO2 max shows no colour, same as Modern (T-069, FR-C-4).
    ///
    /// Driven through the real engine on a real VO2 max plan rather than by constructing outputs, so
    /// the zones are ones the engine genuinely produces for that run type.
    func testVO2MaxShowsNoColourWhileKeepingTheRepStack() {
        let plan = WorkoutPresets.vo2Max4x1000()
        var engine = RunEngine(
            configuration: .default,
            plan: plan,
            profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8))
        )

        var distance = 0.0
        var sawRepText = false

        for second in 0..<600 {
            distance += 4.5
            let output = engine.tick(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: distance,
                // The warmup is an open-goal step, so it never advances on its own — it waits for a
                // tap. Without this the run sits in the warmup for all 600 s and never reaches a
                // repeated step, which is how the first version of this test "found" a missing rep
                // stack that was really a missing manual advance.
                manualAdvanceRequested: second == 60,
                distanceSource: .location
            ))

            let screen = MetricsScreen.make(
                output: output,
                runType: .vo2max,
                profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8))
            )
            XCTAssertFalse(
                screen.appliesZoneColour,
                "VO2 max coloured at second \(second) — it collapsed into interval behaviour"
            )
            XCTAssertEqual(screen.zone, PaceZone.neutral)

            if IntervalPresentation.repText(for: output.step) != nil { sawRepText = true }
        }

        XCTAssertTrue(sawRepText, "no rep text ever appeared, so the VO2 max stack is missing")
    }
}
