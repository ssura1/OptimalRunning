import Foundation
import ORPace

/// Lifecycle state of a workout session.
public enum WorkoutPhase: Sendable, Hashable {
    case idle
    case running
    case paused
    case ended
    /// The terminal denial state (AC-FR-D-1-7): the run happened, but nothing was written to
    /// Health because authorization was refused.
    case endedLocalOnly
    case failed
}

/// Orchestrates an `HKWorkoutSession`'s lifecycle against a `WorkoutBackend` — Legacy tier
/// (T-065), tracking active time via `ActiveClock` exactly the way `Core.RunEngine` does, so
/// pause/resume accounting cannot disagree between the session controller and the engine
/// consuming its output (AC-FR-D-1-3).
///
/// `@MainActor` rather than an `actor`, and the reason is tick ordering, not convenience. Swift 6
/// forbids holding a lock across the `await`s this type needs, and an `actor` would give
/// single-writer safety only via `await` — which forces the 1 Hz `tick` to be enqueued rather
/// than run in place. Two ticks landing out of order silently *over-count* active time, because
/// `ActiveClock` drops a negative delta while still advancing `lastTimestamp`, so the following
/// interval is credited twice. Sharing the main actor with the run model, where ticks originate,
/// makes `tick` an ordinary synchronous call that cannot reorder.
///
/// That reasoning was worked out for the Modern tier in Wave 2 and applies unchanged here, which
/// is why this is a duplicate rather than a fresh design (AC-FR-K-1-4). The genuine difference is
/// segmentation: see `markStepBoundary`.
@MainActor
public final class WorkoutSessionController {

    public private(set) var phase: WorkoutPhase = .idle
    public private(set) var savedWorkoutID: UUID?

    private let backend: WorkoutBackend
    private var clock = ActiveClock()
    private var deniedAuthorization = false

    /// Where the currently open segment began, on the run's clock. `nil` before the session
    /// starts and after it ends.
    private var openSegmentStart: TimeInterval?

    /// Segments handed to the backend, retained for assertion and diagnostics.
    public private(set) var recordedSegments: [WorkoutSegment] = []

    public init(backend: WorkoutBackend) {
        self.backend = backend
    }

    /// Active (non-paused) elapsed seconds, tracked independently of whatever HealthKit reports.
    public var activeElapsed: TimeInterval { clock.activeElapsed }

    public func start(locationType: WorkoutLocationType, now: TimeInterval) async throws {
        guard phase == .idle else { throw WorkoutBackendError.alreadyRunning }

        let outcome = await backend.requestAuthorization()

        if outcome == .authorized {
            try await backend.startSession(locationType: locationType)
        }
        // On denial, deliberately skip starting the HealthKit session — there is nothing to write
        // to, and starting one anyway would either throw or silently no-op depending on the OS.

        phase = .running
        clock.reset()
        clock.advance(to: now, paused: false)
        deniedAuthorization = (outcome == .denied)
        openSegmentStart = now
    }

    public func tick(now: TimeInterval) {
        guard phase == .running || phase == .paused else { return }
        clock.advance(to: now, paused: phase == .paused)
    }

    /// Closes the open segment at `now` and opens the next one — Legacy's substitute for
    /// `beginNewActivity` (AC-FR-D-1-6).
    ///
    /// Called once per step transition, from the same place the run model reads
    /// `EngineOutput.stepTransition`. The *engine* decides where boundaries fall; this method
    /// never re-derives them, which is what makes the recorded segments provably the same
    /// boundaries the Modern tier's activities use — both come from Core's `StepMachine`.
    ///
    /// A zero-length segment is skipped rather than recorded: two transitions on the same tick
    /// would otherwise write an event pair HealthKit displays as an empty interval.
    public func markStepBoundary(now: TimeInterval) async {
        guard phase == .running || phase == .paused else { return }
        guard let start = openSegmentStart else { return }

        if now > start {
            let segment = WorkoutSegment(start: start, end: now)
            recordedSegments.append(segment)
            await backend.recordSegment(segment)
        }
        openSegmentStart = now
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

    /// Ends the session and saves. Idempotent past the first call — a second call after
    /// `.ended`/`.endedLocalOnly` is a no-op, not an error, since the UI's End button and a
    /// background-session-loss handler can both race to call it.
    @discardableResult
    public func end(now: TimeInterval) async throws -> WorkoutPhase {
        guard phase == .running || phase == .paused else { return phase }

        clock.advance(to: now, paused: phase == .paused)

        // Close the step still open at the end. Without this the final interval never becomes a
        // segment event, which is the same class of omission `StepSummaryAccumulator.finish`
        // exists to prevent on the envelope side — and it is the *last* rep, so it is the one a
        // runner is most likely to go looking for.
        await markStepBoundary(now: now)
        openSegmentStart = nil

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
