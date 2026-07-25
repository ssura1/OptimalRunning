import Foundation

/// A contiguous run of samples in a single zone.
public struct ZoneSpan: Codable, Sendable, Hashable {
    public let zone: PaceZone
    public let startSeconds: TimeInterval
    public let durationSeconds: TimeInterval

    public init(zone: PaceZone, startSeconds: TimeInterval, durationSeconds: TimeInterval) {
        self.zone = zone
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var endSeconds: TimeInterval { startSeconds + durationSeconds }
}

/// Run-length encoding of the zone series (AC-FR-D-2-3).
///
/// A well-paced tempo run sits in one zone for minutes at a time, so RLE turns 5 400
/// per-sample entries into a few dozen spans. Storing one entry per sample would be
/// both larger than the packed column it duplicates and slower to aggregate.
public enum ZoneTimeline {

    /// Encodes a zone series sampled at a fixed interval.
    ///
    /// The final span is given the full interval duration, so total encoded duration
    /// equals `count × interval` — which is what makes time-in-zone sum to the run
    /// duration rather than falling one sample short.
    public static func encode(
        zones: [PaceZone],
        startSeconds: TimeInterval = 0,
        intervalSeconds: TimeInterval = 1.0
    ) -> [ZoneSpan] {
        guard !zones.isEmpty else { return [] }

        var spans: [ZoneSpan] = []
        var currentZone = zones[0]
        var runStartIndex = 0

        for (index, zone) in zones.enumerated().dropFirst() where zone != currentZone {
            spans.append(ZoneSpan(
                zone: currentZone,
                startSeconds: startSeconds + Double(runStartIndex) * intervalSeconds,
                durationSeconds: Double(index - runStartIndex) * intervalSeconds
            ))
            currentZone = zone
            runStartIndex = index
        }

        spans.append(ZoneSpan(
            zone: currentZone,
            startSeconds: startSeconds + Double(runStartIndex) * intervalSeconds,
            durationSeconds: Double(zones.count - runStartIndex) * intervalSeconds
        ))
        return spans
    }

    /// Expands spans back into a per-sample zone series.
    public static func decode(_ spans: [ZoneSpan], intervalSeconds: TimeInterval = 1.0) -> [PaceZone] {
        guard intervalSeconds > 0 else { return [] }
        var zones: [PaceZone] = []
        for span in spans {
            let n = Int((span.durationSeconds / intervalSeconds).rounded())
            zones.append(contentsOf: repeatElement(span.zone, count: max(n, 0)))
        }
        return zones
    }

    /// Seconds spent in each zone, indexed by `PaceZone.rawValue` (AC-FR-F-2-4).
    public static func timeInZone(_ spans: [ZoneSpan]) -> [TimeInterval] {
        var totals = [TimeInterval](repeating: 0, count: PaceZone.allCases.count)
        for span in spans {
            totals[span.zone.rawValue] += span.durationSeconds
        }
        return totals
    }

    /// Fraction of total time spent in each zone, indexed by `PaceZone.rawValue`.
    /// Returns all zeros when the run has no duration, rather than dividing by zero.
    public static func fractionInZone(_ spans: [ZoneSpan]) -> [Double] {
        let totals = timeInZone(spans)
        let sum = totals.reduce(0, +)
        guard sum > 0 else { return totals.map { _ in 0 } }
        return totals.map { $0 / sum }
    }
}
