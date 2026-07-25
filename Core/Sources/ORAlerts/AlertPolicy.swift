import Foundation
import ORIntervals
import ORModels

// MARK: - Commands

/// Something the watch should do to get the runner's attention.
public enum AlertCommand: Sendable, Hashable {
    case paceTooFast(current: Pace, target: Pace)
    case paceTooSlow(current: Pace, target: Pace)
    case stepTransition(StepTransition)
    case workoutComplete

    /// Whether this is a pace alert as opposed to a structural one. Pace alerts are
    /// the ones subject to dwell and cooldown.
    public var isPaceAlert: Bool {
        switch self {
        case .paceTooFast, .paceTooSlow: return true
        case .stepTransition, .workoutComplete: return false
        }
    }

    /// Step transitions outrank pace warnings for screen time: a runner who has just
    /// finished a rep needs to know that more than they need to know they were
    /// drifting during it (AC-FR-B-2-6).
    public var presentationPriority: Int {
        switch self {
        case .workoutComplete: return 3
        case .stepTransition: return 2
        case .paceTooFast, .paceTooSlow: return 1
        }
    }
}

// MARK: - Policy

/// Decides when a pace haptic fires (FR-B-1, design.md §7).
///
/// Two mechanisms, doing different jobs:
///
/// - **Dwell** stops the app reacting to noise. A runner who drifts for three seconds
///   does not need to be buzzed; a runner who has been 6% too fast for twenty seconds
///   does.
/// - **Cooldown** stops the app nagging. Sustained deviation produces at most one
///   haptic per minute per direction, which is what bounds an hour's run to sixty
///   alerts however badly it goes (AC-FR-B-1-8).
///
/// Pure and time-driven by caller-supplied timestamps, so "does it nag?" is a question
/// a unit test can answer without waiting an hour.
public struct AlertPolicy: Sendable {

    private let dwell: TimeInterval
    private let cooldown: TimeInterval

    /// The far-off zone currently being dwelt in, and since when.
    private var dwellZone: PaceZone?
    private var dwellSince: TimeInterval?

    /// Last fire time per direction. Separate entries so that returning to target and
    /// then overshooting the other way is not muted by the first direction's cooldown.
    private var lastFired: [PaceZone: TimeInterval] = [:]

    public init(config: AlertConfiguration) {
        self.dwell = config.dwellSeconds
        self.cooldown = config.cooldownSeconds
    }

    /// Evaluates one tick.
    ///
    /// - Parameters:
    ///   - zone: the zone after hysteresis and settling have been applied.
    ///   - suppressed: true during the settling window, while paused, in VO2 max mode,
    ///     and when the runner has turned pace haptics off (AC-FR-B-1-4, AC-FR-B-1-7).
    ///   - currentPace / targetPace: carried into the command so the warning screen can
    ///     state both without re-deriving them.
    public mutating func evaluate(
        zone: PaceZone,
        now: TimeInterval,
        suppressed: Bool,
        currentPace: Pace?,
        targetPace: Pace?
    ) -> AlertCommand? {

        // Anything other than a sustained far-off excursion clears the dwell. In
        // particular, returning to target resets the clock so the next excursion is
        // treated as new rather than resuming a part-served sentence (AC-FR-B-1-5).
        guard !suppressed, zone.isFarOff else {
            dwellZone = nil
            dwellSince = nil
            return nil
        }

        guard dwellZone == zone, let since = dwellSince else {
            dwellZone = zone
            dwellSince = now
            return nil
        }

        guard now - since >= dwell else { return nil }

        if let last = lastFired[zone], now - last < cooldown { return nil }

        guard let currentPace, let targetPace else { return nil }

        lastFired[zone] = now
        return zone == .tooFast
            ? .paceTooFast(current: currentPace, target: targetPace)
            : .paceTooSlow(current: currentPace, target: targetPace)
    }

    public mutating func reset() {
        dwellZone = nil
        dwellSince = nil
        lastFired.removeAll(keepingCapacity: true)
    }
}
