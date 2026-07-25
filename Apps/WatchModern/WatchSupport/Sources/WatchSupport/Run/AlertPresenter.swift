import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// A full-screen interruption the run UI can be showing.
public enum AlertPresentation: Sendable, Hashable {

    /// The FR-B-2 pace warning: direction, current, target, signed delta.
    case paceWarning(PaceWarning)
    /// The §12.4 step-transition screen.
    case stepTransition(TransitionScreen)

    public struct PaceWarning: Sendable, Hashable {
        public let zone: PaceZone
        public let current: Pace
        public let target: Pace
        /// Signed seconds per unit, positive when slower than target. Rendered
        /// alongside the colour, never instead of it (FR-J-1).
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

    /// Both durations are declared tunables (AC-FR-B-2-2 says so explicitly), so they
    /// are read from `PresentationConfiguration` rather than written here — NFR-21
    /// allows a tunable exactly one home.
    func displayDuration(_ config: PresentationConfiguration) -> TimeInterval {
        switch self {
        case .paceWarning: return config.warningAutoDismissSeconds
        case .stepTransition: return config.transitionScreenSeconds
        }
    }
}

/// Decides what interruption is on screen and for how long (T-043, FR-B-2).
///
/// Pure, tick-driven, and holding no `Timer`: the 1 Hz run loop already ticks, and a
/// separate timer would be a second clock to drift against — the same reasoning
/// `SampleStore` uses for its flush cadence. It also makes "does it dismiss at 4 s?"
/// a unit test with no waiting.
///
/// The rule most easily got wrong is dropping rather than queueing. A warning raised
/// while the display is dimmed is discarded outright (AC-FR-B-2-5), because by the
/// time the wrist is raised the pace it described is stale, and a stale warning is
/// worse than none — it tells the runner to correct something they may already have
/// corrected.
public struct AlertPresenter: Sendable {

    public private(set) var visible: AlertPresentation?
    private var shownAt: TimeInterval?
    /// Ticks at which a presentation was suppressed for being invisible, kept only
    /// so tests and the manual protocol can tell "dropped" from "never raised".
    public private(set) var droppedWhileDimmedCount = 0

    private let config: PresentationConfiguration

    public init(config: PresentationConfiguration = PresentationConfiguration()) {
        self.config = config
    }

    /// Offers an alert for presentation. Returns whether it was actually shown.
    @discardableResult
    public mutating func offer(
        _ alert: AlertCommand,
        now: TimeInterval,
        isLuminanceReduced: Bool,
        unit: UnitPreference
    ) -> Bool {
        guard let presentation = Self.presentation(for: alert, unit: unit) else { return false }

        if isLuminanceReduced {
            droppedWhileDimmedCount += 1
            return false
        }

        // A visible higher-priority screen is not interrupted: a pace warning must
        // not shove a step transition aside, though the reverse is correct.
        if let visible, visible.priority > presentation.priority { return false }

        self.visible = presentation
        shownAt = now
        return true
    }

    /// Advances the auto-dismiss clock, and drops anything visible that became
    /// invisible mid-display.
    public mutating func tick(now: TimeInterval, isLuminanceReduced: Bool) {
        guard let visible, let shownAt else { return }

        if isLuminanceReduced {
            // The wrist dropped while a warning was up. Same reasoning as refusing to
            // queue: there is no one to read it, and it will be stale on return.
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
        droppedWhileDimmedCount = 0
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
            // Completion is a destination screen the run controller navigates to,
            // not a 3-second interruption over the metrics page.
            return nil
        }
    }
}
