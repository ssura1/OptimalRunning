import Foundation
import ORAlerts
import ORIntervals
import ORModels
import ORPace

/// One thing to say, in structured form (S-041, design.md §9.2).
///
/// A value rather than a `String` because the tier that renders it and the tier that
/// decides it are different layers, and because a test asserting "the cue for a
/// too-fast excursion carries the right direction and the right number of seconds" should
/// not be a test about English.
public struct SpokenCue: Sendable, Hashable {

    public enum Direction: Sendable, Hashable {
        case easeOff
        case pickItUp
    }

    /// Why this cue exists. Drives the haptic that accompanies it and, for splits, which
    /// channel's on/off switch applies.
    public enum Kind: Sendable, Hashable {
        case pace(Direction, secondsOff: Int)
        case stepTransition(StepKind)
        case workoutComplete
        case split(index: Int)
        case timeProgress
        case gnssLost
        case gnssRestored
    }

    public let kind: Kind
    /// The sentence, already assembled from a single format string.
    public let phrase: String

    public init(kind: Kind, phrase: String) {
        self.kind = kind
        self.phrase = phrase
    }
}

/// Turns `Core`'s alert commands into spoken cues (ADR-S-05).
///
/// **Note how little this decides.** Whether the runner has drifted long enough, whether
/// this would be nagging, whether the run type permits pace feedback at all — every one of
/// those was answered by `AlertPolicy` inside `RunEngine`, which suppresses the alert at
/// source. If an `AlertCommand` reaches here it has already earned the right to be spoken.
///
/// That is the whole of ADR-S-05: the standalone tier adds a *renderer*, not a second
/// policy. A "speech policy" with its own dwell and cooldown would double the surface where
/// nagging can be introduced and would let audio and haptics disagree about whether an
/// excursion is worth mentioning — which to a runner reads as the app being confused.
public enum CueComposer {

    /// The cue for an alert, or `nil` where this tier says nothing.
    public static func cue(
        for alert: AlertCommand, runType: RunType, unit: UnitPreference
    ) -> SpokenCue? {
        // The single check that is not redundant with `Core`, and it is here for the same
        // reason `HapticDispatcher.permits` exists on the watch: VO2 max must never produce
        // pace feedback (FR-C-4), `RunEngine` already suppresses it, and asserting it again
        // on the way out makes a future refactor that breaks the suppression fail a tier
        // test rather than ship.
        if alert.isPaceAlert, !RunTypeSemantics(runType: runType).permitsPaceHaptics {
            return nil
        }

        switch alert {
        case let .paceTooFast(current, target):
            return paceCue(.easeOff, current: current, target: target, unit: unit)
        case let .paceTooSlow(current, target):
            return paceCue(.pickItUp, current: current, target: target, unit: unit)
        case let .stepTransition(transition):
            return stepCue(transition, unit: unit)
        case .workoutComplete:
            return SpokenCue(kind: .workoutComplete, phrase: StandaloneStrings.workoutComplete)
        }
    }

    /// AC-FR-S-C-3-3 — said **once**, at the transition, never repeatedly. The once-ness
    /// is the run controller's to enforce, because it owns the state that knows whether
    /// this transition has already happened; this type only knows how to say it.
    public static func gnssLost() -> SpokenCue {
        SpokenCue(kind: .gnssLost, phrase: StandaloneStrings.gnssLost)
    }

    public static func gnssRestored() -> SpokenCue {
        SpokenCue(kind: .gnssRestored, phrase: StandaloneStrings.gnssRestored)
    }

    // MARK: - Private

    private static func paceCue(
        _ direction: SpokenCue.Direction, current: Pace, target: Pace, unit: UnitPreference
    ) -> SpokenCue? {
        let delta = current.signedDelta(from: target, in: unit)
        guard delta.isFinite else { return nil }
        // The magnitude is spoken; the direction is carried by the verb. Speaking a signed
        // number ("minus twelve seconds") is how you make a cue that has to be decoded
        // rather than obeyed.
        let seconds = abs(Int(delta.rounded()))
        return SpokenCue(
            kind: .pace(direction, secondsOff: seconds),
            phrase: StandaloneStrings.paceCue(direction: direction, secondsOff: seconds))
    }

    private static func stepCue(
        _ transition: StepTransition, unit: UnitPreference
    ) -> SpokenCue? {
        guard let next = transition.to else {
            return SpokenCue(kind: .workoutComplete, phrase: StandaloneStrings.workoutComplete)
        }
        let goal: String?
        if let metres = next.goal.distanceMetres {
            goal = StandaloneStrings.stepGoalDistance(metres: metres, unit: unit)
        } else if let seconds = next.goal.timeSeconds {
            goal = StandaloneStrings.stepGoalDuration(seconds: seconds)
        } else {
            // An open goal has nothing to announce beyond its name — "Recovery." is the
            // whole cue, and inventing "until you tap" would be telling the runner to look
            // at a screen the design says they are not looking at.
            goal = nil
        }
        return SpokenCue(
            kind: .stepTransition(next.kind),
            phrase: StandaloneStrings.stepCue(kind: next.kind, goal: goal))
    }
}

/// Speaks a cue on real hardware. Implemented in the app target over
/// `AVSpeechSynthesizer`; faked in tests.
///
/// `stop()` exists because a run that ends mid-sentence should end, not finish the
/// sentence — and because AC-FR-S-A-2-3 requires the audio session released at teardown,
/// which cannot happen while an utterance is in flight.
@MainActor
public protocol CueSpeaking: AnyObject {
    func speak(_ cue: SpokenCue)
    func stop()
}
