import Foundation

/// Decides whether CoreLocation currently has a usable fix, for the purpose of choosing a
/// distance source — Legacy tier (T-063, feeds `DistanceReading.isAvailable` for `.location`).
///
/// A deliberate duplicate of the Modern tier's tracker (AC-FR-K-1-4). Identical timing, and
/// that is required rather than merely convenient: the `gps-dropout-tunnel` fixture's golden
/// encodes exactly when the pedometer takes over, so a tier that debounced differently would
/// fail AC-FR-K-1-2 on that fixture.
///
/// A single stale or low-accuracy fix must not immediately flip the app to the pedometer — GPS
/// has natural gaps of a few seconds under tree cover or between buildings. Only sustained
/// unavailability past the timeout counts as a real loss (DEG-1).
///
/// Series 3's GPS reacquires more slowly than later hardware, which argues for the debounce
/// being *at least* this long, never shorter. The 10 s default is unchanged from Modern because
/// the fixtures pin it; if Series 3 field testing shows it needs to be longer, that is a
/// divergence for design.md §8.1 and a regenerated golden, not a quiet edit here.
public struct GPSAvailabilityTracker: Sendable {

    private let timeoutSeconds: TimeInterval
    private var lastGoodFixAt: TimeInterval?
    private var latestTimestamp: TimeInterval = 0

    public init(timeoutSeconds: TimeInterval = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Records a tick. `isUsableFix` already reflects whatever accuracy threshold the adapter
    /// applied to the raw `CLLocation`.
    public mutating func record(timestamp: TimeInterval, isUsableFix: Bool) {
        latestTimestamp = timestamp
        if isUsableFix { lastGoodFixAt = timestamp }
    }

    /// Whether GPS should be treated as available. `true` until the timeout has elapsed since
    /// the last usable fix — including before any fix has ever arrived, since a run's opening
    /// seconds are not yet a loss.
    public var isAvailable: Bool {
        guard let lastGoodFixAt else { return latestTimestamp <= timeoutSeconds }
        return latestTimestamp - lastGoodFixAt <= timeoutSeconds
    }

    public mutating func reset() {
        lastGoodFixAt = nil
        latestTimestamp = 0
    }
}
