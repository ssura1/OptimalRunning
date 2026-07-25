import Foundation
import ORModels

/// The estimator's view of the terrain at one tick.
public struct GradeEstimate: Sendable, Hashable {
    /// False when no altitude has been supplied — the altimeter is unavailable, or
    /// the run is indoors. Distinct from "grade is zero", which is a real reading
    /// about flat ground (DEG-2).
    public let isAvailable: Bool
    /// Instantaneous grade over the trailing window, before smoothing.
    public let rawGrade: Double
    /// EWMA-smoothed grade.
    public let smoothedGrade: Double
    /// The grade the target is actually being adjusted by. Moves only once a change
    /// has persisted (AC-FR-A-4-2).
    public let appliedGrade: Double

    public static let unavailable = GradeEstimate(
        isAvailable: false, rawGrade: 0, smoothedGrade: 0, appliedGrade: 0
    )

    public init(isAvailable: Bool, rawGrade: Double, smoothedGrade: Double, appliedGrade: Double) {
        self.isAvailable = isAvailable
        self.rawGrade = rawGrade
        self.smoothedGrade = smoothedGrade
        self.appliedGrade = appliedGrade
    }
}

/// Estimates terrain grade from barometric altitude over horizontal distance
/// (AC-FR-A-4-1, AC-FR-A-4-2).
///
/// Three stages, each doing a distinct job:
///
/// 1. **A distance window**, not a time window. Grade is rise over run — a time
///    window would make the same hill read differently depending on how fast it is
///    climbed.
/// 2. **An EWMA**, which removes barometric noise.
/// 3. **A persistence gate**, which is what makes the app respond to *a hill* rather
///    than to *a kerb*. Without it, a bridge or an underpass would yank the pace
///    target around for no reason the runner can perceive.
///
/// Grade is reported unavailable until the full window has been travelled: dividing a
/// real altitude change by five metres of run produces a nonsense gradient, and the
/// first hundred metres of a run sit inside the settling window anyway.
public struct GradeEstimator: Sendable {

    private struct Point: Sendable {
        let distance: Double
        let altitude: Double
    }

    private let config: GradeConfiguration
    private var buffer: [Point] = []
    private var smoothed: Double?
    private var applied: Double = 0
    private var everReceivedAltitude = false

    /// When the current deviation from `applied` began, and its sign.
    private var deviationSince: TimeInterval?
    private var deviationSign: Int = 0

    public init(config: GradeConfiguration) {
        self.config = config
    }

    /// Feeds one tick. `relativeAltitude` is metres relative to session start;
    /// `nil` means the altimeter is unavailable.
    public mutating func ingest(
        cumulativeDistance: Double,
        relativeAltitude: Double?,
        timestamp: TimeInterval
    ) -> GradeEstimate {
        guard let altitude = relativeAltitude, altitude.isFinite else {
            return everReceivedAltitude ? currentEstimate(available: true) : .unavailable
        }
        everReceivedAltitude = true

        buffer.append(Point(distance: cumulativeDistance, altitude: altitude))
        trimBuffer(newestDistance: cumulativeDistance)

        guard let oldest = buffer.first else { return currentEstimate(available: true) }

        let spanned = cumulativeDistance - oldest.distance
        guard spanned >= config.windowMetres else {
            // Window not yet full. Report available but flat rather than inventing a
            // gradient from a few metres of travel.
            return currentEstimate(available: true)
        }

        let raw = (altitude - oldest.altitude) / spanned
        guard raw.isFinite else { return currentEstimate(available: true) }

        let alpha = config.smoothingAlpha
        let newSmoothed = smoothed.map { $0 + alpha * (raw - $0) } ?? raw
        smoothed = newSmoothed

        updateAppliedGrade(smoothed: newSmoothed, timestamp: timestamp)

        return GradeEstimate(
            isAvailable: true,
            rawGrade: raw,
            smoothedGrade: newSmoothed,
            appliedGrade: applied
        )
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        smoothed = nil
        applied = 0
        everReceivedAltitude = false
        deviationSince = nil
        deviationSign = 0
    }

    // MARK: - Private

    /// The applied grade adopts the smoothed grade only after the deviation has held
    /// the same sign, above threshold, for the full persistence interval.
    private mutating func updateAppliedGrade(smoothed: Double, timestamp: TimeInterval) {
        let delta = smoothed - applied
        let magnitude = abs(delta)

        guard magnitude > config.persistenceDeltaThreshold else {
            // Back inside the deadband: whatever was building has passed.
            deviationSince = nil
            deviationSign = 0
            return
        }

        let sign = delta > 0 ? 1 : -1
        if deviationSign != sign {
            // A new deviation, or one that flipped direction. Restart the clock —
            // an oscillation must not accumulate credit toward adoption.
            deviationSign = sign
            deviationSince = timestamp
            return
        }

        guard let since = deviationSince else {
            deviationSince = timestamp
            return
        }

        if timestamp - since >= config.persistenceSeconds {
            applied = smoothed
            deviationSince = nil
            deviationSign = 0
        }
    }

    private func currentEstimate(available: Bool) -> GradeEstimate {
        GradeEstimate(
            isAvailable: available,
            rawGrade: 0,
            smoothedGrade: smoothed ?? 0,
            appliedGrade: applied
        )
    }

    private mutating func trimBuffer(newestDistance: Double) {
        // Keep one point beyond the window so the span can straddle the boundary.
        let cutoff = newestDistance - config.windowMetres
        var firstKeep = 0
        for (index, point) in buffer.enumerated() {
            if point.distance >= cutoff { break }
            firstKeep = index
        }
        if firstKeep > 0 { buffer.removeFirst(firstKeep) }
    }
}
