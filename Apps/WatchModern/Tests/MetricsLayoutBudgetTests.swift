import XCTest
import UIKit
import WatchKit
import WatchSupport

/// AC-FR-A-6-5, measured rather than eyeballed (T-103).
///
/// The requirement is a claim about rendered height: five metrics legible at 40 mm with no
/// truncation or overlap. `MetricsView` uses `minimumScaleFactor`, so overflow never shows
/// up as clipping — it shows up as *every* metric silently shrinking, which is the failure
/// mode a screenshot is worst at catching and a runner notices immediately.
///
/// So this sums the real `UIFont` line heights of the tallest arrangement the stack can
/// produce and checks it against the real screen. It runs on the watchOS simulator, where
/// `UIFont.preferredFont(forTextStyle:)` returns the metrics the device will actually use;
/// the host-side `swift test` suite could not do this at all.
///
/// **What it does not prove:** horizontal fit, and legibility as a judgement. Both stay on
/// the manual protocol. This holds the one property that is arithmetic.
final class MetricsLayoutBudgetTests: XCTestCase {

    /// The same mapping `ORFont` performs, in the direction the test needs. Kept beside the
    /// budget rather than shared, because `UIFont` is the measurement side and `Font` is
    /// the rendering side — they agree on the *token*, which is the thing that must match.
    private func lineHeight(_ token: TypeToken) -> Double {
        let style: UIFont.TextStyle = switch token.style {
        case .largeTitle: .largeTitle
        case .title2: .title2
        case .title3: .title3
        case .body: .body
        case .caption: .caption1
        case .caption2: .caption2
        }
        return Double(UIFont.preferredFont(forTextStyle: style).lineHeight)
    }

    /// A child's height is its tokens stacked with no spacing between them.
    private func height(of children: [[TypeToken]]) -> Double {
        let text = children.reduce(0.0) { total, child in
            total + child.reduce(0.0) { $0 + lineHeight($1) }
        }
        let spacers = Double(MetricsTypography.spacerCount) * MetricsTypography.rowSpacing
        let gapCount = children.count + MetricsTypography.spacerCount - 1
        return text + spacers + Double(gapCount) * MetricsTypography.rowSpacing
    }

    /// The tallest the metrics stack can get still fits the smallest screen it must fit.
    ///
    /// It clears by under a point, which is a finding rather than a comfort: this page has
    /// no room for another row at any size. That is recorded in T-103 rather than left for
    /// the next person to rediscover by shrinking every metric on the page.
    func testTheWorstCaseStackFitsA40mmScreen() {
        XCTAssertLessThanOrEqual(
            height(of: MetricsTypography.worstCaseChildren),
            MetricsTypography.smallestScreenHeight,
            "the metric stack no longer fits a 40 mm screen at the default Dynamic Type "
                + "size, so every metric will be scaled down to make it fit — including the "
                + "two AC-FR-A-6-2 puts first. Buy the space back in layout, the way "
                + "distance and average pace were folded onto one row, rather than by "
                + "shrinking a font.")
    }

    /// The case a runner actually looks at fits with real margin, not by a hair.
    ///
    /// Passing the worst case is necessary but not sufficient: if the ordinary view sat at
    /// the limit too, the page would scale for the whole run and the budget above would
    /// still be green. 15% is the headroom that keeps the common case off the limit.
    func testAnOrdinaryStructuredRunFitsWithHeadroom() {
        let typical = height(of: MetricsTypography.typicalChildren)
        let ceiling = MetricsTypography.smallestScreenHeight * 0.85
        XCTAssertLessThanOrEqual(
            typical, ceiling,
            "an ordinary structured run now fills \(typical) pt of a "
                + "\(MetricsTypography.smallestScreenHeight) pt screen, leaving under 15% "
                + "spare — the page will be scaling down for most of a run")
    }

    /// The screen constant this budget is written against is the screen we are measuring on.
    ///
    /// Without this the budget could pass on a 46 mm simulator while overflowing the 40 mm
    /// case the requirement actually names — a green test proving nothing.
    func testTheBudgetIsBeingCheckedAgainstTheSizeItClaims() throws {
        let bounds = WKInterfaceDevice.current().screenBounds
        try XCTSkipUnless(
            Double(bounds.height) == MetricsTypography.smallestScreenHeight,
            "not the 40 mm case (screen is \(bounds.width)x\(bounds.height)); the budget "
                + "assertion above is only meaningful on the smallest supported size")
        XCTAssertEqual(Double(bounds.width), MetricsTypography.smallestScreenWidth)
    }

    /// Distance is genuinely larger than the caption-sized metrics around it.
    ///
    /// The reported problem was that it could not be read mid-run. A later change that
    /// quietly returned it to caption size would leave every other assertion here green,
    /// so the size relationship is asserted directly rather than implied by the budget.
    func testDistanceIsReadablyLargerThanTheSecondaryMetrics() {
        XCTAssertGreaterThan(
            lineHeight(MetricsTypography.distanceMetric),
            lineHeight(MetricsTypography.secondaryMetric),
            "distance is no larger than the text beside it — the thing that was reported")
    }

    /// ...and still below the two metrics that must dominate the page.
    ///
    /// AC-FR-A-6-2 orders the stack; design.md §12.2 makes elapsed and rolling pace the
    /// glanceable pair. Distance matching them would flatten that, which is a different
    /// regression from the one above and needs its own assertion.
    func testDistanceStaysBelowThePrimaryPair() {
        XCTAssertLessThan(
            lineHeight(MetricsTypography.distanceMetric),
            lineHeight(MetricsTypography.primaryMetric),
            "distance now competes with elapsed and rolling pace for the page's hierarchy")
    }

    /// The five AC-FR-A-6-2 metrics are all present in the budget, so the budget cannot be
    /// made to pass by dropping one.
    func testTheBudgetCoversAllFiveMetrics() {
        let flat = MetricsTypography.worstCaseChildren.flatMap { $0 }
        XCTAssertEqual(flat.filter { $0 == MetricsTypography.primaryMetric }.count, 2,
                       "elapsed and rolling pace")
        XCTAssertTrue(flat.contains(MetricsTypography.distanceMetric), "distance")
        // Heart rate, the signed delta and target are all secondary-sized; average pace
        // shares distance's row and is bounded by the taller of the two.
        XCTAssertGreaterThanOrEqual(
            flat.filter { $0 == MetricsTypography.secondaryMetric }.count, 3,
            "heart rate must be inside the budget")
    }
}
