import Foundation
import ORPace

/// Lifecycle state of a workout session.
public enum WorkoutPhase: Sendable, Hashable {
    case idle
    case running
    case paused
    case ended
    /// The terminal denial state (AC-FR-D-1-7): the run happened, but nothing was
    /// written to Health because authorization was refused.
    case endedLocalOnly
    case failed
}

/// Orchestrates an `HKWorkoutSession`'s lifecycle against a `WorkoutBackend`
/// (T-033), tracking active time exactly the way `Core.RunEngine` does — via
/// `ActiveClock` — so pause/resume accounting can never disagree between the
/// session controller and the engine consuming its output (AC-FR-D-1-3).
///
/// `@MainActor`, not an `actor`, and the reason is tick ordering rather than
/// convenience.
///
/// Manual `NSLock`ing is out — Swift 6 correctly forbids holding a lock across the
/// `await`s this type needs to call `WorkoutBackend`. An `actor` would give
/// single-writer safety but only via `await`, which forces the 1 Hz `tick` to be
/// enqueued rather than executed in place; two ticks that then land out of order
/// silently *over-count* active time, because `ActiveClock` drops a negative delta
/// while still advancing its `lastTimestamp`, so the following interval is credited
/// twice. Sharing the main actor with `RunSessionModel` — which is where ticks
/// originate — makes `tick` an ordinary synchronous call that cannot reorder.
///
/// Pure orchestration otherwise: it holds no HealthKit type directly, only the
/// protocol, which is what makes it testable against a fake without a device.
@MainActor
public final class WorkoutSessionController {

    public private(set) var phase: WorkoutPhase = .idle
    public private(set) var savedWorkoutID: UUID?

    private let backend: WorkoutBackend
    private var clock = ActiveClock()
    private var deniedAuthorization = false

    public init(backend: WorkoutBackend) {
        self.backend = backend
    }

    /// Active (non-paused) elapsed seconds, as tracked independently of whatever
    /// HealthKit itself reports — this is the figure `RunEngine` receives.
    public var activeElapsed: TimeInterval { clock.activeElapsed }

    /// Requests authorization and starts the session.
    ///
    /// AC-FR-D-1-7: a denial does not stop the run. It moves the controller into
    /// a mode where `end()` will produce `.endedLocalOnly` instead of writing to
    /// Health — the run still records, HealthKit just never learns about it.
    public func start(locationType: WorkoutLocationType, now: TimeInterval) async throws {
        guard phase == .idle else { throw WorkoutBackendError.alreadyRunning }

        let outcome = await backend.requestAuthorization()

        if outcome == .authorized {
            try await backend.startSession(locationType: locationType)
        }
        // On denial, deliberately skip starting the HealthKit session — there is
        // nothing to write to, and attempting to start one anyway would either
        // throw or silently no-op depending on the OS, neither of which is worth
        // depending on.

        phase = .running
        clock.reset()
        clock.advance(to: now, paused: false)
        deniedAuthorization = (outcome == .denied)
    }

    /// Advances the internal clock. Called once per tick from the same 1 Hz loop
    /// that feeds `RunEngine`, so the two never drift relative to each other.
    public func tick(now: TimeInterval) {
        guard phase == .running || phase == .paused else { return }
        clock.advance(to: now, paused: phase == .paused)
    }

    public func pause(now: TimeInterval) async {
        guard phase == .running else { return }
        phase = .paused
        clock.advance(to: now, paused: true)
        await backend.pauseSession()
    }

    public func resume(now: TimeInterval) async {
        guard phase == .paused else { return }
        phase = .running
        clock.advance(to: now, paused: false)
        await backend.resumeSession()
    }

    /// Ends the session and saves. Idempotent past the first call — a second call
    /// after `.ended`/`.endedLocalOnly` is a no-op, not an error, since the UI's
    /// End button and a background-session-loss handler can both race to call it.
    @discardableResult
    public func end(now: TimeInterval) async throws -> WorkoutPhase {
        guard phase == .running || phase == .paused else { return phase }

        clock.advance(to: now, paused: phase == .paused)

        if deniedAuthorization {
            phase = .endedLocalOnly
            return .endedLocalOnly
        }

        do {
            let id = try await backend.endAndSave()
            savedWorkoutID = id
            phase = .ended
            return .ended
        } catch {
            phase = .failed
            throw error
        }
    }
}
