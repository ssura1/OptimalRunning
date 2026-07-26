import Foundation
import ORIntervals
import ORModels

/// Renders `StepState` as the strings the interval UI shows — Legacy tier (T-069).
///
/// Every judgement it might look like it is making was already made in `Core`:
/// `canAdvanceManually` decides whether a tap does anything, `isUndoAvailable` enforces the 5 s
/// undo window, `isCountingDown` decides whether the final-100 m countdown is up, and
/// `distanceRemainingMetres` is the step machine's own figure. This type formats those; it never
/// second-guesses them. That is what makes the interval behaviour a Series 3 runner sees the same
/// behaviour the shared golden fixtures assert.
///
/// A deliberate duplicate of the Modern tier's presentation (AC-FR-K-1-4). The manual-advance
/// *inputs* differ — tap and crown detent here, tap plus Double Tap plus crown on Modern
/// (design.md §8.1) — but that is a difference in what raises the request, not in what the request
/// is permitted to do. `tapAdvances` therefore reads identically on both tiers, because the rule
/// it reports comes from Core.
public enum IntervalPresentation {

    /// `WORK · REP 3/4 · 340 m to go`, or `nil` for an unstructured run.
    ///
    /// Rep numbers come straight from `ResolvedStep.repIndex`, which is **already one-based**;
    /// nothing is added to it. Both tiers previously added 1 here, displaying "REP 2/4" for the
    /// first rep and "REP 5/4" for the last — a bug that survived a full wave because the test
    /// hand-built `repIndex: 0`, a value the real resolver never emits. Both tiers' tests now
    /// drive `WorkoutPresets` through the real resolver, and the shared presentation golden pins
    /// the rendered text.
    ///
    /// Each segment is dropped rather than padded when it does not apply: an un-repeated warmup
    /// reads `WARM UP · 340 m to go`, and an open-goal step with no end in sight reads just
    /// `WARM UP`. Rendering `REP 1/1` or `— m to go` would be noise, and this tier owns the
    /// smallest screen in the product.
    public static func stepHeader(for state: StepState, unit: UnitPreference) -> String? {
        guard let step = state.step else { return nil }

        var segments = [RunStrings.stepKind(step.kind)]

        if step.isRepeated {
            segments.append("REP \(step.repIndex)/\(step.repCount)")
        }
        if let remaining = remainingText(for: state, unit: unit) {
            segments.append(remaining)
        }
        return segments.joined(separator: " · ")
    }

    /// `340 m to go` for a distance goal, `1:20 left` for a time goal, `nil` for an open goal.
    ///
    /// Metres, not the runner's preferred unit, deliberately: interval steps are prescribed in
    /// metres (400 m, 1000 m) by universal convention, so a runner who reads miles everywhere else
    /// still thinks in metres inside a rep. Whole metres too — decimals on a countdown are
    /// unreadable at speed.
    public static func remainingText(for state: StepState, unit: UnitPreference) -> String? {
        if let metres = state.distanceRemainingMetres {
            return "\(Int(metres.rounded())) m to go"
        }
        if let seconds = state.timeRemainingSeconds {
            return "\(ORFormat.duration(seconds)) left"
        }
        return nil
    }

    /// The big final-100 m number (AC-FR-C-4-5). Whole metres, no unit — the context makes it
    /// obvious and the digits need every pixel, more so at 38 mm than anywhere else.
    public static func countdownText(for state: StepState) -> String? {
        guard state.isCountingDown, let metres = state.distanceRemainingMetres else {
            return nil
        }
        return "\(Int(metres.rounded()))"
    }

    /// `REP 3/4`, for the VO2 max stack where the step kind is already the header.
    public static func repText(for state: StepState) -> String? {
        guard let step = state.step, step.isRepeated else { return nil }
        return "REP \(step.repIndex)/\(step.repCount)"
    }

    /// Whether a tap on the metrics page should advance the step.
    ///
    /// Straight through to Core's answer. AC-FR-C-3 only permits advancing an *open-goal* step
    /// manually — a 1000 m rep ends when 1000 m are covered, and letting a stray glove-tap end it
    /// early would corrupt the rep the runner is judged on. On Series 3 that matters slightly
    /// more: with no Double Tap, tap is one of only two advance inputs, so it gets used more.
    public static func tapAdvances(_ state: StepState) -> Bool {
        state.canAdvanceManually
    }

    /// Whether the crown detent should advance the step.
    ///
    /// The same permission as a tap, exposed under its own name because the two inputs are wired
    /// separately in the view layer and a future change to one must not silently change the other.
    /// Series 3 has exactly these two (T-069) — there is no Double Tap path to add.
    public static func crownDetentAdvances(_ state: StepState) -> Bool {
        state.canAdvanceManually
    }

    /// Whether the undo affordance should be on screen (FR-C-6).
    public static func showsUndo(_ state: StepState) -> Bool {
        state.isUndoAvailable
    }
}
