import Foundation
import ORModels

/// One distance observation fed to the rolling pace estimator.
public struct DistanceSample: Sendable, Hashable {
    public let timestamp: TimeInterval
    /// Metres since session start, already fused across sources by the adapter.
    public let cumulativeDistance: Double
    /// Whether this observation is good enough to define a window endpoint.
    ///
    /// A poor GPS fix still advances `cumulativeDistance` — the pedometer or
    /// HealthKit contribution is real — but must never anchor the window, because a
    /// 50 m position error over a 200 m window is a 25% pace error (AC-FR-A-1-2).
    public let isTrusted: Bool

    public init(timestamp: TimeInterval, cumulativeDistance: Double, isTrusted: Bool) {
        self.timestamp = timestamp
        self.cumulativeDistance = cumulativeDistance
        self.isTrusted = isTrusted
    }
}

/// The result of one estimator tick.
public struct RollingPaceResult: Sendable, Hashable {
    /// `nil` when the window has not filled, the runner is stationary, or the
    /// computed value failed the plausibility check.
    public let pace: Pace?
    /// True once no trusted sample has arrived for longer than the configured
    /// timeout (AC-FR-A-1-3).
    public let isGPSDegraded: Bool
    /// True when the window shows effectively no movement (AC-FR-A-1-5).
    public let isStationary: Bool

    public init(pace: Pace?, isGPSDegraded: Bool, isStationary: Bool) {
        self.pace = pace
        self.isGPSDegraded = isGPSDegraded
        self.isStationary = isStationary
    }
}

/// Distance-windowed rolling pace (FR-A-1, ADR-004).
///
/// The window spans a trailing *distance*, not a trailing time. A fixed time window
/// covers wildly different distances at different speeds, so its noise characteristics
/// change with pace — the display gets jumpier the slower you run, which is exactly
/// backwards. A distance window holds the sample count roughly constant, and the time
/// bounds stop it becoming twitchy when sprinting or useless when nearly stopped.
///
/// Holds no wall-clock and no randomness: time enters only through sample timestamps.
/// That is what makes replayed fixtures bit-identical across runs (AC-FR-A-1-6).
public struct RollingPaceEstimator: Sendable {

    private let config: RollingPaceConfiguration
    private let fastestPace: Pace
    private let slowestPace: Pace

    /// Trusted samples only, oldest first. Trimmed to what the window can need.
    private var buffer: [DistanceSample] = []
    private var smoothed: Double?
    private var lastTrustedTimestamp: TimeInterval?
    private var latestTimestamp: TimeInterval = 0
    private var wasStationary = false

    public init(config: RollingPaceConfiguration) {
        self.config = config
        self.fastestPace = Pace(secondsPerMile: config.fastestPlausibleSecondsPerMile)
        self.slowestPace = Pace(secondsPerMile: config.slowestPlausibleSecondsPerMile)
    }

    /// Feeds one observation and returns the current estimate.
    public mutating func ingest(_ sample: DistanceSample) -> RollingPaceResult {
        latestTimestamp = sample.timestamp

        if sample.isTrusted {
            lastTrustedTimestamp = sample.timestamp
        }

        let degraded = isGPSDegraded()

        // Once GPS has been unusable for longer than the timeout, admit untrusted
        // samples to the window. `cumulativeDistance` is a fused figure — the
        // pedometer contribution is real even when no fix is — so this is the
        // pedometer fallback AC-FR-A-1-3 requires. Without it the window's newest
        // endpoint freezes and the display shows a stale pace for the whole tunnel,
        // which is worse than a slightly noisier live one.
        if sample.isTrusted || degraded {
            buffer.append(sample)
            trimBuffer()
        }

        guard let window = selectWindow() else {
            return RollingPaceResult(pace: nil, isGPSDegraded: degraded, isStationary: false)
        }

        // Stationary detection looks only at the trailing few seconds, not at the
        // whole pace window. Judging it over the full 200 m window would let twenty
        // seconds of running before a red light mask the forty seconds spent standing
        // at it — and the app would report "far too slow", buzz, and be wrong.
        if isStationary(now: sample.timestamp) {
            // Drop the smoothed value: carrying it across an indefinite stop would
            // blend pre-stop pace into the first post-stop reading.
            //
            // The buffer is kept intact here, not collapsed. Collapsing on every
            // stationary tick would leave too few samples to re-detect stationarity on
            // the next one, so the flag would stutter on and off for the whole stop.
            // The collapse happens once, on resumption, below.
            smoothed = nil
            wasStationary = true
            return RollingPaceResult(pace: nil, isGPSDegraded: degraded, isStationary: true)
        }

        if wasStationary {
            // Movement has resumed. Restart the window from here, so the forty seconds
            // spent at a junction do not sit inside the trailing 200 m for the best
            // part of a minute — which would have the app report "far too slow" and
            // buzz a runner who is pacing perfectly well. Pace is briefly undefined
            // instead, which reads as neutral and says nothing, and saying nothing is
            // the honest answer until there is fresh ground to measure.
            wasStationary = false
            buffer = [sample]
            return RollingPaceResult(pace: nil, isGPSDegraded: degraded, isStationary: false)
        }

        let spannedDistance = window.end.cumulativeDistance - window.start.cumulativeDistance
        let spannedSeconds = window.end.timestamp - window.start.timestamp

        guard let raw = Pace(distanceMetres: spannedDistance, seconds: spannedSeconds) else {
            return RollingPaceResult(pace: smoothedPace(), isGPSDegraded: degraded, isStationary: false)
        }

        // Plausibility: outside this range is a sensor artefact, not a runner. Such a
        // value must not enter the EWMA, or it would contaminate the next ~15 s.
        guard raw >= fastestPace, raw <= slowestPace else {
            return RollingPaceResult(pace: smoothedPace(), isGPSDegraded: degraded, isStationary: false)
        }

        let alpha = config.smoothingAlpha
        smoothed = smoothed.map { $0 + alpha * (raw.secondsPerMetre - $0) } ?? raw.secondsPerMetre

        return RollingPaceResult(pace: smoothedPace(), isGPSDegraded: degraded, isStationary: false)
    }

    /// Discards accumulated state. Used when a run restarts.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        smoothed = nil
        lastTrustedTimestamp = nil
        latestTimestamp = 0
        wasStationary = false
    }

    // MARK: - Private

    private func smoothedPace() -> Pace? {
        smoothed.map { Pace(secondsPerMetre: $0) }
    }

    /// True when the runner has covered essentially no ground in the trailing
    /// `stationarySeconds` (AC-FR-A-1-5).
    ///
    /// Needs a sample at least that old to judge against; before then the run has not
    /// been going long enough for standing still to be distinguishable from starting.
    private func isStationary(now: TimeInterval) -> Bool {
        guard let newest = buffer.last else { return false }
        let cutoff = now - config.stationarySeconds

        var oldestWithinWindow: DistanceSample?
        for sample in buffer.reversed() {
            oldestWithinWindow = sample
            if sample.timestamp <= cutoff { break }
        }

        guard let oldest = oldestWithinWindow,
              newest.timestamp - oldest.timestamp >= config.stationarySeconds
        else { return false }

        return newest.cumulativeDistance - oldest.cumulativeDistance < config.stationaryDistanceMetres
    }

    private func isGPSDegraded() -> Bool {
        guard let last = lastTrustedTimestamp else {
            // No trusted sample has ever arrived. Only call that degraded once enough
            // time has passed that a fix should have been acquired.
            return latestTimestamp > config.gpsDegradedAfterSeconds
        }
        return latestTimestamp - last > config.gpsDegradedAfterSeconds
    }

    /// The window is the trailing `windowMetres`, clamped to
    /// `[minWindowSeconds, maxWindowSeconds]`.
    private func selectWindow() -> (start: DistanceSample, end: DistanceSample)? {
        guard let end = buffer.last, buffer.count >= 2 else { return nil }

        var startIndex = buffer.count - 1

        // Walk back until the window spans the target distance or hits the time ceiling.
        var index = buffer.count - 2
        while index >= 0 {
            let candidate = buffer[index]
            startIndex = index
            let distance = end.cumulativeDistance - candidate.cumulativeDistance
            let seconds = end.timestamp - candidate.timestamp
            if distance >= config.windowMetres || seconds >= config.maxWindowSeconds { break }
            index -= 1
        }

        // If that left the window shorter than the time floor, extend it. A fast
        // runner covers 200 m in under 40 s, and a window that short chases noise.
        while startIndex > 0,
              end.timestamp - buffer[startIndex].timestamp < config.minWindowSeconds {
            startIndex -= 1
        }

        // Never let the extension push past the time ceiling.
        while startIndex < buffer.count - 1,
              end.timestamp - buffer[startIndex].timestamp > config.maxWindowSeconds {
            startIndex += 1
        }

        let start = buffer[startIndex]
        guard start.timestamp < end.timestamp else { return nil }
        return (start, end)
    }

    /// Keeps the buffer bounded. Anything older than the time ceiling *and* outside
    /// the distance window can never be selected again.
    private mutating func trimBuffer() {
        guard let end = buffer.last else { return }
        let cutoffTime = end.timestamp - config.maxWindowSeconds
        // Retain one sample beyond the cutoff so the window can still straddle it.
        var firstKeep = 0
        for (index, sample) in buffer.enumerated() {
            if sample.timestamp >= cutoffTime { break }
            firstKeep = index
        }
        if firstKeep > 0 {
            buffer.removeFirst(firstKeep)
        }
    }
}
