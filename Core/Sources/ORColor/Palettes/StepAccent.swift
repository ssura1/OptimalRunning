import Foundation

/// The work/recovery marker's colours (T-104).
///
/// ## Why this is a filled chip and not coloured text
///
/// The obvious implementation — render `W` and `R` in two different colours — cannot meet
/// this project's own contrast floor, and that was established by measurement before the
/// design changed rather than after it shipped.
///
/// AC-FR-J-1-3 requires 4.5:1 against the background. The marker sits on the zone fill,
/// which ranges from `#FB923C` to `#0D1117` across the two palettes and both luminance
/// states. The binding case is `slightlySlow` at `#238180`: the best contrast *any* colour
/// achieves against it is 4.64:1, using pure white — pure black manages 4.52:1. There is no
/// room for a saturated hue there at all, so two distinguishable coloured letters on that
/// background is not a thing that exists.
///
/// A chip moves the problem somewhere solvable. The fill is a non-text element, which WCAG
/// 1.4.11 holds to **3:1**, and the letter's contrast is then against the fill — a value
/// this file controls completely rather than one the zone dictates. Both bars are cleared
/// with margin, and `StepAccentTests` checks every combination rather than trusting these
/// comments.
///
/// ## Why amber and cyan
///
/// Warm against cool is the one axis that survives all three dichromacies, which is why
/// `colorVisionDeficiency` already builds its whole scale on it. Red/green would have put
/// the work/recovery distinction on precisely the axis ~8% of men cannot use.
///
/// Colour is not the only channel regardless — `W` and `R` differ in letterform, which is
/// what FR-J-1 actually requires. The colour is the fast channel; the shape is the reliable
/// one.
public struct StepAccentSwatch: Sendable, Hashable {

    /// The chip's fill.
    public let fill: SRGBColor
    /// The letter drawn on it, black or white, whichever clears 4.5:1 against `fill`.
    public let letter: SRGBColor

    public init(fill: SRGBColor, letter: SRGBColor) {
        self.fill = fill
        self.letter = letter
    }

    /// The letter's contrast against its own chip — the text bar, 4.5:1.
    public var letterContrastRatio: Double { fill.contrastRatio(against: letter) }

    /// The chip's contrast against the page behind it — the non-text bar, 3:1.
    public func fillContrastRatio(against background: SRGBColor) -> Double {
        fill.contrastRatio(against: background)
    }
}

/// The two step kinds that alternate often enough to need telling apart at a glance.
///
/// Warm-up and cool-down are deliberately absent. They are not part of the alternation, and
/// giving warm-up a chip would put a bare `W` on screen meaning something other than the
/// `W` that means work — an ambiguity created purely by abbreviating. They keep their full
/// words.
public enum StepAccentKind: String, Sendable, Hashable, CaseIterable {
    case work
    case recovery
}

public enum StepAccent {

    /// Light and dark variants per kind, selected by whichever clears more contrast against
    /// the zone fill behind it. One fixed pair cannot span backgrounds this far apart —
    /// `#FB923C` and `#0D1117` are 18:1 from each other.
    static let workLight = StepAccentSwatch(fill: hex("#FFD166"), letter: .black)
    static let workDark = StepAccentSwatch(fill: hex("#8A4600"), letter: .white)
    static let recoveryLight = StepAccentSwatch(fill: hex("#8FE3FF"), letter: .black)
    static let recoveryDark = StepAccentSwatch(fill: hex("#104A6E"), letter: .white)

    /// The chip for a step kind, on a given zone background.
    ///
    /// Measured worst cases across both palettes, all six zones and both luminance states:
    /// fill-vs-background **3.14:1** (on `#FB923C`), letter-on-fill **7.10:1**, and work vs
    /// recovery **ΔE 79.2** — far past the ΔE 25 that would merely make them "different".
    public static func accent(for kind: StepAccentKind, on background: SRGBColor) -> StepAccentSwatch {
        let (light, dark) = switch kind {
        case .work: (workLight, workDark)
        case .recovery: (recoveryLight, recoveryDark)
        }
        return light.fillContrastRatio(against: background)
            >= dark.fillContrastRatio(against: background) ? light : dark
    }

    /// Compile-time constants; a malformed literal here is a programming error, the same
    /// treatment `ZonePalette` gives its own.
    private static func hex(_ value: String) -> SRGBColor {
        guard let colour = SRGBColor(hex: value) else {
            preconditionFailure("Malformed step accent hex literal: \(value)")
        }
        return colour
    }
}
