import Foundation
import ORModels

/// Maps a pace ratio onto one of the five judged zones, with boundary hysteresis
/// (FR-A-3).
///
/// The classifier is a pure function of `(ratio, band, previousZone)`. It never sees
/// the settling window, VO2 max mode, or a paused run — those force `neutral` upstream
/// (see `SettlingWindow` and `RunTypeSemantics`), which keeps this type answering
/// exactly one question.
public struct ZoneClassifier: Sendable {

    private let hysteresis: Double

    public init(config: ZoneConfiguration) {
        self.hysteresis = config.hysteresis
    }

    /// Classifies without hysteresis. The five zones partition the real line, in
    /// ascending ratio order, so this is total.
    public static func rawZone(ratio: Double, band: PaceBand) -> PaceZone {
        guard ratio.isFinite else { return .neutral }
        if ratio < 1 - band.fastFar { return .tooFast }
        if ratio < 1 - band.fastNear { return .slightlyFast }
        if ratio <= 1 + band.slowNear { return .onTarget }
        if ratio <= 1 + band.slowFar { return .slightlySlow }
        return .tooSlow
    }

    /// Classifies with hysteresis applied against the previous zone.
    ///
    /// Leaving a zone requires exceeding its boundary by the hysteresis margin;
    /// re-entering requires only the boundary itself. That asymmetry is what makes a
    /// pace hovering on an edge settle rather than oscillate (AC-FR-A-3-7).
    public func classify(ratio: Double, band: PaceBand, previous: PaceZone) -> PaceZone {
        let candidate = ZoneClassifier.rawZone(ratio: ratio, band: band)

        guard candidate != previous else { return previous }
        // `neutral` sits outside the ratio ordering — it is imposed, not measured — so
        // there is no boundary to be sticky about when leaving it.
        guard previous != .neutral, candidate != .neutral else { return candidate }

        if candidate.rawValue < previous.rawValue {
            // Moving toward the fast end: must break the previous zone's lower edge.
            let edge = ZoneClassifier.lowerBound(of: previous, band: band)
            return ratio < edge - hysteresis ? candidate : previous
        } else {
            // Moving toward the slow end: must break the previous zone's upper edge.
            let edge = ZoneClassifier.upperBound(of: previous, band: band)
            return ratio > edge + hysteresis ? candidate : previous
        }
    }

    // MARK: Boundaries

    /// Lowest ratio belonging to `zone`. `-infinity` for the fastest zone.
    public static func lowerBound(of zone: PaceZone, band: PaceBand) -> Double {
        switch zone {
        case .tooFast: return -.infinity
        case .slightlyFast: return 1 - band.fastFar
        case .onTarget: return 1 - band.fastNear
        case .slightlySlow: return 1 + band.slowNear
        case .tooSlow: return 1 + band.slowFar
        case .neutral: return -.infinity
        }
    }

    /// Highest ratio belonging to `zone`. `+infinity` for the slowest zone.
    public static func upperBound(of zone: PaceZone, band: PaceBand) -> Double {
        switch zone {
        case .tooFast: return 1 - band.fastFar
        case .slightlyFast: return 1 - band.fastNear
        case .onTarget: return 1 + band.slowNear
        case .slightlySlow: return 1 + band.slowFar
        case .tooSlow: return .infinity
        case .neutral: return .infinity
        }
    }
}
