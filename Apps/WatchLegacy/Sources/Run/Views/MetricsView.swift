import SwiftUI
import ORModels
import LegacySupport

/// The metrics page — Legacy tier (T-067, FR-A-6, design.md §12.2).
///
/// Renders a `MetricsScreen` and decides nothing. Every value here was resolved by `LegacySupport`,
/// which was in turn handed an `EngineOutput` by `Core`. That layering is what makes the metrics page
/// testable at all on this tier: there is no watchOS 8 simulator to render a view in, so anything
/// this file decided for itself would be unverifiable until it reached hardware.
///
/// A deliberate duplicate of the Modern tier's view (AC-FR-K-1-4, ADR-002). Its shape differs — no
/// dimmed variants, a tighter stack, and the 38 mm delta row — so the duplication is not even
/// mechanical.
struct MetricsView: View {

    let screen: MetricsScreen
    let caseSize: LegacyCaseSize

    var body: some View {
        ZStack {
            // Edge to edge, ignoring every safe area: T-067 requires the zone colour to fill the
            // panel, and an inset background reads as a rendering bug rather than a zone.
            Color(screen.background)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: caseSize == .mm38 ? 2 : 4) {
                header
                Spacer(minLength: 0)
                primary
                Spacer(minLength: 0)
                secondary
            }
            .padding(.horizontal, 8)
            .foregroundColor(Color(screen.textColour))
        }
    }

    // MARK: - Rows

    /// The step header during a structured workout, otherwise the zone caption with its glyph and
    /// signed delta.
    ///
    /// The glyph is never omitted and the delta is never merged into the colour: FR-J-1 requires the
    /// zone be readable without perceiving colour at all, so shape and number ride alongside it.
    @ViewBuilder private var header: some View {
        if let step = screen.stepHeaderText {
            Text(step)
                .font(LegacyTypography.caption(caseSize))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: screen.glyphSymbolName)
                        .font(LegacyTypography.caption(caseSize))
                    Text(screen.zoneCaption)
                        .font(LegacyTypography.caption(caseSize))
                    // At 42 mm the delta shares this row; at 38 mm it moves below, because
                    // "A BIT FAST +24" measured 14 characters against a 13-character budget. See
                    // MetricsScreen.placesDeltaOnItsOwnRow.
                    if let delta = screen.signedDeltaText,
                       !screen.placesDeltaOnItsOwnRow(at: caseSize) {
                        Text(delta).font(LegacyTypography.caption(caseSize))
                    }
                }
                if let delta = screen.signedDeltaText,
                   screen.placesDeltaOnItsOwnRow(at: caseSize) {
                    Text(delta).font(LegacyTypography.caption(caseSize))
                }
            }
            .lineLimit(1)
        }
    }

    /// Rolling pace — the number the runner is actually steering by.
    private var primary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(screen.rollingPaceText)
                .font(LegacyTypography.primaryMetric(caseSize))
            Text(screen.paceSuffix)
                .font(LegacyTypography.secondaryMetric(caseSize))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The remaining four of the five metrics (FR-A-6): elapsed, heart rate, target, distance.
    ///
    /// Present in full even in VO2 max mode — that mode drops pace *judgement*, never the metrics
    /// (FR-C-4).
    private var secondary: some View {
        VStack(spacing: caseSize == .mm38 ? 1 : 3) {
            HStack {
                Text(screen.elapsedText)
                Spacer()
                Text(screen.heartRateText)
            }
            HStack {
                if let target = screen.targetPaceText {
                    HStack(spacing: 2) {
                        Text(target)
                        // The hill indicator: the target has been grade-adjusted
                        // (AC-FR-A-4-8). Live on Series 3 — it has the barometer.
                        if screen.isTargetGradeAdjusted {
                            Image(systemName: "mountain.2.fill")
                        }
                    }
                }
                Spacer()
                Text("\(screen.distanceText) \(screen.distanceSuffix)")
            }
            if let notice = screen.degradationNotice {
                Text(notice)
                    .font(.system(size: caseSize == .mm38 ? 10 : 12, weight: .bold))
                    .opacity(0.85)
            }
        }
        .font(LegacyTypography.secondaryMetric(caseSize))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
