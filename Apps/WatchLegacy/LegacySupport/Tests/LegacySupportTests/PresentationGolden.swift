import Foundation
import ORIntervals
import ORModels
import ORPace
@testable import LegacySupport

/// A committed record of what the interval UI renders, tick by tick, for a shared fixture
/// (T-069, AC-FR-K-1-2).
///
/// **A deliberate duplicate of the Modern tier's test-side type** (AC-FR-K-1-4), exactly as
/// `FixtureLocating` already is. What is shared between the tiers is the JSON artifact at
/// `Fixtures/golden/intervals-4x1000.presentation.json` — never a source file, and never a build
/// dependency in either direction. `Tools/check-tier-isolation.sh` fails if that changes.
///
/// ## Why this tier can only read
///
/// There is no regeneration path here, and its absence is the design. implementation.md makes
/// Wave 2 the reference implementation for Wave 4, so Modern *defines* the rendered presentation
/// and Legacy must match it. If this file could regenerate, the natural response to a red test
/// would be to regenerate from Legacy — which turns a caught divergence into the new expectation
/// and defeats the entire mechanism. Regeneration lives in the Modern tier's
/// `PresentationGoldenTests` alone.
///
/// If a genuine Legacy-specific presentation divergence is ever needed, it belongs in design.md
/// §8.1's tier matrix and in a separate, explicitly-named golden — not in a quiet edit to this
/// shared one.
///
/// The recording rules are duplicated verbatim, including `gridInterval`, because the two tiers
/// must select the same ticks. A tier that sampled a different grid would produce a differently
/// shaped golden and fail for a reason that has nothing to do with what it renders.
struct PresentationGolden: Codable, Hashable {

    struct Row: Codable, Hashable {
        let tick: Int
        let reason: String
        let stepIndex: Int?
        let kind: String?
        let repIndex: Int?
        let repCount: Int?
        let header: String?
        let repText: String?
        let countdown: String?
        let tapAdvances: Bool
        let showsUndo: Bool
    }

    let fixture: String
    let rows: [Row]

    /// Records rows at the ticks where interval presentation changes, plus a coarse grid.
    ///
    /// See the Modern tier's copy for why this is not one row per tick: `header` embeds a live
    /// "340 m to go" that changes every second, so every-tick recording would bury a real boundary
    /// change under ~1 760 rows of a decrementing distance.
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
