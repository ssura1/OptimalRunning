import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// The tactile vocabulary, one case per thing the app can say without a screen — Legacy tier
/// (T-068, FR-B-1).
///
/// An app-layer enum rather than `WKHapticType` directly: the mapping to WatchKit is a one-line
/// switch in the extension target, and keeping the decision here means "which pattern fires, and
/// when" is unit-testable while only "how it feels" needs hardware.
///
/// That split matters more on this tier than on Modern. Series 3's haptic engine is the oldest in
/// the supported range and genuinely feels different — weaker, with less separation between
/// patterns — so "how it feels" is a real hardware question here, not a formality. It is on the
/// hardware-verification list for exactly that reason.
public enum HapticPattern: String, Sendable, Hashable, CaseIterable {
    /// Descending — "ease off".
    case slowDown
    /// Ascending — "pick it up".
    case speedUp
    /// A distinct notification, deliberately dissimilar to both pace patterns so it is identifiable
    /// without looking (AC-FR-B-1-3, AC-FR-C-2-2).
    case stepTransition
    case workoutComplete
}

/// Plays a pattern on real hardware. Implemented in the extension target over `WKInterfaceDevice`;
/// faked in tests.
public protocol HapticPlaying: AnyObject {
    func play(_ pattern: HapticPattern)
}

/// Maps `Core`'s `AlertCommand` to a haptic pattern — Legacy tier (T-068).
///
/// A deliberate duplicate of the Modern tier's dispatcher (AC-FR-K-1-4). Note how little it does:
/// every question worth getting wrong — has the runner dwelt long enough, is this a nag, is the
/// runner in a mode where pace haptics are wrong, are pace haptics switched off — was already
/// answered by `AlertPolicy` and `RunTypeSemantics` inside `RunEngine`, which suppresses the pace
/// alert at source. An `AlertCommand` arriving here has already earned the right to fire.
///
/// Re-deciding any of that here is the specific mistake this type exists to prevent, and on this
/// tier the consequence is the wave's central failure mode: the Legacy app would hold a second,
/// subtly different copy of the alert policy, the shared golden fixtures would keep passing because
/// they only see `Core`, and the two watches would buzz at different moments during the same run.
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
    /// The single check that is *not* redundant with `Core`: VO2 max mode must never produce a pace
    /// haptic (FR-C-4), and asserting it on the way out as well as at source is cheap insurance on a
    /// requirement the product memo is emphatic about. `RunEngine` already suppresses these; this
    /// makes a future refactor that breaks the suppression fail a watch-tier test instead of
    /// shipping to a wrist.
    public static func permits(_ alert: AlertCommand, runType: RunType) -> Bool {
        guard alert.isPaceAlert else { return true }
        return RunTypeSemantics(runType: runType).permitsPaceHaptics
    }
}
