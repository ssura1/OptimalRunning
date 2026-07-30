import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// The phone's tactile vocabulary (S-043, FR-S-D-2).
///
/// One case per thing the app can say without a screen, and — the requirement that shapes
/// the list — **distinguishable by direction** (AC-FR-S-D-2-1). "Ease off" and "pick it
/// up" must not feel the same, because a runner who cannot tell them apart has to look at
/// the phone to find out, which is the thing this whole tier exists to avoid.
///
/// Declared here rather than as `UIImpactFeedbackGenerator` calls for the same reason the
/// watch declares `HapticPattern`: the mapping to the framework is a switch in the app
/// target, and keeping the decision here means "which pattern fires, and when" is
/// unit-testable while only "how it feels" needs hardware.
public enum StandaloneHapticPattern: String, Sendable, Hashable, CaseIterable {
    /// Descending double tap — "ease off" (design.md §9.2).
    case slowDown
    /// Ascending double tap — "pick it up".
    case speedUp
    /// Distinct triple tap, deliberately dissimilar to both pace patterns.
    case stepTransition
    /// A long pattern, unmistakable at the end of a workout.
    case workoutComplete
    /// A single tap. Splits and the GPS notice share it: both are informational, neither
    /// asks the runner to do anything, and a third informational pattern would dilute the
    /// two that mean "correct something".
    case notice
}

/// Plays a pattern on real hardware. Implemented in the app target; faked in tests.
///
/// `@MainActor` for the same reason `RunSensorFeed` is: the run controller is main-actor
/// isolated and this is called synchronously from its tick, so the alternative would be an
/// enqueued hop between the alert being decided and the buzz arriving.
@MainActor
public protocol HapticPlaying: AnyObject {
    func play(_ pattern: StandaloneHapticPattern)
}

/// Maps cues and alerts to haptic patterns (S-043).
///
/// Every event that produces a spoken cue produces a haptic (AC-FR-S-D-2-1), and the
/// mapping is total — which is what makes haptics a *complete* channel rather than a
/// decoration on the audio one. Disabling speech leaves this working unchanged
/// (AC-FR-S-D-1-7), and that is a property of where the switch is: speech is silenced at
/// the speaker, not at the composer.
public enum StandaloneHaptics {

    public static func pattern(for cue: SpokenCue) -> StandaloneHapticPattern {
        switch cue.kind {
        case let .pace(direction, _):
            return direction == .easeOff ? .slowDown : .speedUp
        case .stepTransition:
            return .stepTransition
        case .workoutComplete:
            return .workoutComplete
        case .split, .timeProgress, .gnssLost, .gnssRestored:
            return .notice
        }
    }

    /// Whether this cue may fire a haptic at all, given the run type and the runner's
    /// preferences.
    ///
    /// AC-FR-S-D-2-4: pace haptics can be turned off without turning off interval haptics.
    /// The asymmetry is deliberate and is inherited from the watch (AC-FR-B-1-7) — a
    /// runner who finds pace nudges intrusive still needs to know a rep has ended, because
    /// that one is not advice, it is the workout's structure.
    public static func permits(
        _ cue: SpokenCue, runType: RunType, profile: RunnerProfile
    ) -> Bool {
        switch cue.kind {
        case .pace:
            guard profile.paceHapticsEnabled else { return false }
            return RunTypeSemantics(runType: runType).permitsPaceHaptics
        case .stepTransition, .workoutComplete, .split, .timeProgress, .gnssLost,
            .gnssRestored:
            return true
        }
    }
}
