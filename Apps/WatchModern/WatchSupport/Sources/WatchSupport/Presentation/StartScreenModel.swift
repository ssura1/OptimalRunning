import Foundation
import Observation
import ORIntervals
import ORModels

/// One row on the start screen.
public struct RunTypeOption: Sendable, Hashable {
    public let runType: RunType
    public let title: String
    public let detail: String
    /// `8:00 /mi`, or `nil` for a type with no per-run target (FR-C-5) or no stored
    /// base pace yet.
    public let targetText: String?
    /// `7:52 – 8:14`, the band around the target, so the runner can see what counts as
    /// on-target before starting rather than discovering it mid-run.
    public let bandText: String?
    /// True for interval and VO2 max, which start from a plan rather than a pace.
    public let isStructured: Bool
}

/// Drives the start screen: which run types exist, what each one's target looks like,
/// and the per-run target adjustment (T-046, FR-A-7).
///
/// The adjustment is the part worth being careful about. AC-FR-A-7 requires that
/// nudging a target for today's run does **not** rewrite the stored profile — a runner
/// who is tired and eases off by fifteen seconds has not changed their tempo pace, and
/// silently retraining the profile on a bad day would make every future target drift
/// downward. So the adjustment lives here, in transient state, and is handed to the
/// engine as a one-run override; `SettingsStore` is never touched.
@MainActor
@Observable
public final class StartScreenModel {

    /// Per-run target overrides, keyed by run type, cleared when the run ends.
    /// Deliberately not persisted — see the type note.
    private var adjustments: [RunType: Pace] = [:]

    public private(set) var profile: RunnerProfile
    /// The workout the phone scheduled for today, if any. The start screen shows it in
    /// its own slot above the five run types (FR-A-7).
    public private(set) var plannedWorkout: WorkoutPlan?

    private let configuration: PaceEngineConfiguration

    public init(
        profile: RunnerProfile,
        plannedWorkout: WorkoutPlan? = nil,
        configuration: PaceEngineConfiguration = .default
    ) {
        self.profile = profile
        self.plannedWorkout = plannedWorkout
        self.configuration = configuration
    }

    public func update(profile: RunnerProfile) {
        self.profile = profile
    }

    public func update(plannedWorkout: WorkoutPlan?) {
        self.plannedWorkout = plannedWorkout
    }

    /// All five run types, in the order the memo lists them, every one reachable.
    public var options: [RunTypeOption] {
        RunType.allCases.map(option(for:))
    }

    public func option(for runType: RunType) -> RunTypeOption {
        let target = effectiveTarget(for: runType)
        let band = configuration.band(for: runType)

        return RunTypeOption(
            runType: runType,
            title: RunStrings.runType(runType),
            detail: RunStrings.runTypeDetail(runType),
            targetText: target.map {
                ORFormat.pace($0, in: profile.units) + " " + RunStrings.paceSuffix(profile.units)
            },
            bandText: target.map { bandText(around: $0, band: band) },
            isStructured: runType.isStructured
        )
    }

    /// The target this run would use: today's adjustment if one was made, else the
    /// stored profile pace.
    public func effectiveTarget(for runType: RunType) -> Pace? {
        adjustments[runType] ?? profile.basePace(for: runType)
    }

    /// Nudges today's target by whole seconds per preferred unit.
    ///
    /// Seconds-per-unit rather than a percentage because that is how runners talk
    /// about it ("ten seconds slower today"), and because a percentage of an unset
    /// target is meaningless.
    public func adjustTarget(for runType: RunType, bySeconds delta: Double) {
        guard let base = effectiveTarget(for: runType) else { return }
        let perUnit = base.secondsPerMetre * profile.units.metresPerUnit + delta
        guard perUnit > 0 else { return }
        adjustments[runType] = Pace(secondsPerMetre: perUnit / profile.units.metresPerUnit)
    }

    public func resetAdjustment(for runType: RunType) {
        adjustments.removeValue(forKey: runType)
    }

    public func hasAdjustment(for runType: RunType) -> Bool {
        adjustments[runType] != nil
    }

    /// Builds the plan a run starts with.
    ///
    /// Structured types come from a preset (or from the phone's planned workout when it
    /// matches); the three continuous types come from `continuousRun`, which is what
    /// carries today's possibly-adjusted target into the engine without the profile
    /// having changed.
    public func plan(for runType: RunType) -> WorkoutPlan {
        if let plannedWorkout, plannedWorkout.runType == runType { return plannedWorkout }

        switch runType {
        case .vo2max:
            return WorkoutPresets.vo2Max4x1000()
        case .interval:
            return WorkoutPresets.intervals(reps: 4, workMetres: 800, recoveryMetres: 400)
        case .tempo, .easy, .long:
            return WorkoutPresets.continuousRun(runType: runType)
        }
    }

    /// The profile handed to `RunEngine` for this run: the stored profile with today's
    /// adjustment substituted in. The stored copy is untouched.
    public func runProfile(for runType: RunType) -> RunnerProfile {
        guard let adjusted = adjustments[runType] else { return profile }
        var copy = profile
        switch runType {
        case .tempo: copy.tempoPace = adjusted
        case .easy: copy.easyPace = adjusted
        case .long: copy.longPace = adjusted
        case .interval, .vo2max: break
        }
        return copy
    }

    /// `7:52 – 8:14` — the on-target window in the runner's own units.
    ///
    /// Bands are defined as *percentages of pace* (ADR-003), and a percentage is not
    /// something to show a runner mid-stride; the two clock times either side of the
    /// target are.
    private func bandText(around target: Pace, band: PaceBand) -> String {
        let fast = Pace(secondsPerMetre: target.secondsPerMetre * (1 - band.fastNear))
        let slow = Pace(secondsPerMetre: target.secondsPerMetre * (1 + band.slowNear))
        return ORFormat.pace(fast, in: profile.units) + " – " + ORFormat.pace(slow, in: profile.units)
    }
}
