import Foundation

/// The metrics page's type scale, as plain data (T-103).
///
/// **Why this is here and not next to the view.** AC-FR-A-6-5 is a claim about rendered
/// height — five metrics legible at 40 mm with no truncation or overlap — and the only
/// honest way to hold that claim is to measure real font metrics on a real watchOS
/// runtime. That measurement lives in `OptimalRunnerWatchTests`, which cannot import the
/// app target at all (see `ScaffoldingTests`), so a token defined beside `MetricsView`
/// would be invisible to the test that has to check it.
///
/// Both sides therefore read *these* values: `ORFont` turns each token into a SwiftUI
/// `Font`, and `MetricsLayoutBudgetTests` turns the same token into a `UIFont` and sums
/// the stack. Changing a size in one place changes what the other measures, which is the
/// only arrangement where the test can actually fail for the right reason.
///
/// `WatchSupport` imports no UI framework and this file keeps that true — a text style is
/// named, not constructed.
public struct TypeToken: Sendable, Equatable, Hashable {

    /// Dynamic Type styles, so sizes scale with the runner's setting rather than being
    /// pinned in points. AC-FR-A-6-5 only holds if the scale is relative to begin with.
    public enum Style: Sendable, Equatable, Hashable {
        case largeTitle
        case title2
        case title3
        case body
        case caption
        case caption2
    }

    public enum Weight: Sendable, Equatable, Hashable {
        case medium
        case semibold
        case bold
        case heavy
    }

    public let style: Style
    public let weight: Weight
    /// `.rounded` for numerals a runner reads at a glance; the glyph row uses the system
    /// face because SF Symbols are drawn from it.
    public let rounded: Bool

    public init(style: Style, weight: Weight, rounded: Bool) {
        self.style = style
        self.weight = weight
        self.rounded = rounded
    }
}

/// Watch typography for the run screen, and the layout budget that constrains it.
public enum MetricsTypography {

    /// Elapsed time and rolling pace: the two a runner reads without breaking stride.
    public static let primaryMetric = TypeToken(style: .title2, weight: .semibold, rounded: true)

    /// Distance (T-103). Deliberately its own tier, between the primary pair and the
    /// caption-sized rest.
    ///
    /// It was `secondaryMetric` — 15 pt, dimmed, and the last line on the page — and was
    /// reported unreadable mid-run on real hardware. It is not promoted all the way to
    /// `primaryMetric`: three co-equal 28 pt numbers would flatten the hierarchy the page
    /// depends on, and the measured budget below shows it would not fit the worst case.
    /// 19 pt against the 15 pt around it is a visible step without costing the page its
    /// answer to "am I running this correctly?".
    public static let distanceMetric = TypeToken(style: .title3, weight: .semibold, rounded: true)

    public static let zoneCaption = TypeToken(style: .caption, weight: .bold, rounded: true)
    public static let secondaryMetric = TypeToken(style: .caption, weight: .medium, rounded: true)
    public static let stepHeader = TypeToken(style: .caption2, weight: .bold, rounded: true)
    public static let countdown = TypeToken(style: .largeTitle, weight: .heavy, rounded: true)
    public static let glyph = TypeToken(style: .title3, weight: .bold, rounded: false)

    /// The 40 mm case, in points — the smallest this tier supports under ADR-014's floor,
    /// and the size AC-FR-A-6-5 names. Read off `WKInterfaceDevice.screenBounds` on an
    /// Apple Watch SE 3 (40 mm) rather than taken from a specification table.
    public static let smallestScreenHeight: Double = 197
    public static let smallestScreenWidth: Double = 162

    /// `VStack(spacing:)` on the metric stack.
    public static let rowSpacing: Double = 2

    /// `Spacer(minLength:)` — two of them, and they are rows with real height, not free
    /// space. A budget that forgot them would under-count by 4 pt on a page that clears its
    /// limit by less than one.
    public static let spacerCount = 2

    /// The tallest arrangement `MetricsView` can produce, as the stack's *children*.
    ///
    /// Each entry is one child of the `VStack`; the inner array is what that child stacks
    /// with **no** spacing of its own. The distinction is not pedantry — rolling pace and
    /// its signed delta are one child with `spacing: 0`, so counting them as two rows
    /// invents a 2 pt gap that is not there, and the page has less than 1 pt of margin to
    /// spare.
    ///
    /// **This mirrors `MetricsView.metricStack` by hand and no compiler link exists** — the
    /// view is in the app target, which the measuring test cannot import. A child added
    /// there without a child added here is a real drift risk; the mitigation is the note at
    /// the view's own stack, because the mechanism that would catch it does not exist on
    /// this platform.
    ///
    /// A structured workout shows `stepHeader` *or* `zoneCaption`, never both, and they are
    /// within 1.2 pt of each other, so which one a worst case takes barely moves the total.
    public static let worstCaseChildren: [[TypeToken]] = [
        [stepHeader],                      // structured-workout step name
        [primaryMetric],                   // elapsed
        [secondaryMetric],                 // heart rate
        [primaryMetric, secondaryMetric],  // rolling pace + signed delta, one child
        [secondaryMetric],                 // target pace
        [distanceMetric],                  // average pace + distance, one row (T-103)
        [stepHeader],                      // degradation notice, stepHeader-sized
    ]

    /// An ordinary structured run: no GPS degradation, no signed delta. This is what the
    /// runner sees for almost the whole of a workout, and it is the case that must fit with
    /// room to spare rather than merely fit.
    public static let typicalChildren: [[TypeToken]] = [
        [stepHeader],
        [primaryMetric],
        [secondaryMetric],
        [primaryMetric],
        [secondaryMetric],
        [distanceMetric],
    ]
}
