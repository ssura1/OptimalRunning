import XCTest
import ORAlerts
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// **A completed run's data can never be destroyed before it is durably held** (T-106).
///
/// This is the structural half of the sync fix. The bug it exists to prevent was not a
/// crash, a wrong number, or anything a user could report — it was `finalizeRun()` deleting
/// the only file the run ever wrote, on the *happy* path, with no error anywhere. A run that
/// ended cleanly erased itself, and a run that crashed was the only kind that survived.
///
/// The property asserted here is deliberately weaker than "sync worked" and much stronger
/// than "the code looks right": after `end()`, the run is in the sink **or** still on disk,
/// and never in neither. That holds whether the phone is reachable, unreachable, or the
/// hand-off fails outright — none of which the watch can control.
@MainActor
final class RunDurabilityTests: XCTestCase {

    /// A sink that can be made to fail, because the ordering exists for the failing case.
    private final class SpySink: FinishedRunSink {
        private(set) var accepted: [RunEnvelope] = []
        var failure: Error?

        func accept(_ envelope: RunEnvelope) throws {
            if let failure { throw failure }
            accepted.append(envelope)
        }
    }

    private struct Failure: Error {}

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunDurabilityTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Harness {
        let model: RunSessionModel
        let feed: FakeSensorFeed
        let store: SampleStore
        let sink: SpySink
        let directory: URL
    }

    private func makeHarness(sink: SpySink? = nil) -> Harness {
        let directory = scratch()
        let feed = FakeSensorFeed()
        let store = SampleStore(directory: directory)
        let spy = sink ?? SpySink()
        let model = RunSessionModel(
            plan: WorkoutPresets.continuousRun(runType: .easy),
            profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
            feed: feed,
            store: store,
            session: WorkoutSessionController(backend: FakeWorkoutBackend()),
            haptics: RecordingHaptics(),
            sink: spy
        )
        return Harness(model: model, feed: feed, store: store, sink: spy, directory: directory)
    }

    private func run(_ harness: Harness, seconds: Int = 120) {
        for second in 0..<seconds {
            harness.feed.emit(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: Double(second) * 3.35,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5 + Double(second) * 1e-5,
                    longitude: -0.12, altitudeMetres: 10,
                    horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0, heartRate: 150, distanceSource: .healthKit
            ))
        }
    }

    /// Files the store is holding for this run, by extension. `.inprogress` means "an
    /// orphan on next launch"; `.completed` means "finished but not yet handed over".
    private func storedFiles(_ harness: Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path)) ?? [])
            .filter { $0.hasSuffix(".inprogress") || $0.hasSuffix(".completed") }
    }

    // MARK: - The property

    /// The whole point, stated as one assertion over both outcomes.
    func testAFinishedRunIsEitherHandedOverOrStillOnDisk() async throws {
        for shouldFail in [false, true] {
            let harness = makeHarness()
            harness.sink.failure = shouldFail ? Failure() : nil

            try await harness.model.start(activity: .outdoorRun)
            run(harness)
            _ = try await harness.model.end()

            let handedOver = !harness.sink.accepted.isEmpty
            let onDisk = !storedFiles(harness).isEmpty

            XCTAssertTrue(
                handedOver || onDisk,
                "a completed run is in neither the sink nor on disk — it is gone "
                    + "(hand-off failing: \(shouldFail))")
        }
    }

    /// The happy path: handed over, and only then released.
    func testACleanlyFinishedRunReachesTheSinkAndIsThenReleased() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness)
        _ = try await harness.model.end()

        XCTAssertEqual(harness.sink.accepted.count, 1, "the run never reached the sink")
        XCTAssertEqual(
            storedFiles(harness), [],
            "samples were retained after a successful hand-off, so they would accumulate")
    }

    /// The failing path — the one the ordering exists for. Nothing is deleted.
    func testAFailedHandOverKeepsTheSamples() async throws {
        let harness = makeHarness()
        harness.sink.failure = Failure()

        try await harness.model.start(activity: .outdoorRun)
        run(harness)
        _ = try await harness.model.end()

        XCTAssertTrue(harness.sink.accepted.isEmpty)
        XCTAssertEqual(
            storedFiles(harness).count, 1,
            "the hand-off failed and the samples were deleted anyway — the run is lost")
    }

    /// A run with nowhere to go keeps its samples rather than discarding them.
    func testWithNoSinkTheRunIsRetainedRatherThanDropped() async throws {
        let directory = scratch()
        let feed = FakeSensorFeed()
        let store = SampleStore(directory: directory)
        let model = RunSessionModel(
            plan: WorkoutPresets.continuousRun(runType: .easy),
            profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
            feed: feed, store: store,
            session: WorkoutSessionController(backend: FakeWorkoutBackend()),
            haptics: RecordingHaptics()
        )

        try await model.start(activity: .outdoorRun)
        for second in 0..<60 {
            feed.emit(EngineInput(
                timestamp: Double(second), cumulativeDistance: Double(second) * 3.35,
                location: nil, relativeAltitude: nil, heartRate: nil, distanceSource: .pedometer
            ))
        }
        _ = try await model.end()

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".completed") }
        XCTAssertEqual(files.count, 1, "a run with no sink was discarded")
    }

    /// A finished run stops being an orphan, so the next launch does not offer to recover a
    /// run that already synced. The samples surviving must not cost a false recovery prompt.
    func testAFinishedRunIsNoLongerAnOrphan() async throws {
        let harness = makeHarness()
        harness.sink.failure = Failure()   // retained on disk, the harder case

        try await harness.model.start(activity: .outdoorRun)
        run(harness)
        _ = try await harness.model.end()

        let relaunched = SampleStore(directory: harness.directory)
        XCTAssertNil(
            relaunched.detectOrphan(),
            "a cleanly finished run is being offered for crash recovery")
    }

    // MARK: - What actually reached the sink

    /// The envelope is not an empty shell: it carries the run's samples, its totals and its
    /// path. A hand-off that delivered a well-formed envelope with no data in it would pass
    /// every assertion above.
    func testTheEnvelopeCarriesTheRunRatherThanJustItsIdentity() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)
        run(harness, seconds: 300)
        _ = try await harness.model.end()

        let envelope = try XCTUnwrap(harness.sink.accepted.first)
        XCTAssertEqual(envelope.runType, .easy)
        XCTAssertGreaterThan(envelope.summary.distanceMetres, 900, "no distance recorded")
        XCTAssertGreaterThan(envelope.summary.activeSeconds, 250)
        XCTAssertGreaterThan(envelope.samples.count, 250, "the sample blob is empty")
        XCTAssertNotNil(envelope.route, "no route — the phone will draw no map")
        XCTAssertGreaterThan(envelope.route?.count ?? 0, 250)
        XCTAssertFalse(envelope.zoneTimeline.isEmpty, "no zone timeline")
    }

    /// An indoor run has no fixes, and its route must be `nil` rather than an empty array —
    /// otherwise the phone renders a map of nothing (AC-FR-F-2-7).
    func testAnIndoorRunCarriesNoRoute() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .indoorRun)
        for second in 0..<60 {
            harness.feed.emit(EngineInput(
                timestamp: Double(second), cumulativeDistance: Double(second) * 3.0,
                location: nil, relativeAltitude: nil, heartRate: 150,
                distanceSource: .pedometer
            ))
        }
        _ = try await harness.model.end()

        let envelope = try XCTUnwrap(harness.sink.accepted.first)
        XCTAssertNil(envelope.route)
    }

    // MARK: - End to end, through the real queue

    /// The real `SyncCoordinator` over the real `PendingPayloadQueue`, with the phone
    /// unreachable — the ordinary case of finishing a run with the phone indoors.
    ///
    /// Proves the durability claim is a property of the shipping sink and not only of the
    /// spy: the payload is on disk before any transfer is attempted, and stays pending.
    func testAgainstTheRealQueueWithThePhoneUnreachable() async throws {
        let directory = scratch()
        let queue = PendingPayloadQueue(directory: directory.appendingPathComponent("outbox"))
        let transport = FakeFileTransport()
        transport.isReachable = false
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let store = SampleStore(directory: directory)
        let feed = FakeSensorFeed()
        let model = RunSessionModel(
            plan: WorkoutPresets.continuousRun(runType: .easy),
            profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
            feed: feed, store: store,
            session: WorkoutSessionController(backend: FakeWorkoutBackend()),
            haptics: RecordingHaptics(),
            sink: coordinator
        )

        try await model.start(activity: .outdoorRun)
        for second in 0..<120 {
            feed.emit(EngineInput(
                timestamp: Double(second), cumulativeDistance: Double(second) * 3.35,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5, longitude: -0.12,
                    altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0, heartRate: 150, distanceSource: .healthKit
            ))
        }
        _ = try await model.end()

        XCTAssertEqual(queue.pending.count, 1, "the run was not durably queued")
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertTrue(transport.transferred.isEmpty, "transferred while unreachable")

        // And when the phone comes back, it goes — without the run having been re-recorded.
        transport.isReachable = true
        coordinator.reachabilityChanged()
        XCTAssertEqual(transport.transferred.count, 1)
    }
}

/// A transport whose reachability the test controls, since that is the condition the
/// Simulator cannot reproduce.
@MainActor
final class FakeFileTransport: FileTransporting {
    var isReachable = true
    private(set) var transferred: [URL] = []
    var failure: Error?

    func transfer(fileAt url: URL, metadata: [String: String]) throws {
        if let failure { throw failure }
        transferred.append(url)
    }
}
