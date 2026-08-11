import Foundation
import ORModels

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

    /// Attaches the run's path to the saved workout (T-107).
    ///
    /// Called after `endAndSave`, because a route can only be finished against a workout
    /// that exists. A default implementation does nothing, so a backend with no notion of
    /// location — or a test fake — is not forced to care.
    ///
    /// Both watch tiers requested `HKSeriesType.workoutRoute()` write permission from the
    /// day they were written and then never wrote one, so every run this app has ever saved
    /// to Health has been mapless while holding permission to do better.
    func saveRoute(_ route: [RoutePoint]) async throws
}

public extension WorkoutBackend {
    func saveRoute(_ route: [RoutePoint]) async throws {}
}

public enum WorkoutBackendError: Error, Equatable, Sendable {
    case sessionUnavailable
    case alreadyRunning
    case notRunning
}
