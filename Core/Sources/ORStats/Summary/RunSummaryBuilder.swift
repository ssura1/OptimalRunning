import Foundation
import ORModels

/// Derives a run's denormalized totals from its samples (design.md §9.3).
///
/// **Why this is in `Core` rather than in either app.** Both watch tiers build a summary
/// when a run ends, and the phone builds one again when reconstructing a degraded record
/// from HealthKit alone (T-051). Three implementations of "how much climb was that?"
/// would disagree in the third decimal place at best, and the disagreement would surface
/// as a run whose lifetime totals shift depending on which path produced it. One
/// definition, shared.
///
/// This is a gap Wave 1 left: `RunSummary` was declared (T-026) with nothing to build one.
/// See the note on T-026 in `implementation.md`.
public enum RunSummaryBuilder {

    /// Builds the summary.
    ///
    /// `activeSeconds` is a parameter rather than something derived from the samples, and
    /// that is deliberate. `RunSample.timestamp` is *session*-relative — it advances while
    /// the run is paused, because the capture loop keeps recording so a resumed run has an
    /// unbroken series. Deriving active time from those timestamps would silently credit
    /// every pause as running time, which is exactly the kind of quietly-wrong number that
    /// is never noticed. `RunEngine`'s `ActiveClock` is the only authority on active time,
    /// so the caller passes what it says.
    ///
    /// Time in zone comes from the run-length-encoded timeline for the same reason: it is
    /// what the envelope carries and what the phone renders, so computing it a second way
    /// here would create two answers to one question.
    public static func build(
        samples: [RunSample],
        activeSeconds: TimeInterval,
        zoneTimeline: [ZoneSpan],
        config: StatsConfiguration = StatsConfiguration()
    ) -> RunSummary {
        let distance = distanceCovered(samples)
        let heartRates = samples.compactMap(\.heartRate).filter { $0.isFinite && $0 > 0 }

        return RunSummary(
            distanceMetres: distance,
            activeSeconds: activeSeconds,
            averagePace: Pace(distanceMetres: distance, seconds: activeSeconds),
            averageHeartRate: heartRates.isEmpty
                ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
            maxHeartRate: heartRates.max(),
            elevationGainMetres: elevationGain(samples, config: config),
            timeInZoneSeconds: ZoneTimeline.timeInZone(zoneTimeline)
        )
    }

    /// Distance covered during the recording.
    ///
    /// The difference between first and last, not simply the last value: a run whose first
    /// usable distance source arrives late opens at a non-zero cumulative reading (see
    /// `DistanceFusion`'s baseline rule), and treating that as distance covered would
    /// credit metres recorded before the series began.
    public static func distanceCovered(_ samples: [RunSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(last.cumulativeDistance - first.cumulativeDistance, 0)
    }

    /// Total climb, with hysteresis against altimeter jitter.
    ///
    /// **Why not a sum of positive deltas.** That is the obvious implementation and it is
    /// badly wrong. A barometric altimeter resolves about a metre but jitters continuously,
    /// so over a 5 400-sample run the positive half of that noise integrates into hundreds
    /// of metres of climb that never happened — a flat park loop reported as hilly, and
    /// every grade comparison built on top inheriting the error.
    ///
    /// Instead a reference altitude follows the runner: climb is credited only once the
    /// altitude has risen `elevationGainThresholdMetres` above the reference, and the
    /// reference tracks downward freely so a descent re-arms the next climb. Oscillation
    /// inside the threshold contributes nothing, which is the correct answer for standing
    /// still on a windy day.
    public static func elevationGain(
        _ samples: [RunSample],
        config: StatsConfiguration = StatsConfiguration()
    ) -> Double {
        let threshold = config.elevationGainThresholdMetres
        var gain = 0.0
        var reference: Double?

        for sample in samples {
            // A `nil` altitude is "no altimeter" (DEG-2), not "ground level". Skipping
            // rather than substituting 0 is what keeps an altimeter-less run reporting
            // zero climb instead of a fictional profile derived from missing data.
            guard let altitude = sample.relativeAltitude, altitude.isFinite else { continue }

            guard let current = reference else {
                reference = altitude
                continue
            }

            let delta = altitude - current
            if delta >= threshold {
                // A real climb. Credit all of it and move the reference up to here, so the
                // next threshold is measured from the new height rather than from the
                // bottom of the hill.
                gain += delta
                reference = altitude
            } else if delta < 0 {
                // Descending — follow it down immediately. Lagging here would let a long
                // descent swallow the start of the next climb.
                reference = altitude
            }
        }
        return gain
    }
}
