import SwiftUI
import ORModels
import WatchSupport

/// The full-screen zone-coloured metrics page (T-040, design.md §12.2).
///
/// Renders a `MetricsScreen` and decides nothing. Every string, colour, glyph, and
/// opacity on this page was resolved in `WatchSupport`, which is why the requirements
/// this page carries — a glyph beside every colour, VO2 max never coloured, `--` for a
/// dropped heart rate — are asserted in `MetricsScreenTests` rather than needing a
/// snapshot test to catch a regression.
struct MetricsView: View {

    let screen: MetricsScreen
    let configuration: PresentationConfiguration
    /// Whether a tap here advances the step (AC-FR-C-3). Open-goal steps only.
    let tapAdvances: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A `Button`, and it still looks and behaves like a bare page (T-095, T-044).
        //
        // The whole page must stay the tap target — a runner taps without looking, and a
        // button that needed aiming would be worse than no button. But Double Tap only
        // binds to a *control*: `handGestureShortcut(.primaryAction)` designates one, and
        // there has to be one to designate. Wrapping the page in a button whose style
        // returns the label untouched satisfies both — the control exists for the system
        // to route the gesture to, and the runner cannot tell it is there.
        //
        // This is the resolution T-044's deviation note listed as option 2 and priced as
        // "costs the full-screen tap target". It does not: what that option would have
        // cost is a *prominent, aimable* button, and the cost is avoided by making the
        // label the whole page rather than a control drawn inside it.
        Button {
            if tapAdvances { onTap() }
        } label: {
            ZStack {
                // AC-FR-A-6-1: edge to edge, no inset, no letterbox. `ignoresSafeArea` on
                // the fill rather than on the whole stack, so the text stays inside the
                // safe area on a curved display while the colour does not.
                Color(screen.background)
                    .ignoresSafeArea()
                    .animation(ORMotion.zoneFill(configuration), value: screen.background)

                metricStack
                    .foregroundStyle(Color(screen.textColour))
                    .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FullScreenAdvanceButtonStyle())
        // AC-FR-C-3-4 — Double Tap advances the step, same as a tap.
        //
        // Deliberately **not** `isEnabled: tapAdvances`. A closed step's tap is inert
        // rather than disabled (see `RunSessionModel.requestManualAdvance`), and the
        // gesture follows the same rule for a specific reason: with this shortcut
        // disabled the system is free to route Double Tap to whatever control is next
        // in line, and on a closed step that is the undo affordance. A double tap
        // silently undoing the previous rep is far worse than one that does nothing.
        .handGestureShortcut(.primaryAction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// **Adding or removing a row here means updating
    /// `MetricsTypography.worstCaseRows`**, which is what `MetricsLayoutBudgetTests`
    /// measures against the 40 mm screen for AC-FR-A-6-5. The two cannot be linked by the
    /// compiler — this target is unreachable from the test bundle — so the note is the
    /// mechanism. `rowSpacing` there must match the `spacing:` below.
    private var metricStack: some View {
        VStack(spacing: MetricsTypography.rowSpacing) {
            // Step header replaces the zone caption during a structured workout
            // (design.md §12.2). Both are never shown at once — the screen has room for
            // one line of context, and the step is the more useful one when there is a
            // step.
            if screen.stepKindLabel != nil {
                stepHeader
            }

            Text(screen.elapsedText)
                .font(ORFont.primaryMetric)
                .monospacedDigit()

            heartRate
                .opacity(screen.secondaryOpacity)

            Spacer(minLength: 2)

            rollingPace

            if screen.stepKindLabel == nil {
                Text(screen.zoneCaption)
                    .font(ORFont.zoneCaption)
            }

            target

            Spacer(minLength: 2)

            secondary
                .opacity(screen.secondaryOpacity)

            if let notice = screen.degradationNotice {
                Text(notice)
                    .font(ORFont.stepHeader)
                    .opacity(screen.secondaryOpacity)
            }
        }
        // Scales down rather than truncating, which is what AC-FR-A-6-5 requires at
        // 40 mm and the largest Dynamic Type size.
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.center)
    }

    /// The structured-workout header: a `W` or `R` chip, then the rep and countdown
    /// (T-104).
    ///
    /// **Two channels, not one.** The chip colour is the fast channel — amber for work,
    /// cyan for recovery, ΔE 79 apart. The letterform is the reliable one, and it is what
    /// FR-J-1 requires: `W` and `R` are different *shapes*, so the distinction survives any
    /// colour vision deficiency, including the tritanopia that the warm/cool axis does not.
    /// Neither channel is conditional — there is no code path here that draws the colour
    /// without the letter.
    ///
    /// The chip exists because coloured letters directly on the zone fill cannot clear
    /// AC-FR-J-1-3's 4.5:1 — see `StepAccent` for the measurement. A fill is held to 3:1,
    /// and the letter's contrast is then against the fill rather than against the zone.
    @ViewBuilder
    private var stepHeader: some View {
        HStack(spacing: 4) {
            if let label = screen.stepKindLabel {
                if let accent = screen.stepAccent {
                    Text(label)
                        .font(ORFont.stepHeader)
                        .foregroundStyle(Color(accent.letter))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(accent.fill)))
                } else {
                    // Warm-up and cool-down: plain words, no chip.
                    Text(label)
                        .font(ORFont.stepHeader)
                }
            }
            if let detail = screen.stepDetailText {
                Text(detail)
                    .font(ORFont.stepHeader)
            }
        }
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }

    private var heartRate: some View {
        HStack(spacing: 2) {
            Image(systemName: "heart.fill")
            Text(screen.heartRateText)
                .monospacedDigit()
        }
        .font(ORFont.secondaryMetric)
    }

    /// The rolling pace line, and the two non-colour channels that must accompany it.
    ///
    /// FR-J-1 is satisfied *structurally* here rather than conditionally: the glyph is
    /// always rendered, and the signed delta is rendered whenever the model supplies one.
    /// There is no code path that draws a zone colour without them.
    private var rollingPace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: screen.glyphSymbolName)
                    .font(ORFont.glyph)
                Text(screen.rollingPaceText)
                    .font(ORFont.primaryMetric)
                    .monospacedDigit()
                Text(screen.paceSuffix)
                    .font(ORFont.secondaryMetric)
            }
            if let delta = screen.signedDeltaText {
                Text(delta)
                    .font(ORFont.secondaryMetric)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var target: some View {
        if let target = screen.targetPaceText {
            HStack(spacing: 3) {
                if screen.isTargetGradeAdjusted {
                    // The hill indicator: the target moved because of grade, so the
                    // number being shown is not the one in the runner's settings
                    // (AC-FR-A-4-8).
                    Image(systemName: "mountain.2.fill")
                }
                Text("target \(target)")
                    .monospacedDigit()
            }
            .font(ORFont.secondaryMetric)
        }
    }

    /// Average pace and distance, on one baseline-aligned row (T-103).
    ///
    /// **Enlarging distance in place was not available.** Measured on a 40 mm SE 3, the
    /// screen is 197 pt tall and the tallest arrangement this stack can produce already
    /// came to ~210 pt — so the page was already relying on `minimumScaleFactor` to fit,
    /// and adding height to it would have shrunk *every* metric to make one of them
    /// bigger. That is the trade AC-FR-A-6-5 exists to prevent.
    ///
    /// Folding these two onto one row buys back a whole row — ~13 pt measured — and spends
    /// part of it on distance, which is why the page comes out both shorter and easier to
    /// read. `MetricsLayoutBudgetTests` holds the arithmetic.
    ///
    /// **Deviation from AC-FR-A-6-2**, which words the five metrics as "top to bottom".
    /// The sequence is preserved as reading order rather than as five separate rows: pace
    /// still precedes distance. Recorded in requirements.md against the requirement itself
    /// rather than only here.
    ///
    /// The pace suffix is dropped from this row alone — the rolling-pace row above already
    /// establishes the unit, and the distance suffix sits two words away. That is width
    /// this row genuinely needs at 40 mm.
    private var secondary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("avg \(screen.averagePaceText)")
                .font(ORFont.secondaryMetric)
                .monospacedDigit()
            Text(screen.distanceText)
                .font(ORFont.distanceMetric)
                .monospacedDigit()
            Text(screen.distanceSuffix)
                .font(ORFont.secondaryMetric)
        }
        .lineLimit(1)
    }

    /// One combined label rather than eight separate elements: VoiceOver on a run screen
    /// should read the runner's state in a sentence, not require eight swipes mid-stride.
    private var accessibilityLabel: String {
        var parts = [
            "Elapsed \(screen.elapsedText)",
            "Pace \(screen.rollingPaceText) \(screen.paceSuffix)",
            screen.zoneCaption,
        ]
        if let delta = screen.signedDeltaText { parts.append("\(delta) seconds") }
        if let header = screen.stepHeaderText { parts.insert(header, at: 0) }
        parts.append("Heart rate \(screen.heartRateText)")
        parts.append("Distance \(screen.distanceText) \(screen.distanceSuffix)")
        return parts.joined(separator: ", ")
    }
}

/// Renders a button as exactly its label — no pressed state, no chrome, no inset.
///
/// The metrics page answers "am I running this correctly?" with its dominant colour in
/// under 250 ms of attention, and any style that dimmed or scaled that colour on touch
/// would be changing the one signal the product exists to deliver. `.plain` is close but
/// not neutral: it still applies a pressed appearance. This applies none, which is the
/// whole requirement — the button is a binding target for Double Tap, not an affordance.
private struct FullScreenAdvanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
