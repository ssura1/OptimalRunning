import Foundation
import ORModels
import ORStats

/// A race result the runner reports, or an effort found in their history.
public struct RaceResult: Sendable, Hashable {
    public let distanceMetres: Double
    public let seconds: TimeInterval

    public init(distanceMetres: Double, seconds: TimeInterval) {
        self.distanceMetres = distanceMetres
        self.seconds = seconds
    }

    public var pace: Pace? { Pace(distanceMetres: distanceMetres, seconds: seconds) }
}

/// Derives training paces from a performance (T-062, AC-FR-I-1-2, design.md §14.1).
///
/// **Every derived pace is a suggestion, never a setting.** AC-FR-I-1-3 requires each to be
/// overridable and AC-FR-I-1-5 requires explicit confirmation before anything changes, so this
/// type only ever *returns* paces — it holds no store and writes nothing. A derivation that
/// silently updated the profile would be the one behaviour the requirements rule out.
public enum PaceDerivation {

    /// Riegel's exponent. 1.06 is the published value, and design.md §14.1 names it.
    ///
    /// Accurate to roughly 2–3% between adjacent distances and degrading over large
    /// extrapolations — which is why `derive` prefers the effort nearest the reference distance
    /// rather than whichever is fastest in absolute terms.
    public static let riegelExponent = 1.06

    /// The reference distance everything is normalised to before paces are derived.
    ///
    /// 10 km, per §14.1. Chosen because it sits between the 5 k a fit runner races and the half a
    /// marathoner trains for, so most extrapolations are short in both directions.
    public static let referenceDistanceMetres = 10_000.0

    /// Riegel: `T₂ = T₁ × (D₂/D₁)^1.06`.
    public static func equivalentTime(
        for targetDistance: Double,
        from result: RaceResult
    ) -> TimeInterval? {
        guard result.distanceMetres > 0, result.seconds > 0, targetDistance > 0 else { return nil }
        return result.seconds * pow(targetDistance / result.distanceMetres, riegelExponent)
    }

    /// Training paces derived from a performance.
    ///
    /// The percentages are of velocity at threshold, following the VDOT-style relationships in
    /// §14.1. They are expressed against the normalised 10 k pace, which for a well-trained runner
    /// sits close to threshold — a deliberate simplification of the full VDOT tables, and stated
    /// as such rather than presented as a physiological model: the product needs three usable
    /// training paces, not a laboratory estimate.
    public struct DerivedPaces: Sendable, Hashable {
        public let tempo: Pace
        public let easy: Pace
        public let long: Pace
        /// The normalised 10 k equivalent the three were derived from, so the UI can explain
        /// where they came from rather than presenting three numbers from nowhere.
        public let equivalentTenKilometreTime: TimeInterval

        public func pace(for runType: RunType) -> Pace? {
            switch runType {
            case .tempo: return tempo
            case .easy: return easy
            case .long: return long
            // Interval and VO2 max carry targets per step, not per run (FR-C-5).
            case .interval, .vo2max: return nil
            }
        }
    }

    /// Derives tempo, easy and long paces from one result.
    public static func derive(from result: RaceResult) -> DerivedPaces? {
        guard let tenK = equivalentTime(for: referenceDistanceMetres, from: result),
              let tenKPace = Pace(distanceMetres: referenceDistanceMetres, seconds: tenK),
              tenKPace.isValid
        else { return nil }

        // Multipliers on *pace*, not speed (ADR-003): above 1 is slower.
        //
        // Tempo runs a little easier than 10 k race pace, because 10 k for most runners is above
        // threshold and a tempo run must be sustainable for longer than a race. Easy is
        // deliberately much slower — the most common training error is running easy days too
        // hard, and a suggestion that errs slow is the safer of the two failures.
        return DerivedPaces(
            tempo: Pace(secondsPerMetre: tenKPace.secondsPerMetre * 1.06),
            easy: Pace(secondsPerMetre: tenKPace.secondsPerMetre * 1.30),
            long: Pace(secondsPerMetre: tenKPace.secondsPerMetre * 1.22),
            equivalentTenKilometreTime: tenK
        )
    }

    /// Finds the best effort in recent history to derive from (§14.1 step 1).
    ///
    /// Prefers the effort whose distance is *nearest* the 10 km reference rather than the fastest
    /// one. A blistering 1 km inside an interval session normalises to an implausible 10 k time
    /// because Riegel degrades badly over that extrapolation, and the resulting easy pace would
    /// be far too quick — the failure that injures people.
    public static func bestRecentEffort(
        in cache: AggregateCache,
        preferring reference: Double = referenceDistanceMetres
    ) -> RaceResult? {
        let candidates = cache.bests.values
            .filter { $0.seconds > 0 }
            .map { RaceResult(distanceMetres: $0.distance.metres, seconds: $0.seconds) }
            // Only distances long enough for Riegel to be meaningful. A 1 km best extrapolated
            // to 10 km is not evidence about a runner's 10 k.
            .filter { $0.distanceMetres >= 5_000 }

        return candidates.min {
            abs($0.distanceMetres - reference) < abs($1.distanceMetres - reference)
        }
    }

    // MARK: - Suggestions from actual performance (AC-FR-I-1-5)

    /// A proposed change to one run type's target, awaiting confirmation.
    public struct Suggestion: Sendable, Hashable {
        public let runType: RunType
        public let current: Pace?
        public let suggested: Pace
        /// How many runs of this type the suggestion is based on.
        public let sampleCount: Int

        /// Whether the change is large enough to be worth interrupting the runner about.
        public var isMeaningful: Bool {
            guard let current else { return true }
            return abs(suggested.secondsPerMetre - current.secondsPerMetre)
                / current.secondsPerMetre > 0.02
        }
    }

    /// The minimum runs of a type before a suggestion is offered (AC-FR-I-1-5).
    public static let minimumRunsForSuggestion = 5

    /// Suggests an updated target from actual performance.
    ///
    /// Returns `nil` below the threshold, and `nil` again if the change would be trivial — a
    /// prompt that appears after every fifth run to move a target by two seconds trains the
    /// runner to dismiss prompts, which costs more than the accuracy gains.
    ///
    /// **Never applies the change.** The caller must confirm it, which is the AC.
    public static func suggestTarget(
        for runType: RunType,
        recentPaces: [Pace],
        currentTarget: Pace?
    ) -> Suggestion? {
        let valid = recentPaces.filter(\.isValid)
        guard valid.count >= minimumRunsForSuggestion else { return nil }

        // The median, not the mean: one run cut short by traffic or a mis-started GPS fix should
        // not drag the suggestion, and with five samples a single outlier moves a mean
        // noticeably.
        let sorted = valid.map(\.secondsPerMetre).sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

        let suggestion = Suggestion(
            runType: runType,
            current: currentTarget,
            suggested: Pace(secondsPerMetre: median),
            sampleCount: valid.count
        )
        return suggestion.isMeaningful ? suggestion : nil
    }
}
