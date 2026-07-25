import Foundation
import ORModels

/// How far through the run the runner is, in [0, 1] (design.md §5.2).
///
/// Progress drives the target pace curve, so a run with no plan must yield 0 — a flat
/// curve with no drift (AC-FR-A-2-7). Inventing progress for an open-ended run would
/// make the target wander for no reason the runner could predict.
public enum ProgressCalculator {

    /// Distance takes precedence over duration: a runner who planned 5 miles cares
    /// about the miles, and finishing early or late should not move the target.
    public static func progress(
        distanceCovered: Double,
        activeElapsed: TimeInterval,
        plannedDistanceMetres: Double?,
        plannedDurationSeconds: TimeInterval?
    ) -> Double {
        if let planned = plannedDistanceMetres, planned > 0, planned.isFinite {
            return clamp(distanceCovered / planned)
        }
        if let planned = plannedDurationSeconds, planned > 0, planned.isFinite {
            return clamp(activeElapsed / planned)
        }
        return 0
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Tracks elapsed time excluding paused intervals (AC-FR-D-1-3).
///
/// Paused time is excluded from elapsed, average pace, and step progress — a runner
/// who stops to tie a shoe has not run slower. Distance is deliberately *not* frozen:
/// if the watch records movement while paused, that movement really happened, and
/// hiding it would make total distance disagree with the route.
public struct ActiveClock: Sendable {

    private var accumulated: TimeInterval = 0
    private var lastTimestamp: TimeInterval?
    private var isPaused = false

    public init() {}

    /// Advances the clock to `timestamp`. Time is only accrued when not paused.
    public mutating func advance(to timestamp: TimeInterval, paused: Bool) {
        defer {
            lastTimestamp = timestamp
            isPaused = paused
        }
        guard let last = lastTimestamp else { return }
        let delta = timestamp - last
        guard delta > 0 else { return }
        // Credit the interval only if we were running for its whole duration. A
        // pause that lands mid-interval forfeits at most one tick, which at 1 Hz is
        // below the resolution of anything the runner sees.
        if !isPaused { accumulated += delta }
    }

    public var activeElapsed: TimeInterval { accumulated }

    public mutating func reset() {
        accumulated = 0
        lastTimestamp = nil
        isPaused = false
    }
}
