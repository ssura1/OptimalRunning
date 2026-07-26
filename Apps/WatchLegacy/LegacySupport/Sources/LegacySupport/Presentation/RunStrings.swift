import Foundation
import ORColor
import ORIntervals
import ORModels

/// The Legacy watch tier's display strings.
///
/// `Core` deliberately ships no string catalog (NFR-23) — it hands out caption *keys* and leaves
/// words to the app layer. This is that layer for the Legacy watch.
///
/// A deliberate duplicate of the Modern tier's table (AC-FR-K-1-4), and the duplication is
/// load-bearing rather than incidental: these exact strings are what the shared presentation
/// golden compares (see `PresentationEquivalenceTests`). A tier that rendered "WARMUP" where the
/// other rendered "WARM UP" would be a visible cross-tier inconsistency, so the strings are
/// pinned by test, not by convention.
public enum RunStrings {

    /// Zone captions, keyed by `ZoneAffordance.captionKey`.
    ///
    /// Short and upper-case because they are read at a glance mid-stride. On this tier the
    /// constraint is tighter than on Modern: the 38 mm Series 3 is the narrowest display the
    /// product supports at 136 points, so these strings and their glyph must fit that width —
    /// which `MetricsScreenTests` asserts for every zone at both case sizes.
    public static func zoneCaption(_ key: String) -> String {
        switch key {
        case "zone.tooFast": return "TOO FAST"
        case "zone.slightlyFast": return "A BIT FAST"
        case "zone.onTarget": return "ON TARGET"
        case "zone.slightlySlow": return "A BIT SLOW"
        case "zone.tooSlow": return "TOO SLOW"
        case "zone.neutral": return "—"
        default: return "—"
        }
    }

    public static func stepKind(_ kind: StepKind) -> String {
        switch kind {
        case .warmup: return "WARM UP"
        case .work: return "WORK"
        case .recovery: return "RECOVERY"
        case .cooldown: return "COOL DOWN"
        }
    }

    public static func runType(_ type: RunType) -> String {
        switch type {
        case .tempo: return "Tempo"
        case .easy: return "Easy"
        case .long: return "Long"
        case .interval: return "Intervals"
        case .vo2max: return "VO2 Max"
        }
    }

    /// One-line description of what a run type is for, shown under its name on the start screen so
    /// the choice is not a guess.
    public static func runTypeDetail(_ type: RunType) -> String {
        switch type {
        case .tempo: return "Comfortably hard, held steady"
        case .easy: return "Conversational recovery pace"
        case .long: return "Sustained distance, relaxed"
        case .interval: return "Structured reps with targets"
        case .vo2max: return "Max effort reps, no pace judging"
        }
    }

    public static func unitSuffix(_ unit: UnitPreference) -> String {
        switch unit {
        case .miles: return "mi"
        case .kilometres: return "km"
        }
    }

    /// `/mi` or `/km`.
    public static func paceSuffix(_ unit: UnitPreference) -> String {
        "/" + unitSuffix(unit)
    }
}
