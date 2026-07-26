import SwiftUI
import ORModels
import LegacySupport

/// Pause, resume, and end — Legacy tier (T-068, CON-1).
///
/// Ending is a two-step confirmation while pausing is one tap, and the asymmetry is deliberate
/// (requirements.md §145): an accidental lap during a warmup is cheap and undoable, an accidental
/// *end* is not.
///
/// No crown *press* anywhere (CON-1) — the crown's press is the system's, and binding it would fight
/// the OS. Crown *rotation* is used for step advance on the metrics page.
struct ControlsView: View {

    @ObservedObject var coordinator: AppCoordinator
    @State private var confirmingEnd = false

    var body: some View {
        VStack(spacing: 8) {
            if confirmingEnd {
                Text("End run?")
                    .font(.headline)
                HStack(spacing: 8) {
                    Button("Cancel") { confirmingEnd = false }
                        .buttonStyle(.bordered)
                    Button("End") { coordinator.endRun() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } else {
                if coordinator.run.phase == .paused {
                    Button {
                        coordinator.resumeRun()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        coordinator.pauseRun()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    confirmingEnd = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// A full-screen interruption: the pace warning or the step-transition screen (T-068, FR-B-2).
///
/// Auto-dismiss timing is `AlertPresenter`'s, driven by the run loop's ticks, so this view holds no
/// timer of its own and "does it dismiss at 4 s?" stays a unit test.
struct WarningView: View {

    let alert: AlertPresentation
    let caseSize: LegacyCaseSize
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).edgesIgnoringSafeArea(.all)

            switch alert {
            case let .paceWarning(warning):
                paceWarning(warning)
            case let .stepTransition(transition):
                stepTransition(transition)
            }
        }
        // Tap or crown rotation dismisses (AC-FR-B-2-4). Never a crown press (CON-1).
        .onTapGesture(perform: onDismiss)
    }

    /// Direction, current, target, and the signed delta — the colour is one channel of four, never
    /// the only one (FR-J-1).
    private func paceWarning(_ warning: AlertPresentation.PaceWarning) -> some View {
        VStack(spacing: 4) {
            Image(systemName: warning.zone == .tooFast ? "chevron.down.2" : "chevron.up.2")
                .font(.system(size: caseSize == .mm38 ? 28 : 34, weight: .bold))
            Text(warning.zone == .tooFast ? "TOO FAST" : "TOO SLOW")
                .font(LegacyTypography.caption(caseSize))
            Text(ORFormat.signedSeconds(warning.signedDelta))
                .font(LegacyTypography.primaryMetric(caseSize))
        }
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The rep that just finished (design.md §12.4).
    private func stepTransition(_ transition: AlertPresentation.TransitionScreen) -> some View {
        VStack(spacing: 2) {
            Text(RunStrings.stepKind(transition.from.kind))
                .font(LegacyTypography.caption(caseSize))
            Text("\(Int(transition.completedDistanceMetres.rounded())) m")
                .font(LegacyTypography.primaryMetric(caseSize))
            Text(ORFormat.duration(transition.completedActiveSeconds))
                .font(LegacyTypography.secondaryMetric(caseSize))
            if let next = transition.to {
                Text("NEXT · \(RunStrings.stepKind(next.kind))")
                    .font(LegacyTypography.caption(caseSize))
                    .opacity(0.8)
            }
        }
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
