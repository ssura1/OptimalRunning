import Foundation
import ORModels

// MARK: - Luminance state

/// Whether the display is at full brightness or in the always-on dimmed state
/// (AC-FR-A-6-6).
public enum LuminanceState: String, Sendable, Hashable, CaseIterable {
    case normal
    case dimmed
}

// MARK: - Swatch

/// One zone's background and the text colour that goes on it.
///
/// Text colour is a property of `(zone, luminance state)`, **not** of zone alone. The
/// amber `slightlyFast` swatch is the reason: black text on it reads 9.74:1 at full
/// brightness but only 2.62:1 once dimmed, because the dimmed amber is dark. Modelling
/// text colour per-zone would pass review and fail the contrast gate.
public struct ZoneSwatch: Sendable, Hashable {
    public let background: SRGBColor
    public let text: SRGBColor

    public init(background: SRGBColor, text: SRGBColor) {
        self.background = background
        self.text = text
    }

    public var contrastRatio: Double { background.contrastRatio(against: text) }
}

// MARK: - Palette

/// A full set of zone colours for both luminance states.
public struct ZonePalette: Sendable {

    public let choice: PaletteChoice
    private let normal: [PaceZone: ZoneSwatch]
    private let dimmed: [PaceZone: ZoneSwatch]

    public init(
        choice: PaletteChoice,
        normal: [PaceZone: ZoneSwatch],
        dimmed: [PaceZone: ZoneSwatch]
    ) {
        self.choice = choice
        self.normal = normal
        self.dimmed = dimmed
    }

    public func swatch(for zone: PaceZone, luminance: LuminanceState = .normal) -> ZoneSwatch {
        let table = luminance == .normal ? normal : dimmed
        // Every zone is present in both tables, asserted by a test that iterates
        // `PaceZone.allCases`. The fallback exists only so a lookup can never trap.
        return table[zone] ?? ZoneSwatch(background: .black, text: .white)
    }

    public static func palette(for choice: PaletteChoice) -> ZonePalette {
        switch choice {
        case .standard: return .standard
        case .colorVisionDeficiency: return .colorVisionDeficiency
        }
    }

    // MARK: Standard palette

    /// The product memo's palette: red is too fast, green is on target, blue is too
    /// slow, with amber and turquoise as the intermediate steps.
    ///
    /// Two values are worth knowing before "correcting" them:
    ///
    /// - `tooFast` is **not** the brand red. The logo's `#E63946` reaches only 4.17:1
    ///   against white, below the 4.5:1 bar. `#C1121F` is the nearest darker red that
    ///   clears it, at 6.22:1.
    /// - `slightlyFast` flips text colour between luminance states — see `ZoneSwatch`.
    ///
    /// Every ratio below is verified numerically in `PaletteTests`; the tightest is
    /// `slightlySlow` at 4.64:1.
    public static let standard = ZonePalette(
        choice: .standard,
        normal: [
            .tooFast: swatch("#C1121F", .white),       // 6.22:1
            .slightlyFast: swatch("#E8A33D", .black),  // 9.74:1
            .onTarget: swatch("#1B7F4C", .white),      // 5.02:1
            .slightlySlow: swatch("#238180", .white),  // 4.64:1
            .tooSlow: swatch("#1D5FA8", .white),       // 6.45:1
            .neutral: swatch("#2B2F33", .white),       // 13.49:1
        ],
        dimmed: [
            .tooFast: swatch("#5A0A10", .white),       // 14.14:1
            .slightlyFast: swatch("#6B4A1A", .white),  // 8.02:1 — text flips to white
            .onTarget: swatch("#0C3A23", .white),      // 12.76:1
            .slightlySlow: swatch("#134746", .white),  // 10.41:1
            .tooSlow: swatch("#0D2B4C", .white),       // 14.31:1
            .neutral: swatch("#141618", .white),       // 18.14:1
        ]
    )

    // MARK: Colour-vision-deficiency palette

    /// An orange↔blue diverging scale on a **dark centre** (FR-J-2).
    ///
    /// Inverting the usual light-centred diverging scale earns its place three times:
    /// it puts maximum lightness on the two states that need attention, it keeps
    /// `onTarget` — where a runner spends most of the run — easy on the eyes at night,
    /// and it spreads lightness widely across the five judged steps, which is exactly
    /// what makes the palette survive dichromacy.
    ///
    /// `neutral` is a warm stone grey rather than the standard palette's graphite:
    /// graphite sits only ΔE 7.8 from this palette's near-black `onTarget`, which would
    /// make "settling" and "on target" indistinguishable.
    ///
    /// Verified worst-case separations: ΔE 23.2 normal, 18.2 dimmed, across all three
    /// simulated dichromacies.
    public static let colorVisionDeficiency = ZonePalette(
        choice: .colorVisionDeficiency,
        normal: [
            .tooFast: swatch("#FB923C", .black),       // 9.28:1
            .slightlyFast: swatch("#9A3412", .white),  // 7.31:1
            .onTarget: swatch("#1F2937", .white),      // 14.68:1
            .slightlySlow: swatch("#1E40AF", .white),  // 8.72:1
            .tooSlow: swatch("#7DD3FC", .black),       // 12.60:1
            .neutral: swatch("#57534E", .white),       // 7.63:1
        ],
        dimmed: [
            .tooFast: swatch("#803B03", .white),       // 8.25:1
            .slightlyFast: swatch("#411608", .white),  // 15.64:1
            .onTarget: swatch("#0D1117", .white),      // 18.92:1
            .slightlySlow: swatch("#0D1B4A", .white),  // 16.50:1
            .tooSlow: swatch("#046A9B", .white),       // 5.93:1
            .neutral: swatch("#55504A", .white),       // 7.98:1
        ]
    )

    /// Palette definitions are compile-time constants; a malformed hex here is a
    /// programming error, not a runtime condition.
    private static func swatch(_ hex: String, _ text: SRGBColor) -> ZoneSwatch {
        guard let background = SRGBColor(hex: hex) else {
            preconditionFailure("Malformed palette hex literal: \(hex)")
        }
        return ZoneSwatch(background: background, text: text)
    }
}

// MARK: - Redundant encoding

/// The non-colour channel carried on every zone screen (FR-J-1).
///
/// Colour is never the only carrier of meaning. Roughly 8% of men have some red-green
/// colour vision deficiency, and the memo's palette puts its two most important states
/// on exactly that axis — so a glyph and a signed pace delta are rendered
/// unconditionally, in both palettes, for every zone.
public struct ZoneAffordance: Sendable, Hashable {
    /// SF Symbol name. Rendered as a symbol, never as an emoji.
    public let symbolName: String
    /// Non-localized caption key. The app layer maps this to a localized string
    /// (NFR-23); `Core` holds no string catalog.
    public let captionKey: String
    /// Whether a signed pace delta is meaningful for this zone.
    public let showsDelta: Bool

    public init(symbolName: String, captionKey: String, showsDelta: Bool) {
        self.symbolName = symbolName
        self.captionKey = captionKey
        self.showsDelta = showsDelta
    }

    public static func affordance(for zone: PaceZone) -> ZoneAffordance {
        switch zone {
        case .tooFast:
            return .init(symbolName: "chevron.down.2", captionKey: "zone.tooFast", showsDelta: true)
        case .slightlyFast:
            return .init(symbolName: "chevron.down", captionKey: "zone.slightlyFast", showsDelta: true)
        case .onTarget:
            return .init(symbolName: "circle.fill", captionKey: "zone.onTarget", showsDelta: false)
        case .slightlySlow:
            return .init(symbolName: "chevron.up", captionKey: "zone.slightlySlow", showsDelta: true)
        case .tooSlow:
            return .init(symbolName: "chevron.up.2", captionKey: "zone.tooSlow", showsDelta: true)
        case .neutral:
            return .init(symbolName: "pause.circle", captionKey: "zone.neutral", showsDelta: false)
        }
    }
}
