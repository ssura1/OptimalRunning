import SwiftUI
import ORColor
import ORModels
import WatchSupport

/// The bridge from `ORColor`'s verified swatches to SwiftUI (T-039).
///
/// This file is the **only** place in the watch app allowed to name a colour, and it
/// names none of its own: every value comes from an `SRGBColor` that `ORColor` computed
/// and `PaletteTests` verified for contrast. AC-FR-A-6-1's edge-to-edge fill and
/// AC-FR-J-1-3's 4.5:1 floor are both properties of those swatches, so introducing a
/// literal here — even "just" a grey for a divider — would put an unverified colour on
/// screen and quietly invalidate both.
extension Color {
    /// Exact conversion, no colour-space guessing: `ORColor` works in sRGB and this
    /// asks SwiftUI for sRGB explicitly, so the hex in the palette is the hex on the
    /// display.
    init(_ srgb: SRGBColor) {
        let (r, g, b) = srgb.components
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Watch typography, sized for reading at a glance mid-stride.
///
/// Fixed text styles rather than point sizes, so Dynamic Type scales them — AC-FR-A-6-5
/// requires the five-metric stack to survive at 40 mm without truncation, which only works
/// if the sizes are relative to begin with.
///
/// **The sizes themselves live in `WatchSupport.MetricsTypography`, not here.** This target
/// is unreachable from the test bundle, so a token defined here could never be measured by
/// the layout budget that has to hold AC-FR-A-6-5. Both sides read the same tokens; this
/// file only turns them into SwiftUI.
enum ORFont {
    static let primaryMetric = Font(MetricsTypography.primaryMetric)
    static let distanceMetric = Font(MetricsTypography.distanceMetric)
    static let zoneCaption = Font(MetricsTypography.zoneCaption)
    static let secondaryMetric = Font(MetricsTypography.secondaryMetric)
    static let stepHeader = Font(MetricsTypography.stepHeader)
    static let countdown = Font(MetricsTypography.countdown)
    static let glyph = Font(MetricsTypography.glyph)
}

extension Font {
    /// The single mapping from a framework-free token to a real font. Exhaustive switches,
    /// so a token added in `WatchSupport` fails to compile here rather than silently
    /// falling back to a default size.
    init(_ token: TypeToken) {
        let style: Font.TextStyle = switch token.style {
        case .largeTitle: .largeTitle
        case .title2: .title2
        case .title3: .title3
        case .body: .body
        case .caption: .caption
        case .caption2: .caption2
        }
        let weight: Font.Weight = switch token.weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        self = token.rounded
            ? .system(style, design: .rounded, weight: weight)
            : .system(style, weight: weight)
    }
}

/// Animation, and what `Reduce Motion` changes about it (T-039, AC-FR-A-6-3).
///
/// Durations come from `PresentationConfiguration` rather than being written as `0.4`
/// here — the requirement marks the transition tunable, and NFR-21 gives a tunable
/// exactly one home.
enum ORMotion {

    /// The zone fill's cross-fade. Unconditional, and deliberately *not* gated on
    /// `Reduce Motion`: an opacity cross-fade is not the kind of motion that setting
    /// exists to suppress, and snapping a full-screen colour instantly is exactly the
    /// jarring flash AC-FR-A-6-3 asks to avoid. Turning it off would make the
    /// accessibility setting actively worse for the runner who enabled it.
    static func zoneFill(_ config: PresentationConfiguration) -> Animation {
        .easeInOut(duration: config.colourTransitionSeconds)
    }

    /// Movement — a transition screen sliding in, a countdown number scaling. This is
    /// what `Reduce Motion` removes, leaving a cross-fade of the same duration in its
    /// place so the change is still perceptible without anything travelling.
    static func screenChange(
        _ config: PresentationConfiguration,
        reduceMotion: Bool
    ) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .push(from: .bottom), removal: .opacity)
    }
}
