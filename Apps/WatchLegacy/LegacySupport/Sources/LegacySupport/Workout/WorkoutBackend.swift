import Foundation

/// What kind of location the workout is happening in — mirrors `HKWorkoutSessionLocationType`
/// without depending on HealthKit.
public enum WorkoutLocationType: Sendable, Hashable {
    case outdoor
    case indoor
    case unknown
}

/// Whether HealthKit authorization was granted, and what that means for this run.
public enum AuthorizationOutcome: Sendable, Hashable {
    case authorized
    /// AC-FR-D-1-7: the run still proceeds, recorded locally, with no HealthKit write. Denial is
    /// a normal handled state, not an error path.
    case denied
}

/// One interval boundary, as it will be written to the saved workout.
///
/// **This type is the Legacy tier's defining divergence** (design.md §8.1, AC-FR-D-1-6). The
/// Modern tier calls `HKWorkoutSession.beginNewActivity`, which is watchOS 9+ and gives HealthKit
/// first-class knowledge of each interval — Fitness and third-party apps then display the reps
/// natively. That API does not exist on watchOS 8, so this tier records
/// `HKWorkoutEvent(type: .segment)` per step instead.
///
/// The consequence is worth being precise about, because "equivalent" would be too strong: a
/// segment event is a *marker on a timeline*, not a nested activity, so a Legacy-recorded
/// workout carries the same boundaries with less structure around them. What matters for this
/// product is that the boundaries are present and correct — the per-rep table (AC-FR-F-2-6) is
/// built from the `RunEnvelope`'s `steps`, which both tiers populate identically from Core's
/// `StepSummaryAccumulator`, not from HealthKit. HealthKit segmentation is for *export* quality:
/// other apps reading the workout.
///
/// Times are `TimeInterval` on the run's own clock rather than `Date`, so this layer stays
/// testable without a device; the extension-target adapter converts to the `Date` pair
/// `HKWorkoutEvent` needs.
public struct WorkoutSegment: Sendable, Hashable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// The minimal surface `WorkoutSessionController` needs from HealthKit, abstracted so the
/// orchestration logic is testable without a device — Legacy tier (T-065).
///
/// A real conformer wraps `HKHealthStore` + `HKWorkoutSession` + `HKLiveWorkoutBuilder` and lives
/// in `Apps/WatchLegacy/Sources/Sensors/Workout`, where it can be written correctly against the
/// real framework but not exercised by XCTest. That gap is wider on this tier than on Modern:
/// HealthKit's session lifecycle needs a device or an interactively-authorized simulator, and
/// **there is no watchOS 8 simulator at all for Xcode 26** — so for Legacy the real conformer is
/// verifiable on Series 3 hardware and nowhere else. Everything above this protocol is
/// consequently held to a higher testing bar, because it is the only part a test can reach.
///
/// A deliberate duplicate of the Modern tier's protocol (AC-FR-K-1-4), differing only by
/// `recordSegment`.
public protocol WorkoutBackend: Sendable {
    func requestAuthorization() async -> AuthorizationOutcome
    func startSession(locationType: WorkoutLocationType) async throws
    func pauseSession() async
    func resumeSession() async

    /// Appends one `HKWorkoutEvent(type: .segment)` to the builder.
    ///
    /// Called once per completed step, including the step still open when the run ends — a
    /// missing final event means a silently worse export, with the last and often most
    /// interesting interval absent from the workout.
    func recordSegment(_ segment: WorkoutSegment) async

    /// Ends the session and saves the workout. Returns the saved workout's identifier, or `nil`
    /// when authorization was denied (AC-FR-D-1-7) — there is nothing to save in that case, and
    /// that is not a failure.
    func endAndSave() async throws -> UUID?
}

public enum WorkoutBackendError: Error, Equatable, Sendable {
    case sessionUnavailable
    case alreadyRunning
    case notRunning
}
