import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// The tactile vocabulary, one case per thing the app can say without a screen
/// (T-042, FR-B-1).
///
/// Deliberately an app-layer enum rather than `WKHapticType` directly: the mapping to
/// WatchKit is a one-line switch in the app target, and keeping the decision here
/// means "which pattern fires, and when" is unit-testable while only "how it feels"
/// needs hardware.
public enum HapticPattern: String, Sendable, Hashable, CaseIterable {
    /// Descending — "ease off".
    case slowDown
    /// Ascending — "pick it up".
    case speedUp
    /// A distinct notification, deliberately dissimilar to both pace patterns so it
    /// is identifiable without looking (AC-FR-B-1-3, AC-FR-C-2-2).
    case stepTransition
    case workoutComplete
}

/// Plays a pattern on real hardware. Implemented in the app target over
/// `WKInterfaceDevice`; faked in tests.
public protocol HapticPlaying: AnyObject {
    func play(_ pattern: HapticPattern)
}

/// Maps `Core`'s `AlertCommand` to a haptic pattern (T-042).
///
/// Note how little this does. Every question worth getting wrong — has the runner
/// dwelt long enough, is this a nag, is the runner in a mode where pace haptics are
/// wrong, are pace haptics switched off — was already answered by `AlertPolicy` and
/// `RunTypeSemantics` inside `RunEngine`, which suppresses the pace alert at source.
/// If an `AlertCommand` arrives here, it has already earned the right to fire.
///
/// Re-deciding any of that here is the specific mistake this type exists to prevent:
/// the watch app would then hold a second, subtly different copy of the alert policy,
/// and the golden fixtures — which only see `Core` — would keep passing while the
/// device misbehaved.
public enum HapticDispatcher {

    public static func pattern(for alert: AlertCommand) -> HapticPattern {
        switch alert {
        case .paceTooFast: return .slowDown
        case .paceTooSlow: return .speedUp
        case .stepTransition: return .stepTransition
        case .workoutComplete: return .workoutComplete
        }
    }

    /// Whether this alert may fire at all, given the run type.
    ///
    /// The single check that is *not* redundant with `Core`: VO2 max mode must never
    /// produce a pace haptic (FR-C-4), and asserting it on the way out as well as at
    /// source is cheap insurance on a requirement the product memo is emphatic
    /// about. `RunEngine` already suppresses these; this makes a future refactor
    /// that breaks that suppression fail a watch-tier test instead of shipping.
    public static func permits(_ alert: AlertCommand, runType: RunType) -> Bool {
        guard alert.isPaceAlert else { return true }
        return RunTypeSemantics(runType: runType).permitsPaceHaptics
    }
}
