import Foundation

/// What kind of location the workout is happening in — mirrors
/// `HKWorkoutSessionLocationType` without depending on HealthKit.
public enum WorkoutLocationType: Sendable, Hashable {
    case outdoor
    case indoor
    case unknown
}

/// Whether HealthKit authorization was granted, and what that means for this run.
public enum AuthorizationOutcome: Sendable, Hashable {
    case authorized
    /// AC-FR-D-1-7: the run still proceeds, recorded locally, with no HealthKit
    /// write. Denial is a normal, handled state — not an error path.
    case denied
}

/// The minimal surface `WorkoutSessionController` needs from HealthKit, abstracted
/// so the orchestration logic (T-033) is testable without a device (design.md
/// §16.1's "Integration... against fakes" layer, made concrete).
///
/// A real conformer wraps `HKHealthStore` + `HKWorkoutSession` +
/// `HKLiveWorkoutBuilder` and lives in `Apps/WatchModern/Sources/Sensors/Workout`,
/// where it can be written correctly against the real framework but not exercised
/// by XCTest — HealthKit's workout session lifecycle needs a device or an
/// interactively-authorized simulator, neither available in CI.
public protocol WorkoutBackend: Sendable {
    func requestAuthorization() async -> AuthorizationOutcome
    func startSession(locationType: WorkoutLocationType) async throws
    func pauseSession() async
    func resumeSession() async
    /// Ends the session and saves the workout. Returns the saved workout's
    /// identifier, or `nil` when authorization was denied (AC-FR-D-1-7) — there is
    /// nothing to save to Health in that case, and that is not a failure.
    func endAndSave() async throws -> UUID?
}

public enum WorkoutBackendError: Error, Equatable, Sendable {
    case sessionUnavailable
    case alreadyRunning
    case notRunning
}
