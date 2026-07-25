import XCTest
@testable import WatchSupport

/// A fake `WorkoutBackend` — this is the "HealthKit protocol fake" T-033's
/// Done-when calls for. Records every call so tests can assert on ordering, not
/// just on outcomes.
actor FakeWorkoutBackend: WorkoutBackend {
    enum Call: Equatable { case authorize, start, pause, resume, endAndSave }

    private(set) var calls: [Call] = []
    var authorizationResult: AuthorizationOutcome = .authorized
    var endResult: Result<UUID?, Error> = .success(UUID())

    func requestAuthorization() async -> AuthorizationOutcome {
        calls.append(.authorize)
        return authorizationResult
    }

    func startSession(locationType: WorkoutLocationType) async throws {
        calls.append(.start)
    }

    func pauseSession() async {
        calls.append(.pause)
    }

    func resumeSession() async {
        calls.append(.resume)
    }

    func endAndSave() async throws -> UUID? {
        calls.append(.endAndSave)
        return try endResult.get()
    }
}

struct FakeError: Error {}

/// `@MainActor` because `WorkoutSessionController` is: it shares the run loop's actor
/// so that `tick` cannot reorder relative to the engine's own clock. The tests inherit
/// that isolation rather than working around it, which is also what the app does.
@MainActor
final class WorkoutSessionControllerTests: XCTestCase {

    func testStartMovesToRunningAndCallsAuthorizeAndStart() async throws {
        let backend = FakeWorkoutBackend()
        let controller = WorkoutSessionController(backend: backend)

        try await controller.start(locationType: .outdoor, now: 0)

        let phase = await controller.phase
        XCTAssertEqual(phase, .running)
        let calls = await backend.calls
        XCTAssertEqual(calls, [.authorize, .start])
    }

    func testDeniedAuthorizationSkipsSessionStartButStillRuns() async throws {
        let backend = FakeWorkoutBackend()
        await backend.setAuthorizationResult(.denied)
        let controller = WorkoutSessionController(backend: backend)

        try await controller.start(locationType: .outdoor, now: 0)

        let phase = await controller.phase
        XCTAssertEqual(phase, .running, "a denial must not stop the run — AC-FR-D-1-7")
        let calls = await backend.calls
        XCTAssertEqual(calls, [.authorize], "must not attempt to start a session with no authorization")
    }

    func testEndAfterDenialProducesEndedLocalOnlyWithoutCallingSave() async throws {
        let backend = FakeWorkoutBackend()
        await backend.setAuthorizationResult(.denied)
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        let result = try await controller.end(now: 60)

        XCTAssertEqual(result, .endedLocalOnly)
        let phase = await controller.phase
        XCTAssertEqual(phase, .endedLocalOnly)
        let calls = await backend.calls
        XCTAssertFalse(calls.contains(.endAndSave), "denied runs never call the save path")
    }

    func testEndAfterAuthorizationSavesAndCapturesTheWorkoutID() async throws {
        let backend = FakeWorkoutBackend()
        let expectedID = UUID()
        await backend.setEndResult(.success(expectedID))
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        let result = try await controller.end(now: 60)

        XCTAssertEqual(result, .ended)
        let savedID = await controller.savedWorkoutID
        XCTAssertEqual(savedID, expectedID)
    }

    func testPauseAndResumeProduceCorrectActiveTime() async throws {
        let backend = FakeWorkoutBackend()
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        for t in stride(from: 1.0, through: 100.0, by: 1.0) { await controller.tick(now: t) }
        await controller.pause(now: 100)
        for t in stride(from: 101.0, through: 200.0, by: 1.0) { await controller.tick(now: t) }
        await controller.resume(now: 200)
        for t in stride(from: 201.0, through: 300.0, by: 1.0) { await controller.tick(now: t) }

        // 100 s running, then 100 s paused (excluded), then 100 s running again.
        let active = await controller.activeElapsed
        XCTAssertEqual(active, 200, accuracy: 1.0)

        let calls = await backend.calls
        XCTAssertEqual(calls, [.authorize, .start, .pause, .resume])
    }

    func testEndIsIdempotent() async throws {
        let backend = FakeWorkoutBackend()
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        _ = try await controller.end(now: 60)
        let secondResult = try await controller.end(now: 61)

        XCTAssertEqual(secondResult, .ended)
        let calls = await backend.calls
        XCTAssertEqual(calls.filter { $0 == .endAndSave }.count, 1, "save must only be called once")
    }

    func testSecondStartWhileRunningThrows() async throws {
        let backend = FakeWorkoutBackend()
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        do {
            try await controller.start(locationType: .outdoor, now: 1)
            XCTFail("expected alreadyRunning")
        } catch let error as WorkoutBackendError {
            XCTAssertEqual(error, .alreadyRunning)
        }
    }

    func testSaveFailureMovesToFailedAndPropagatesTheError() async throws {
        let backend = FakeWorkoutBackend()
        await backend.setEndResult(.failure(FakeError()))
        let controller = WorkoutSessionController(backend: backend)
        try await controller.start(locationType: .outdoor, now: 0)

        do {
            _ = try await controller.end(now: 60)
            XCTFail("expected the fake error to propagate")
        } catch is FakeError {
            let phase = await controller.phase
            XCTAssertEqual(phase, .failed)
        }
    }
}

extension FakeWorkoutBackend {
    func setAuthorizationResult(_ outcome: AuthorizationOutcome) {
        authorizationResult = outcome
    }
    func setEndResult(_ result: Result<UUID?, Error>) {
        endResult = result
    }
}
