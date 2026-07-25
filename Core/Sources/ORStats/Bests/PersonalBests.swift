import Foundation
import ORModels

/// A distance runners measure themselves against.
public enum BenchmarkDistance: String, Codable, Sendable, Hashable, CaseIterable {
    case oneKilometre
    case oneMile
    case fiveKilometres
    case tenKilometres
    case halfMarathon
    case marathon

    public var metres: Double {
        switch self {
        case .oneKilometre: return 1000
        case .oneMile: return Pace.metresPerMile
        case .fiveKilometres: return 5000
        case .tenKilometres: return 10_000
        case .halfMarathon: return 21_097.5
        case .marathon: return 42_195
        }
    }
}

/// The fastest effort at a benchmark distance found inside a run.
public struct BestEffort: Codable, Sendable, Hashable {
    public let distance: BenchmarkDistance
    public let seconds: TimeInterval
    /// Where in the run the effort started, in metres from the start.
    public let startDistanceMetres: Double

    public init(distance: BenchmarkDistance, seconds: TimeInterval, startDistanceMetres: Double) {
        self.distance = distance
        self.seconds = seconds
        self.startDistanceMetres = startDistanceMetres
    }

    public var pace: Pace? { Pace(distanceMetres: distance.metres, seconds: seconds) }
}

/// Finds best efforts as the fastest *rolling segment* within a run (AC-FR-F-3-4).
///
/// Not "the run's total time if the run happened to be 5 km". A 5 km personal best set
/// inside a 10 km run counts, because that is what runners mean by a PB and what every
/// other platform reports. Computing it any other way produces a statistics screen the
/// user immediately distrusts.
///
/// Two-pointer sweep, O(n) per benchmark distance. Six distances over a 5 400-sample
/// run is trivial work at ingest and zero work at read.
public enum PersonalBestSweep {

    /// - Parameters:
    ///   - cumulativeDistance: monotonically non-decreasing metres.
    ///   - timestamps: matching active-elapsed seconds.
    public static func bestEffort(
        distance benchmark: BenchmarkDistance,
        cumulativeDistance: [Double],
        timestamps: [TimeInterval]
    ) -> BestEffort? {
        let target = benchmark.metres
        guard cumulativeDistance.count == timestamps.count,
              cumulativeDistance.count >= 2,
              let total = cumulativeDistance.last,
              let first = cumulativeDistance.first,
              total - first >= target
        else { return nil }

        var start = 0
        var best: TimeInterval = .infinity
        var bestStart: Double = 0

        for end in 1..<cumulativeDistance.count {
            // Advance the trailing pointer as far as it can go while the window still
            // covers the benchmark. That leaves the tightest window ending at `end`.
            while start + 1 < end,
                  cumulativeDistance[end] - cumulativeDistance[start + 1] >= target {
                start += 1
            }
            guard cumulativeDistance[end] - cumulativeDistance[start] >= target else { continue }

            let elapsed = timestamps[end] - timestamps[start]
            if elapsed > 0, elapsed < best {
                best = elapsed
                bestStart = cumulativeDistance[start]
            }
        }

        guard best.isFinite else { return nil }
        return BestEffort(distance: benchmark, seconds: best, startDistanceMetres: bestStart)
    }

    /// Sweeps every benchmark the run is long enough to contain.
    public static func allBestEfforts(
        cumulativeDistance: [Double],
        timestamps: [TimeInterval]
    ) -> [BenchmarkDistance: BestEffort] {
        var results: [BenchmarkDistance: BestEffort] = [:]
        for benchmark in BenchmarkDistance.allCases {
            if let effort = bestEffort(
                distance: benchmark,
                cumulativeDistance: cumulativeDistance,
                timestamps: timestamps
            ) {
                results[benchmark] = effort
            }
        }
        return results
    }
}
