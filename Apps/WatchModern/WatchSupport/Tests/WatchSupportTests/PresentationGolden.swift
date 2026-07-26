import Foundation
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// A committed record of what the interval UI renders, tick by tick, for a shared fixture
/// (T-044/T-045 on this tier, T-069 on Legacy; AC-FR-K-1-2, AC-FR-K-1-3).
///
/// ## Why this file exists
///
/// `Fixtures/golden/*.golden.json` proves both tiers feed `RunEngine` the same input and get the
/// same *engine* output. It says nothing about what either tier then puts on a screen. Two tiers
/// can agree perfectly on zone, distance and step transitions and still disagree about whether the
/// third rep is labelled `REP 3/4` or `REP 4/4`, or about which tick the final-100 m countdown
/// appears on — and Wave 3 found exactly that class of bug, a one-based `repIndex` that both tiers
/// incremented, shipping "REP 5/4" to the wrist.
///
/// So the *rendered* strings get a golden too, and it is shared between the tiers the same way the
/// engine goldens are. A test asserting Legacy's 4×1000 m session "looks like intervals" would be
/// far weaker than one asserting Legacy renders the identical header text at the identical tick as
/// Modern.
///
/// ## Who generates it, and why only one tier may
///
/// **The Modern tier generates; both tiers compare.** implementation.md makes Wave 2 the reference
/// implementation for Wave 4, so Modern is the definition and Legacy must match it. Letting either
/// tier regenerate would invite the failure mode this whole mechanism exists to prevent: a
/// developer facing a red Legacy test regenerates from Legacy, and the divergence becomes the new
/// expectation.
///
/// Regenerate deliberately with `REGENERATE_PRESENTATION_GOLDEN=1 swift test`, and only when the
/// *intended* presentation changes. A diff here is a reviewable behavioural change to the run
/// screen, which is why the encoder sorts keys and pretty-prints.
///
/// This type is duplicated in the Legacy tier's test target rather than shared, per AC-FR-K-1-4 —
/// the same treatment `FixtureLocating` already gets. What is shared is the JSON artifact.
struct PresentationGolden: Codable, Hashable {

    /// One tick worth of rendered interval state.
    struct Row: Codable, Hashable {
        let tick: Int
        /// Why this row was recorded, so a diff explains itself.
        let reason: String
        let stepIndex: Int?
        let kind: String?
        let repIndex: Int?
        let repCount: Int?
        /// `WORK · REP 3/4 · 340 m to go`.
        let header: String?
        /// `REP 3/4`, the VO2 max stack's shorter form.
        let repText: String?
        let countdown: String?
        let tapAdvances: Bool
        let showsUndo: Bool
    }

    let fixture: String
    let rows: [Row]

    // MARK: - Recording

    /// Records rows at the ticks where interval presentation actually changes.
    ///
    /// Deliberately not one row per tick. `header` embeds a live "340 m to go" countdown that
    /// changes every second, so recording every tick would produce 1 800 rows per fixture, of which
    /// ~1 760 would be a distance decrementing — enormous, unreviewable, and noisy enough that a
    /// genuine boundary change would be lost in the diff.
    ///
    /// Instead a row is written whenever any of the *structural* facts change — which step is
    /// active, whether the countdown is up, whether a tap would advance, whether undo is offered —
    /// plus a coarse periodic sample so formatting is still pinned mid-step. That captures exactly
    /// what T-069 asks for (rep count, rep boundaries, step-transition timing) at a size a reviewer
    /// can read.
    static func record(
        fixtureName: String,
        outputs: [EngineOutput],
        unit: UnitPreference,
        gridInterval: Int = 120
    ) -> PresentationGolden {
        var rows: [Row] = []
        var previousKey: String?

        for (tick, output) in outputs.enumerated() {
            let state = output.step
            let step = state.step

            // The structural signature. A change in any component is a behavioural event.
            let key = [
                step?.index.description ?? "-",
                state.isCountingDown.description,
                state.canAdvanceManually.description,
                state.isUndoAvailable.description,
            ].joined(separator: "|")

            let isStructuralChange = key != previousKey
            let isGridSample = tick % gridInterval == 0
            guard isStructuralChange || isGridSample else { continue }
            previousKey = key

            rows.append(Row(
                tick: tick,
                reason: isStructuralChange ? "change" : "grid",
                stepIndex: step?.index,
                kind: step.map { RunStrings.stepKind($0.kind) },
                repIndex: step?.repIndex,
                repCount: step?.repCount,
                header: IntervalPresentation.stepHeader(for: state, unit: unit),
                repText: IntervalPresentation.repText(for: state),
                countdown: IntervalPresentation.countdownText(for: state),
                tapAdvances: IntervalPresentation.tapAdvances(state),
                showsUndo: IntervalPresentation.showsUndo(state)
            ))
        }

        return PresentationGolden(fixture: fixtureName, rows: rows)
    }
}
