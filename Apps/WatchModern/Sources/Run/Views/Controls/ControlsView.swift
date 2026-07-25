import SwiftUI
import ORModels
import WatchSupport

/// The Controls page: Pause / Resume, End, Lap (T-041, design.md §12.1).
///
/// Reached by swiping right, mirroring the stock Workout app (AC-FR-A-6-9). End living
/// one deliberate swipe away is the requirement, not an accident of layout: a runner must
/// not be able to end a run by fumbling at the screen mid-stride.
struct ControlsView: View {

    let phase: RunPhase
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void
    let onLap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // End on the left, Pause on the right, matching the stock app's
                // positions. Familiarity is the safety property here — muscle memory
                // built on the Workout app must not end a run in OptimalRunner.
                ControlButton(
                    title: "End",
                    systemImage: "xmark",
                    tint: .red,
                    action: onEnd
                )

                if phase == .paused {
                    ControlButton(
                        title: "Resume",
                        systemImage: "play.fill",
                        tint: .green,
                        action: onResume
                    )
                } else {
                    ControlButton(
                        title: "Pause",
                        systemImage: "pause.fill",
                        tint: .yellow,
                        action: onPause
                    )
                }
            }

            ControlButton(
                title: "Lap",
                systemImage: "flag.fill",
                tint: .blue,
                action: onLap
            )
            .disabled(phase != .running)
        }
        .padding(.horizontal, 6)
    }
}

/// A large, round, unmissable target.
///
/// Sized well past the 44 pt minimum because it is pressed with a sweaty finger, in
/// motion, without looking. The tints are SwiftUI's semantic colours rather than
/// `ORColor` swatches — deliberately: `ORColor` is the *zone* palette, and its contrast
/// guarantees are about zone backgrounds. Borrowing a zone colour for a button would
/// imply a pace meaning that a control does not have.
private struct ControlButton: View {

    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(.title3, weight: .bold))
                Text(title)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityLabel(title)
    }
}
