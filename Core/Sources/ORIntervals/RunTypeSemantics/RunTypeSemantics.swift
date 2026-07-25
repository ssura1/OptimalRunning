import Foundation
import ORModels

/// Encodes the behavioural difference between run types (design.md §6.3).
///
/// The one that matters most is Interval versus VO2 max. They are structurally
/// identical — both are step lists with repeat blocks — and it would be easy to let
/// VO2 max collapse into "an interval workout with no targets set". It must not.
///
/// A VO2 max session is a *test of capability*. Colouring the screen would tell the
/// runner what the app expects, and a runner who is being told what to expect is no
/// longer producing a clean measurement. So VO2 max refuses colour and pace haptics
/// unconditionally — not because its steps happen to lack targets, but because the run
/// type says so. A target accidentally attached to a VO2 max step changes nothing.
public struct RunTypeSemantics: Sendable {

    public let runType: RunType

    public init(runType: RunType) {
        self.runType = runType
    }

    /// Whether the run type permits colouring at all.
    public var permitsColouring: Bool { runType.appliesZoneColouring }

    /// Whether pace haptics may ever fire (AC-FR-C-4-4, AC-FR-B-1-4).
    public var permitsPaceHaptics: Bool { runType.firesPaceHaptics }

    /// Step-transition haptics fire for every run type, including VO2 max — the buzz
    /// at 1000 m is the entire reason the runner does not need a track.
    public var permitsTransitionHaptics: Bool { true }

    /// The target in force for a step, or `nil` if the step is not judged.
    ///
    /// - VO2 max: always `nil`, whatever the step or profile says.
    /// - Interval: the step's own target; steps without one are not judged
    ///   (AC-FR-C-5-1, AC-FR-C-5-3).
    /// - Continuous runs: the profile's base pace for the run type, with the standard
    ///   band. No profile pace means no judgement, and the run records neutral
    ///   throughout rather than refusing to start (DEG-9).
    public func effectiveTarget(
        for step: ResolvedStep?,
        profileBasePace: Pace?,
        defaultBand: PaceBand
    ) -> StepTarget? {
        guard permitsColouring else { return nil }

        switch runType {
        case .vo2max:
            return nil
        case .interval:
            guard let target = step?.target else { return nil }
            return StepTarget(pace: target.pace, band: target.band ?? defaultBand)
        case .tempo, .easy, .long:
            // A per-step target still wins if one was set, so a planned workout can
            // override the profile for a single session.
            if let target = step?.target {
                return StepTarget(pace: target.pace, band: target.band ?? defaultBand)
            }
            guard let base = profileBasePace else { return nil }
            return StepTarget(pace: base, band: defaultBand)
        }
    }
}
