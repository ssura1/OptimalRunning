import SwiftUI
import ORIntervals
import ORModels
import WatchSupport

/// The final-100 m countdown (T-044, AC-FR-C-4-5).
///
/// Overlaid on the metrics page rather than replacing it: the runner still needs pace and
/// elapsed while closing out a rep, and swapping the whole screen for a number would take
/// both away at the moment they matter most.
struct CountdownOverlay: View {

    let text: String
    let textColour: Color

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(ORFont.countdown)
                .monospacedDigit()
                .foregroundStyle(textColour)
                // A subtle background so the digits survive over any zone colour without
                // introducing a colour of their own.
                .padding(.horizontal, 10)
                .background(.black.opacity(0.25), in: Capsule())
            Spacer()
        }
        .accessibilityLabel("\(text) metres remaining")
    }
}

/// The undo affordance (FR-C-6).
///
/// Visible only while `Core` says the window is open — five seconds by
/// `IntervalConfiguration.undoWindowSeconds`, which this view neither knows nor
/// re-implements. It asks `IntervalPresentation.showsUndo` and renders the answer.
struct UndoAffordance: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                Text("Undo")
            }
            .font(.system(.caption2, design: .rounded, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(.gray)
        .accessibilityLabel("Undo the last step advance")
    }
}

/// The VO2 max metric stack (T-045).
///
/// This is a *layout*, not a behaviour: the absence of zone colour is already decided in
/// `MetricsScreen.make`, which resolves the neutral swatch for any run type that does not
/// permit colouring, and `MetricsScreenTests` proves it holds at every zone under both
/// palettes. So there is no `if runType == .vo2max` anywhere in the view layer — which is
/// the point, because that is the branch that would eventually be got wrong and let
/// VO2 max collapse into Interval's behaviour.
///
/// What this view adds is step context: step kind, rep number, and distance remaining
/// alongside the full metric stack (AC-FR-C-4-3, AC-FR-C-4-5).
struct VO2MaxStepStack: View {

    let state: StepState
    let unit: UnitPreference

    var body: some View {
        VStack(spacing: 1) {
            if let step = state.step {
                Text(RunStrings.stepKind(step.kind))
                    .font(ORFont.stepHeader)
            }
            HStack(spacing: 6) {
                if let rep = IntervalPresentation.repText(for: state) {
                    Text(rep)
                }
                if let remaining = IntervalPresentation.remainingText(for: state, unit: unit) {
                    Text(remaining)
                }
            }
            .font(ORFont.secondaryMetric)
            .monospacedDigit()
        }
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
}
