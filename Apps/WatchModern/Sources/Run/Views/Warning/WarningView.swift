import SwiftUI
import ORColor
import ORModels
import WatchSupport

/// The full-screen pace warning (T-043, design.md §12.3) and the step-transition screen
/// (§12.4), presented from the same place because they compete for the same space.
///
/// Which one is up, for how long, and whether one may replace the other is decided by
/// `WatchSupport.AlertPresenter` and asserted in `AlertPresenterTests` against all six
/// FR-B-2 criteria. This view renders whatever it is handed and reports dismissal.
struct AlertOverlayView: View {

    let presentation: AlertPresentation
    let palette: PaletteChoice
    let unit: UnitPreference
    let onDismiss: () -> Void

    var body: some View {
        switch presentation {
        case let .paceWarning(warning):
            PaceWarningView(warning: warning, palette: palette, unit: unit, onDismiss: onDismiss)
        case let .stepTransition(screen):
            TransitionScreenView(screen: screen, palette: palette, unit: unit)
        }
    }
}

/// Direction, current → target, signed delta, on the full-bleed zone colour
/// (AC-FR-B-2-1).
private struct PaceWarningView: View {

    let warning: AlertPresentation.PaceWarning
    let palette: PaletteChoice
    let unit: UnitPreference
    let onDismiss: () -> Void

    /// Crown rotation dismisses (AC-FR-B-2-3) — and it is a *rotation*, never a press.
    /// CON-1: the crown press is the system's Dock gesture and is never relied upon.
    @State private var crownValue: Double = 0

    private var swatch: ZoneSwatch {
        ZonePalette.palette(for: palette).swatch(for: warning.zone)
    }

    private var affordance: ZoneAffordance {
        ZoneAffordance.affordance(for: warning.zone)
    }

    var body: some View {
        ZStack {
            Color(swatch.background).ignoresSafeArea()

            VStack(spacing: 4) {
                // The glyph at maximum size — on a screen whose entire purpose is to be
                // read in one glance, the shape carries the message and the colour
                // reinforces it, not the other way round (FR-J-1).
                Image(systemName: affordance.symbolName)
                    .font(.system(size: 44, weight: .heavy))

                Text(RunStrings.zoneCaption(affordance.captionKey))
                    .font(ORFont.zoneCaption)

                HStack(spacing: 4) {
                    Text(ORFormat.pace(warning.current, in: unit))
                    Image(systemName: "arrow.right")
                    Text(ORFormat.pace(warning.target, in: unit))
                }
                .font(ORFont.secondaryMetric)
                .monospacedDigit()

                Text("\(ORFormat.signedSeconds(warning.signedDelta)) s \(RunStrings.paceSuffix(unit))")
                    .font(ORFont.primaryMetric)
                    .monospacedDigit()
            }
            .foregroundStyle(Color(swatch.text))
            .minimumScaleFactor(0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .focusable()
        .digitalCrownRotation($crownValue)
        .onChange(of: crownValue) { _, _ in onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(RunStrings.zoneCaption(affordance.captionKey)). "
                + "Current \(ORFormat.pace(warning.current, in: unit)), "
                + "target \(ORFormat.pace(warning.target, in: unit))."
        )
        .accessibilityAddTraits(.isModal)
    }
}

/// `1000 m WORK → 1000 m RECOVERY`, with the completed step's time and average pace
/// (design.md §12.4).
private struct TransitionScreenView: View {

    let screen: AlertPresentation.TransitionScreen
    let palette: PaletteChoice
    let unit: UnitPreference

    /// Neutral, not a zone colour: a transition is not a judgement about pace, and
    /// colouring it would imply one.
    private var swatch: ZoneSwatch {
        ZonePalette.palette(for: palette).swatch(for: .neutral)
    }

    var body: some View {
        ZStack {
            Color(swatch.background).ignoresSafeArea()

            VStack(spacing: 5) {
                Text(RunStrings.stepKind(screen.from.kind))
                    .font(ORFont.stepHeader)
                    .opacity(0.7)

                if let next = screen.to {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text(RunStrings.stepKind(next.kind))
                    }
                    .font(ORFont.primaryMetric)
                } else {
                    Text("DONE")
                        .font(ORFont.primaryMetric)
                }

                Divider()

                Text(ORFormat.duration(screen.completedActiveSeconds))
                    .font(ORFont.primaryMetric)
                    .monospacedDigit()

                if let pace = screen.completedAveragePace {
                    Text("\(ORFormat.pace(pace, in: unit)) \(RunStrings.paceSuffix(unit))")
                        .font(ORFont.secondaryMetric)
                        .monospacedDigit()
                }

                Text("\(Int(screen.completedDistanceMetres.rounded())) m")
                    .font(ORFont.secondaryMetric)
                    .monospacedDigit()
            }
            .foregroundStyle(Color(swatch.text))
            .minimumScaleFactor(0.6)
        }
        // Deliberately not dismissable by tap: it lasts three seconds and reports a
        // completed rep. A runner tapping to advance the *next* step would otherwise
        // dismiss the summary of the last one by accident.
        .accessibilityElement(children: .combine)
    }
}
