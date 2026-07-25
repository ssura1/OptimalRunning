import Foundation

/// Decides whether CoreLocation currently has a usable fix, for the purpose of
/// choosing a distance source (T-034, feeds `DistanceReading.isAvailable` for
/// `.location`).
///
/// A single stale or low-accuracy fix should not immediately flip the app to the
/// pedometer — GPS naturally has gaps of a few seconds under tree cover or between
/// buildings. Only sustained unavailability, past the configured timeout, counts as
/// a real loss (DEG-1). This mirrors `RollingPaceEstimator`'s own degradation
/// timing in `Core`, but is a distinct concern: that one governs pace smoothing,
/// this one governs which raw distance source the fusion layer should prefer.
public struct GPSAvailabilityTracker: Sendable {

    private let timeoutSeconds: TimeInterval
    private var lastGoodFixAt: TimeInterval?
    private var latestTimestamp: TimeInterval = 0

    public init(timeoutSeconds: TimeInterval = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Records a tick. `isUsableFix` should already reflect whatever accuracy
    /// threshold the caller applies to the raw `CLLocation`.
    public mutating func record(timestamp: TimeInterval, isUsableFix: Bool) {
        latestTimestamp = timestamp
        if isUsableFix { lastGoodFixAt = timestamp }
    }

    /// Whether GPS should currently be treated as available. `true` until the
    /// timeout has elapsed since the last usable fix — including before any fix
    /// has ever arrived, since a run's opening seconds are not yet a loss.
    public var isAvailable: Bool {
        guard let lastGoodFixAt else { return latestTimestamp <= timeoutSeconds }
        return latestTimestamp - lastGoodFixAt <= timeoutSeconds
    }

    public mutating func reset() {
        lastGoodFixAt = nil
        latestTimestamp = 0
    }
}
