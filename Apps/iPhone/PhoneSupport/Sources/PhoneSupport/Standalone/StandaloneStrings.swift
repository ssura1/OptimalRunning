import Foundation
import ORColor
import ORIntervals
import ORModels

/// The standalone tier's display and spoken strings.
///
/// `Core` ships caption *keys* and no words (NFR-23), so each tier owns its wording. This
/// is that layer for the phone, and it is deliberately separate from the watch's
/// `RunStrings`: the phone can afford longer labels than a 40 mm face, and — more
/// importantly — half of these are spoken rather than read, which is a different writing
/// problem. "A BIT FAST" is a good glance target and a bad sentence.
///
/// English literals rather than a `.strings` catalog, the same scope call the watch tier
/// made and for the same reason: the keys are what `Core` commits to, so swapping these
/// bodies for `String(localized:)` touches this file and nothing else.
public enum StandaloneStrings {

    // MARK: Screen

    /// Zone captions, keyed by `ZoneAffordance.captionKey`.
    public static func zoneCaption(_ key: String) -> String {
        switch key {
        case "zone.tooFast": return "Too fast"
        case "zone.slightlyFast": return "A bit fast"
        case "zone.onTarget": return "On target"
        case "zone.slightlySlow": return "A bit slow"
        case "zone.tooSlow": return "Too slow"
        case "zone.neutral": return "—"
        default: return "—"
        }
    }

    public static func unitSuffix(_ unit: UnitPreference) -> String {
        switch unit {
        case .miles: return "mi"
        case .kilometres: return "km"
        }
    }

    public static func paceSuffix(_ unit: UnitPreference) -> String {
        "/" + unitSuffix(unit)
    }

    public static func stepKind(_ kind: StepKind) -> String {
        switch kind {
        case .warmup: return "Warm up"
        case .work: return "Work"
        case .recovery: return "Recovery"
        case .cooldown: return "Cool down"
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

    // MARK: Spoken
    //
    // Every one of these is a single format string with its values substituted in, never
    // a concatenation of fragments (AC-FR-S-D-1-9, NFR-23). The difference matters for
    // more than translation: a sentence assembled from pieces cannot be reordered, and
    // languages that put the direction after the quantity would be unsayable.

    /// "Ease off. 12 seconds fast." / "Pick it up. 9 seconds slow."
    public static func paceCue(direction: SpokenCue.Direction, secondsOff: Int) -> String {
        switch direction {
        case .easeOff: return "Ease off. \(secondsOff) seconds fast."
        case .pickItUp: return "Pick it up. \(secondsOff) seconds slow."
        }
    }

    /// "Recovery. 1000 metres." — or the duration form for a time-based step.
    public static func stepCue(kind: StepKind, goal: String?) -> String {
        guard let goal else { return "\(stepKind(kind))." }
        return "\(stepKind(kind)). \(goal)."
    }

    public static func stepGoalDistance(metres: Double, unit: UnitPreference) -> String {
        // Spoken in whole metres or yards rather than in the runner's fractional unit:
        // "zero point six two miles" is not a sentence, and interval goals are set in
        // round metres anyway.
        let rounded = Int(metres.rounded())
        return unit == .miles ? "\(rounded) metres" : "\(rounded) metres"
    }

    public static func stepGoalDuration(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total % 60 == 0 { return "\(total / 60) minutes" }
        return "\(total) seconds"
    }

    public static let workoutComplete = "Workout complete."

    /// "Mile 3. 7:58. Average 8:02."
    ///
    /// The pace is spoken as a clock-style string because that is how a runner says it
    /// and how the system voice reads it. Whether it is *intelligible* at running speed
    /// over wind and music is not something CI can answer, which is why it is on the
    /// manual protocol (AC-FR-S-D-1-9).
    public static func splitCue(
        index: Int, unit: UnitPreference, splitPace: String, averagePace: String
    ) -> String {
        let noun = unit == .miles ? "Mile" : "Kilometre"
        return "\(noun) \(index). \(splitPace). Average \(averagePace)."
    }

    /// "45 minutes. 5.2 miles. Average 8:02."
    public static func timeCue(
        elapsed: String, distance: String, unit: UnitPreference, averagePace: String
    ) -> String {
        "\(elapsed). \(distance) \(unitSuffix(unit)). Average \(averagePace)."
    }

    public static let gnssLost = "GPS signal lost. Pace is estimated."
    public static let gnssRestored = "GPS signal back."

    // MARK: Provenance and confidence

    /// AC-FR-S-E-2-1, on the detail screen.
    public static func provenance(measuredFraction: Double) -> String {
        let percent = Int((measuredFraction * 100).rounded())
        if percent >= 100 { return "All of this run's distance was measured by GPS." }
        if percent <= 0 { return "All of this run's distance was estimated from motion." }
        return "\(percent)% of this run's distance was measured by GPS; the rest was "
            + "estimated from motion."
    }

    /// AC-FR-S-E-2-4 — why a run is marked lower-confidence, in a sentence that says what
    /// would fix it.
    public static func lowerConfidenceReason(_ calibration: CalibrationSummary) -> String {
        if !calibration.isCalibrated {
            return "This run had no calibration to work from, so any estimated distance "
                + "used a published average rather than your own stride."
        }
        return "Your stride calibration had not settled when this run was recorded "
            + "(\(calibration.observationCount) of the GPS stretches it needs). Estimated "
            + "distance is less accurate than it will be on later runs."
    }
}
