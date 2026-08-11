import Foundation
import ORColor
import ORIntervals
import ORModels

/// The watch tier's display strings.
///
/// `Core` deliberately ships no string catalog (NFR-23) — it hands out caption *keys*
/// and leaves words to the app layer. This is that layer for the Modern watch.
///
/// Currently English literals rather than a `.strings` catalog, and that is a
/// deliberate MVP scope call rather than an oversight: the keys already exist and are
/// already the only thing `Core` commits to, so swapping these bodies for
/// `String(localized:)` lookups later touches this file and nothing else. Localization
/// is not in the MVP requirement set.
public enum RunStrings {

    /// Zone captions, keyed by `ZoneAffordance.captionKey`.
    ///
    /// Short and upper-case because they are read at a glance mid-stride, and because
    /// they must fit a 40 mm screen at the largest Dynamic Type size beside a glyph.
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

    /// The full words. Still what VoiceOver reads and what the post-run record uses —
    /// `stepKindCompact` is a *rendering*, not a rename.
    public static func stepKind(_ kind: StepKind) -> String {
        switch kind {
        case .warmup: return "WARM UP"
        case .work: return "WORK"
        case .recovery: return "RECOVERY"
        case .cooldown: return "COOL DOWN"
        }
    }

    /// What the metrics page draws (T-104).
    ///
    /// `WORK` and `RECOVERY` shrink to single letters because they alternate every few
    /// minutes and are read at a glance, mid-stride, on a 40 mm screen — and because
    /// `RECOVERY` is eight characters of a header that also has to carry a rep count and a
    /// distance countdown.
    ///
    /// **Warm-up and cool-down deliberately keep their words.** Abbreviating warm-up would
    /// put a bare `W` on screen meaning something other than the `W` that means work — an
    /// ambiguity invented entirely by the abbreviation, on the one step where a runner is
    /// least likely to be looking carefully. They are also not part of the alternation, so
    /// they gain nothing from being short.
    public static func stepKindCompact(_ kind: StepKind) -> String {
        switch kind {
        case .work: return "W"
        case .recovery: return "R"
        case .warmup, .cooldown: return stepKind(kind)
        }
    }

    /// The chip kind for a step, or `nil` for the steps that render as plain words.
    public static func accentKind(for kind: StepKind) -> StepAccentKind? {
        switch kind {
        case .work: return .work
        case .recovery: return .recovery
        case .warmup, .cooldown: return nil
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

    /// One-line description of what a run type is for, shown under its name on the
    /// start screen so the choice is not a guess.
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
