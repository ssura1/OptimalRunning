import SwiftUI
import WatchKit
import ORColor
import ORModels
import LegacySupport

/// Bridges `Core`'s palette data to SwiftUI — Legacy tier (T-066, FR-J-1).
///
/// A deliberate duplicate of the Modern tier's bridge (AC-FR-K-1-4). The *colour science* lives in
/// `ORColor` and is shared: both tiers render the identical hex values and are checked by the same
/// `ORColor` contrast tests, which is what T-066 means by "contrast is verified by the same tests" —
/// the bar is shared even though the bridge is not.
///
/// No `LuminanceState` parameter anywhere in this file. Series 3 has no always-on display, so there
/// is no dimmed variant to select; `MetricsScreen` already resolves the swatch with `.normal` and
/// explains why. See design.md §8.1.
extension Color {

    /// Exact conversion from `Core`'s `SRGBColor`.
    ///
    /// `.sRGB` explicitly rather than the default initialiser: SwiftUI's plain
    /// `Color(red:green:blue:)` is documented as sRGB but the explicit form states the colour space
    /// the palette's contrast ratios were computed in, which is the whole basis of the WCAG figures
    /// in design.md §11.
    init(_ colour: SRGBColor) {
        self.init(
            .sRGB,
            red: Double(colour.red) / 255.0,
            green: Double(colour.green) / 255.0,
            blue: Double(colour.blue) / 255.0,
            opacity: 1.0
        )
    }
}

/// Typography scaled for the two Series 3 panels (T-067).
///
/// Series 3 is the smallest display in the product — 136 pt wide at 38 mm — so the type scale is
/// tighter than the Modern tier's. The sizes here are the ones
/// `LegacyCaseSize.primaryMetricCharacterBudget` derives its character budgets from; changing one
/// without the other would make the truncation tests assert against a font that is no longer in use.
enum LegacyTypography {

    static func primaryMetric(_ caseSize: LegacyCaseSize) -> Font {
        .system(size: caseSize == .mm38 ? 30 : 34, weight: .semibold, design: .rounded)
    }

    static func secondaryMetric(_ caseSize: LegacyCaseSize) -> Font {
        .system(size: caseSize == .mm38 ? 16 : 18, weight: .medium, design: .rounded)
    }

    static func caption(_ caseSize: LegacyCaseSize) -> Font {
        .system(size: caseSize == .mm38 ? 13 : 15, weight: .semibold, design: .rounded)
    }

    static func countdown(_ caseSize: LegacyCaseSize) -> Font {
        .system(size: caseSize == .mm38 ? 56 : 64, weight: .bold, design: .rounded)
    }
}

/// Resolves the running device's case size from its screen width.
///
/// `WKInterfaceDevice.current().screenBounds` rather than a build setting, because one binary serves
/// both panels. The 38 mm panel is 136 pt wide and the 42 mm is 156 pt; the midpoint is a safe
/// discriminator, and anything wider than either (a future device, or the watchOS 26 simulator this
/// project can also be built against for smoke purposes) falls to the roomier layout, which is the
/// safe direction — a too-generous character budget is what ships a truncated metric.
enum LegacyDevice {

    /// The running device's screen width in points, reported so T-072's on-device run can record
    /// which panel it measured rather than leaving it to be inferred.
    static var screenWidthPoints: Double {
        Double(WKInterfaceDevice.current().screenBounds.width)
    }

    static var caseSize: LegacyCaseSize {
        screenWidthPoints < 146 ? .mm38 : .mm42
    }
}
