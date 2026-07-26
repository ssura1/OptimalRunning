import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// A full-screen interruption the run UI can be showing — Legacy tier.
public enum AlertPresentation: Sendable, Hashable {

    /// The FR-B-2 pace warning: direction, current, target, signed delta.
    case paceWarning(PaceWarning)
    /// The §12.4 step-transition screen.
    case stepTransition(TransitionScreen)

    public struct PaceWarning: Sendable, Hashable {
        public let zone: PaceZone
        public let current: Pace
        public let target: Pace
        /// Signed seconds per unit, positive when slower than target. Rendered alongside the colour,
        /// never instead of it (FR-J-1).
        public let signedDelta: Double

        public init(zone: PaceZone, current: Pace, target: Pace, signedDelta: Double) {
            self.zone = zone
            self.current = current
            self.target = target
            self.signedDelta = signedDelta
        }
    }

    public struct TransitionScreen: Sendable, Hashable {
        public let from: ResolvedStep
        public let to: ResolvedStep?
        public let completedDistanceMetres: Double
        public let completedActiveSeconds: TimeInterval
        public let completedAveragePace: Pace?

        public init(
            from: ResolvedStep,
            to: ResolvedStep?,
            completedDistanceMetres: Double,
            completedActiveSeconds: TimeInterval,
            completedAveragePace: Pace?
        ) {
            self.from = from
            self.to = to
            self.completedDistanceMetres = completedDistanceMetres
            self.completedActiveSeconds = completedActiveSeconds
            self.completedAveragePace = completedAveragePace
        }
    }

    /// Step transitions outrank pace warnings (AC-FR-B-2-6). Higher wins.
    var priority: Int {
        switch self {
        case .paceWarning: return 0
        case .stepTransition: return 1
        }
    }

    /// Both durations are declared tunables (AC-FR-B-2-2 says so explicitly), so they are read from
    /// `PresentationConfiguration` rather than written here — NFR-21 allows a tunable one home.
    func displayDuration(_ config: PresentationConfiguration) -> TimeInterval {
        switch self {
        case .paceWarning: return config.warningAutoDismissSeconds
        case .stepTransition: return config.transitionScreenSeconds
        }
    }
}

/// Decides what interruption is on screen and for how long — Legacy tier (T-068, FR-B-2).
///
/// Pure and tick-driven, holding no `Timer`: the 1 Hz run loop already ticks, and a separate timer
/// would be a second clock to drift against — the same reasoning `SampleStore` uses for its flush
/// cadence. It also makes "does it dismiss at 4 s?" a unit test with no waiting, which on this tier
/// is the only kind of test available.
///
/// ## The always-on divergence, and why the signal differs while the rule does not
///
/// The Modern tier's presenter takes `isLuminanceReduced` and drops any warning raised while the
/// display is dimmed (AC-FR-B-2-5): by the time the wrist is raised the pace it described is stale,
/// and a stale warning is worse than none — it tells the runner to correct something they may
/// already have corrected.
///
/// **Series 3 has no dimmed state.** Between wrist raises the display is fully off, and watchOS 8
/// exposes nothing equivalent to `isLuminanceReduced` — the app simply becomes inactive. So this
/// tier takes `isScreenVisible` instead, driven by the extension's active/inactive lifecycle rather
/// than by a luminance property.
///
/// The *rule* is deliberately identical, because the reasoning behind it is about the runner's
/// attention and not about the hardware: a warning nobody can read is dropped, never queued. Keeping
/// `isLuminanceReduced` here and always passing `false` would have been the easy path and would have
/// silently disabled AC-FR-B-2-5 on this tier — a requirement quietly lost to a parameter that
/// could never be true. Recorded in design.md §8.1.
public struct AlertPresenter: Sendable {

    public private(set) var visible: AlertPresentation?
    private var shownAt: TimeInterval?
    /// Count of presentations suppressed because the screen was off, kept so tests and the manual
    /// protocol can tell "dropped" from "never raised".
    public private(set) var droppedWhileScreenOffCount = 0

    private let config: PresentationConfiguration

    public init(config: PresentationConfiguration = PresentationConfiguration()) {
        self.config = config
    }

    /// Offers an alert for presentation. Returns whether it was actually shown.
    @discardableResult
    public mutating func offer(
        _ alert: AlertCommand,
        now: TimeInterval,
        isScreenVisible: Bool,
        unit: UnitPreference
    ) -> Bool {
        guard let presentation = Self.presentation(for: alert, unit: unit) else { return false }

        if !isScreenVisible {
            droppedWhileScreenOffCount += 1
            return false
        }

        // A visible higher-priority screen is not interrupted: a pace warning must not shove a step
        // transition aside, though the reverse is correct.
        if let visible, visible.priority > presentation.priority { return false }

        self.visible = presentation
        shownAt = now
        return true
    }

    /// Advances the auto-dismiss clock, and drops anything visible when the screen goes off
    /// mid-display.
    public mutating func tick(now: TimeInterval, isScreenVisible: Bool) {
        guard let visible, let shownAt else { return }

        if !isScreenVisible {
            // The wrist dropped while a warning was up. Same reasoning as refusing to queue: there
            // is no one to read it, and it will be stale on return.
            dismiss()
            return
        }
        if now - shownAt >= visible.displayDuration(config) { dismiss() }
    }

    /// Tap or crown rotation (AC-FR-B-2-4, CON-1 — never a crown *press*).
    public mutating func dismiss() {
        visible = nil
        shownAt = nil
    }

    public mutating func reset() {
        dismiss()
        droppedWhileScreenOffCount = 0
    }

    private static func presentation(
        for alert: AlertCommand,
        unit: UnitPreference
    ) -> AlertPresentation? {
        switch alert {
        case let .paceTooFast(current, target):
            return .paceWarning(.init(
                zone: .tooFast, current: current, target: target,
                signedDelta: current.signedDelta(from: target, in: unit)
            ))
        case let .paceTooSlow(current, target):
            return .paceWarning(.init(
                zone: .tooSlow, current: current, target: target,
                signedDelta: current.signedDelta(from: target, in: unit)
            ))
        case let .stepTransition(transition):
            return .stepTransition(.init(
                from: transition.from,
                to: transition.to,
                completedDistanceMetres: transition.completedDistanceMetres,
                completedActiveSeconds: transition.completedActiveSeconds,
                completedAveragePace: Pace(
                    distanceMetres: transition.completedDistanceMetres,
                    seconds: transition.completedActiveSeconds
                )
            ))
        case .workoutComplete:
            // Completion is a destination screen the run controller navigates to, not a 3-second
            // interruption over the metrics page.
            return nil
        }
    }
}
