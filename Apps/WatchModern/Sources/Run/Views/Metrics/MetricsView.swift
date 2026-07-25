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
        ZStack {
            // AC-FR-A-6-1: edge to edge, no inset, no letterbox. `ignoresSafeArea` on the
            // fill rather than on the whole stack, so the text stays inside the safe area
            // on a curved display while the colour does not.
            Color(screen.background)
                .ignoresSafeArea()
                .animation(ORMotion.zoneFill(configuration), value: screen.background)

            metricStack
                .foregroundStyle(Color(screen.textColour))
                .padding(.horizontal, 4)
        }
        // The whole page is the tap target, not a button: a runner taps the screen
        // without looking, and a button would need aiming.
        .contentShape(Rectangle())
        .onTapGesture { if tapAdvances { onTap() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metricStack: some View {
        VStack(spacing: 2) {
            // Step header replaces the zone caption during a structured workout
            // (design.md §12.2). Both are never shown at once — the screen has room for
            // one line of context, and the step is the more useful one when there is a
            // step.
            if let header = screen.stepHeaderText {
                Text(header)
                    .font(ORFont.stepHeader)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            Text(screen.elapsedText)
                .font(ORFont.primaryMetric)
                .monospacedDigit()

            heartRate
                .opacity(screen.secondaryOpacity)

            Spacer(minLength: 2)

            rollingPace

            if screen.stepHeaderText == nil {
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

    private var secondary: some View {
        VStack(spacing: 0) {
            Text("avg \(screen.averagePaceText) \(screen.paceSuffix)")
                .monospacedDigit()
            Text("\(screen.distanceText) \(screen.distanceSuffix)")
                .monospacedDigit()
        }
        .font(ORFont.secondaryMetric)
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
