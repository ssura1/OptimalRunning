import SwiftUI
import ORColor
import ORModels

/// The bridge from `ORColor`'s verified swatches to SwiftUI, mirroring the watch's
/// `ZoneStyle` (T-052, FR-J-1).
///
/// As on the watch, this is the only place the phone names a colour — and it names none of its
/// own. Every value comes from a swatch whose contrast `PaletteTests` verified, so a literal
/// introduced here would put an unverified colour on a chart and quietly void AC-FR-J-1-3.
extension Color {
    init(_ srgb: SRGBColor) {
        let (r, g, b) = srgb.components
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// The fill for a zone under the runner's chosen palette.
    static func zone(_ zone: PaceZone, palette: PaletteChoice) -> Color {
        Color(ZonePalette.palette(for: palette).swatch(for: zone).background)
    }
}

/// Zone naming and glyphs for the phone.
///
/// `Core` ships caption keys, not words (NFR-23), so each tier owns its wording. The phone can
/// afford longer labels than a 40 mm watch face, so these are sentence case rather than the
/// watch's shouted abbreviations.
enum ZoneLabels {

    static func name(_ zone: PaceZone) -> String {
        switch zone {
        case .tooFast: return "Too fast"
        case .slightlyFast: return "Slightly fast"
        case .onTarget: return "On target"
        case .slightlySlow: return "Slightly slow"
        case .tooSlow: return "Too slow"
        case .neutral: return "Not judged"
        }
    }

    /// The same glyph the watch uses, so the two tiers teach one visual vocabulary — and so a
    /// chart legend is readable in greyscale (AC-FR-F-2-9's "legible in greyscale").
    static func symbol(_ zone: PaceZone) -> String {
        ZoneAffordance.affordance(for: zone).symbolName
    }
}

/// Shared formatting for the phone's screens.
enum PhoneFormat {

    static func distance(_ metres: Double, unit: UnitPreference) -> String {
        "\(ORFormat.distance(metres, in: unit)) \(unitName(unit))"
    }

    static func pace(_ pace: Pace?, unit: UnitPreference) -> String {
        guard let pace, pace.isValid else { return "--" }
        return "\(ORFormat.pace(pace, in: unit)) /\(unitName(unit))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        ORFormat.duration(seconds)
    }

    static func heartRate(_ bpm: Double?) -> String {
        guard let bpm, bpm.isFinite, bpm > 0 else { return "--" }
        return "\(Int(bpm.rounded())) bpm"
    }

    static func unitName(_ unit: UnitPreference) -> String {
        switch unit {
        case .miles: return "mi"
        case .kilometres: return "km"
        }
    }

    static func runType(_ type: RunType) -> String {
        switch type {
        case .tempo: return "Tempo"
        case .easy: return "Easy"
        case .long: return "Long"
        case .interval: return "Intervals"
        case .vo2max: return "VO2 Max"
        }
    }
}
