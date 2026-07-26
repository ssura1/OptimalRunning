import XCTest
import ORIntervals
import ORModels
import ORPace
@testable import LegacySupport

/// Interval boundaries reach the saved workout as `HKWorkoutEvent(.segment)` (T-065, AC-FR-D-1-6).
///
/// This is the Legacy tier's substitute for Modern's `HKWorkoutSession.beginNewActivity`, and a
/// missing event here means a silently worse export: the run still records correctly in the app,
/// while the workout other apps read has lost its rep structure. Nothing on the watch would look
/// wrong.
///
/// The boundaries are asserted against **the committed engine golden's transition list** rather than
/// against a count this test invents. That is what makes it a tier-equivalence assertion and not
/// just a self-consistency one: the golden is the same file `Core` and the Modern tier assert
/// against, so "Legacy's segments land on the golden's transitions" transitively means they land
/// where Modern's native activities do.
final class SegmentEventTests: XCTestCase {

    /// Records what a real `HKLiveWorkoutBuilder` would be told.
    private final class RecordingBackend: WorkoutBackend, @unchecked Sendable {
        var segments: [WorkoutSegment] = []
        var didStart = false
        var didSave = false
        let authorization: AuthorizationOutcome

        init(authorization: AuthorizationOutcome = .authorized) {
            self.authorization = authorization
        }

        func requestAuthorization() async -> AuthorizationOutcome { authorization }
        func startSession(locationType: WorkoutLocationType) async throws { didStart = true }
        func pauseSession() async {}
        func resumeSession() async {}
        func recordSegment(_ segment: WorkoutSegment) async { segments.append(segment) }
        func endAndSave() async throws -> UUID? {
            didSave = true
            return authorization == .authorized ? UUID() : nil
        }
    }

    private final class SilentHaptics: HapticPlaying {
        var played: [HapticPattern] = []
        func play(_ pattern: HapticPattern) { played.append(pattern) }
    }

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-segments-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Drives the committed interval fixture through the real controller and store.
    @MainActor
    private func runFixture(
        named name: String,
        backend: RecordingBackend
    ) throws -> (model: RunSessionModel, golden: EngineGolden) {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: name))
        let replay = FixtureReplay.run(fixture)
        let golden = try FixtureLocating.loadGolden(named: name)

        let model = RunSessionModel(
            store: SampleStore(directory: scratchDirectory()),
            session: WorkoutSessionController(backend: backend),
            haptics: SilentHaptics()
        )

        let plan = try XCTUnwrap(fixture.plan)
        let expectation = XCTestExpectation(description: "run completes")

        Task { @MainActor in
            try await model.start(
                plan: plan, profile: fixture.profile, activity: .outdoorRun, now: 0
            )
            for output in replay.outputs {
                model.record(output, plan: plan, profile: fixture.profile)
                // The controller marks boundaries in a detached Task, so yield to let them land
                // before the next tick. Real ticks are a second apart; this is what stands in for
                // that gap in a test that runs in milliseconds.
                await Task.yield()
            }
            _ = try await model.end(now: replay.outputs.last?.sample.timestamp ?? 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 30)
        return (model, golden)
    }

    // MARK: - The assertion

    /// One segment per completed step, with the final open step closed out.
    ///
    /// A 4×1000 m session resolves to warmup + (work + recovery) × 4 + cooldown = 10 steps, so the
    /// golden records 9 transitions and there must be 10 segments: one per transition, plus the
    /// cooldown that was still running when the workout ended.
    @MainActor
    func testEveryStepBoundaryBecomesASegmentIncludingTheFinalOpenStep() throws {
        let backend = RecordingBackend()
        let (model, golden) = try runFixture(named: "intervals-4x1000", backend: backend)

        XCTAssertEqual(
            backend.segments.count, golden.transitions.count + 1,
            """
            recorded \(backend.segments.count) segments for \(golden.transitions.count) golden \
            transitions — the export has lost rep structure. The +1 is the step still open when the \
            run ended, which is the last rep and the one a runner most wants to see.
            """
        )
        XCTAssertEqual(backend.segments, model.recordedSegments)
        XCTAssertTrue(backend.didSave)
    }

    /// Segment boundaries land on the ticks the engine golden records as transitions.
    ///
    /// The substantive claim. A count alone would pass if all ten segments were one second long.
    @MainActor
    func testSegmentBoundariesLandOnTheGoldensTransitionTimes() throws {
        let backend = RecordingBackend()
        let (_, golden) = try runFixture(named: "intervals-4x1000", backend: backend)

        // Each golden transition's `atActiveElapsed` should be the end of one recorded segment.
        let segmentEnds = Set(backend.segments.map(\.end))
        for transition in golden.transitions {
            XCTAssertTrue(
                segmentEnds.contains(transition.atSeconds),
                """
                no segment ends at \(transition.atSeconds), where the golden records a step \
                transition — the exported boundaries disagree with the engine's
                """
            )
        }
    }

    /// Segments tile the run without gaps or overlaps.
    ///
    /// A segment list that skipped time, or double-counted it, would still satisfy the count and
    /// boundary checks above while exporting an incoherent timeline.
    @MainActor
    func testSegmentsTileTheRunContiguously() throws {
        let backend = RecordingBackend()
        _ = try runFixture(named: "intervals-4x1000", backend: backend)

        var previousEnd: TimeInterval?
        for segment in backend.segments {
            XCTAssertGreaterThan(segment.end, segment.start, "a zero or negative-length segment")
            if let previousEnd {
                XCTAssertEqual(
                    segment.start, previousEnd, accuracy: 1e-9,
                    "segment starting at \(segment.start) does not continue from \(previousEnd)"
                )
            }
            previousEnd = segment.end
        }
    }

    /// An unstructured run produces exactly one segment — the whole run — not zero and not many.
    @MainActor
    func testAContinuousRunProducesASingleWholeRunSegment() throws {
        let backend = RecordingBackend()
        _ = try runFixture(named: "tempo-5mi-rolling", backend: backend)

        XCTAssertEqual(
            backend.segments.count, 1,
            "a continuous run should export one segment covering the run"
        )
    }

    /// With HealthKit authorization denied, the run still records locally and nothing is saved
    /// (AC-FR-D-1-7) — segments included, since there is no workout to attach them to.
    @MainActor
    func testDeniedAuthorizationStillRecordsLocallyAndSavesNothing() throws {
        let backend = RecordingBackend(authorization: .denied)
        let (model, _) = try runFixture(named: "intervals-4x1000", backend: backend)

        XCTAssertFalse(backend.didStart, "a session was started despite denial")
        XCTAssertNil(model.savedWorkoutID, "a workout ID appeared despite denial")
        // The samples are still captured — denial degrades the export, never the run.
        XCTAssertGreaterThan(model.capturedSamples.count, 1_000)
    }
}
