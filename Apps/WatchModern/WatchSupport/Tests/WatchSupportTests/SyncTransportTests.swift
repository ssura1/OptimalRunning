import XCTest
import ORModels
import ORPace
@testable import WatchSupport

/// A transport whose reachability the test controls.
///
/// The reason this exists rather than a real `WCSession`: the Simulator does not reliably
/// reproduce reachability *transitions* between a paired watch and phone, so a test driven
/// through the real session would pass while proving nothing about AC-FR-E-1-1/E-1-2 — the
/// one behaviour that actually matters here. Reachability is a value this fake sets.
@MainActor
final class FakeTransport: FileTransporting {
    var isReachable = false
    /// Set to make the hand-off fail, standing in for the system refusing a transfer.
    var shouldFailTransfer = false

    private(set) var transferred: [(url: URL, metadata: [String: String])] = []

    func transfer(fileAt url: URL, metadata: [String: String]) throws {
        if shouldFailTransfer { throw CocoaError(.fileNoSuchFile) }
        transferred.append((url, metadata))
    }

    var transferredRunIDs: [UUID] {
        transferred.compactMap { UUID(uuidString: $0.metadata[SyncFileMetadata.runIDKey] ?? "") }
    }
}

@MainActor
final class SyncTransportTests: XCTestCase {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncTransportTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(_ bytes: Int = 1_024) -> Data {
        Data(repeating: 0xAB, count: bytes)
    }

    /// Writes an exact queue state to disk, bypassing `enqueue`.
    ///
    /// Necessary because `enqueue` enforces the budget as it goes: seeding an over-budget
    /// population through it would evict during setup, so the state the test means to
    /// examine would never exist — which is how the first version of these tests passed
    /// for the wrong reason. Reloading over a hand-written index is also the realistic path
    /// to an acknowledged-but-undeleted payload: that is what a crash between "mark
    /// acknowledged" and "delete the file" leaves behind.
    private func seed(_ directory: URL, _ entries: [PendingPayload]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            try payload(entry.byteCount).write(
                to: directory.appendingPathComponent("\(entry.runID.uuidString).envelope.gz"),
                options: .atomic
            )
        }
        try JSONEncoder().encode(entries).write(
            to: directory.appendingPathComponent("queue-index.json"), options: .atomic
        )
    }

    private func entry(
        _ runID: UUID, _ offsetSeconds: Double, _ state: PayloadState, bytes: Int = 1_024
    ) -> PendingPayload {
        PendingPayload(
            runID: runID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds),
            byteCount: bytes,
            state: state
        )
    }

    /// A real envelope, built from a real recorded fixture rather than hand-assembled.
    private func envelope(named fixture: String = "tempo-5mi-rolling", runID: UUID = UUID()) throws -> RunEnvelope {
        let source = try XCTUnwrap(FixtureGenerator.fixture(named: fixture))
        let replay = FixtureReplay.run(source)
        return RunEnvelopeBuilder.build(
            runID: runID,
            outputs: replay.outputs,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            runType: source.runType,
            plan: source.plan,
            profile: source.profile,
            appVersion: "1.0-test"
        )
    }

    // MARK: - Payload codec

    /// The codec is the narrowest place a silent corruption could hide: it sits between
    /// two packages that never see each other's code, and a framing mistake would surface
    /// as "some runs never arrive" rather than as a crash.
    func testAnEnvelopeSurvivesCompressionAndDecompressionExactly() throws {
        let original = try envelope()
        let restored = try SyncPayloadCodec.decode(SyncPayloadCodec.encode(original))
        XCTAssertEqual(restored, original)
    }

    func testCompressionActuallyShrinksARealEnvelope() throws {
        let json = try RunEnvelopeCoder.encode(envelope())
        let compressed = try SyncPayloadCodec.compress(json)

        XCTAssertLessThan(
            compressed.count, json.count,
            "compression made the payload larger, which means the format is wrong"
        )
        XCTAssertEqual(try SyncPayloadCodec.decompress(compressed), json)
    }

    /// Large payloads are the case a fixed-size output buffer gets wrong, so the codec is
    /// exercised well past one buffer's worth.
    func testTheCodecHandlesPayloadsLargerThanItsInternalBuffer() throws {
        // Deliberately incompressible, so the compressed form is also multi-buffer.
        var generator = SystemRandomNumberGenerator()
        let noisy = Data((0..<(512 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })

        let restored = try SyncPayloadCodec.decompress(SyncPayloadCodec.compress(noisy))
        XCTAssertEqual(restored, noisy)
    }

    /// Truncation is what a dropped transfer looks like. It must be an error, never a
    /// partial decode that produces a run with missing samples.
    func testATruncatedPayloadIsRejectedRatherThanPartiallyDecoded() throws {
        let compressed = try SyncPayloadCodec.encode(envelope())
        let truncated = compressed.prefix(compressed.count / 2)

        XCTAssertThrowsError(try SyncPayloadCodec.decode(Data(truncated))) { error in
            guard case EnvelopeError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - AC-FR-E-1-1 / E-1-2: enqueue offline, transfer on reconnect

    func testARunEnqueuesWhileUnreachableAndTransfersOnReconnect() throws {
        let transport = FakeTransport()
        transport.isReachable = false
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let runID = UUID()
        try coordinator.enqueue(try envelope(runID: runID))

        // Enqueued and durable, but nothing handed over.
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertTrue(transport.transferred.isEmpty, "transferred while unreachable")
        XCTAssertNotNil(queue.data(for: runID), "the payload was not written to disk")

        // The phone comes back.
        transport.isReachable = true
        coordinator.reachabilityChanged()

        XCTAssertEqual(transport.transferredRunIDs, [runID])
        XCTAssertEqual(
            queue.payload(for: runID)?.state, .pending,
            "a transferred payload must stay pending until the phone acknowledges it"
        )
    }

    /// AC-FR-E-1-2 — the payload survives until acknowledged, not until transferred.
    func testAPayloadIsRetainedUntilAcknowledgedAndDeletedOnAck() throws {
        let transport = FakeTransport()
        transport.isReachable = true
        let directory = scratch()
        let queue = PendingPayloadQueue(directory: directory)
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let runID = UUID()
        try coordinator.enqueue(try envelope(runID: runID))
        XCTAssertNotNil(queue.data(for: runID))

        coordinator.apply(PhoneContext(
            sequence: 1, acknowledgement: SyncAcknowledgement(acked: [runID])
        ))

        XCTAssertNil(queue.payload(for: runID), "the entry outlived its acknowledgement")
        XCTAssertNil(queue.data(for: runID), "the bytes outlived their acknowledgement")
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    /// DEG-7 — days of unreachability queue up and all flush together.
    func testManyRunsQueueWhileUnreachableAndAllFlushOnReconnect() throws {
        let transport = FakeTransport()
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        var ids: [UUID] = []
        for day in 0..<8 {
            let runID = UUID()
            ids.append(runID)
            try queue.enqueue(
                runID: runID, payload: payload(),
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
            )
        }

        transport.isReachable = true
        coordinator.reachabilityChanged()

        XCTAssertEqual(Set(transport.transferredRunIDs), Set(ids))
        // Oldest first, so the earliest run is not starved behind newer ones.
        XCTAssertEqual(transport.transferredRunIDs, ids)
    }

    func testAFailedHandOffLeavesThePayloadPendingForTheNextReconnect() throws {
        let transport = FakeTransport()
        transport.isReachable = true
        transport.shouldFailTransfer = true
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let runID = UUID()
        try coordinator.enqueue(try envelope(runID: runID))
        XCTAssertEqual(queue.payload(for: runID)?.state, .pending)

        transport.shouldFailTransfer = false
        coordinator.reachabilityChanged()
        XCTAssertEqual(transport.transferredRunIDs, [runID])
    }

    // MARK: - Relaunch

    /// The watch reboots, or the system kills the app. Both happen; neither may lose a run.
    func testTheQueueSurvivesRelaunchWithStateIntact() throws {
        let directory = scratch()
        let acked = UUID()
        let pending = UUID()

        do {
            let queue = PendingPayloadQueue(directory: directory)
            try queue.enqueue(runID: acked, payload: payload(2_048))
            try queue.enqueue(runID: pending, payload: payload(4_096))
            queue.apply(SyncAcknowledgement(acked: [acked]))
        }

        // A brand-new instance over the same directory is what a relaunch looks like.
        let relaunched = PendingPayloadQueue(directory: directory)

        XCTAssertNil(relaunched.payload(for: acked), "an acknowledged run came back from the dead")
        let survivor = try XCTUnwrap(relaunched.payload(for: pending))
        XCTAssertEqual(survivor.state, .pending)
        XCTAssertEqual(survivor.byteCount, 4_096)
        XCTAssertNotNil(relaunched.data(for: pending), "the bytes did not survive relaunch")
    }

    /// A crash between writing the payload and updating the index. The file is adopted
    /// rather than orphaned — losing a recorded run to a bookkeeping gap would be the worst
    /// possible trade, and re-sending one the phone already has is free because ingest is
    /// idempotent.
    func testAPayloadFileWithNoIndexEntryIsAdoptedRatherThanLost() throws {
        let directory = scratch()
        let orphan = UUID()

        do {
            let queue = PendingPayloadQueue(directory: directory)
            try queue.enqueue(runID: orphan, payload: payload())
            // Simulate the index write never happening.
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent("queue-index.json")
            )
        }

        let relaunched = PendingPayloadQueue(directory: directory)
        let adopted = try XCTUnwrap(relaunched.payload(for: orphan))
        XCTAssertEqual(adopted.state, .pending)
        XCTAssertEqual(relaunched.pending.map(\.runID), [orphan])
    }

    /// The mirror case: an index entry whose file vanished must not be reported as pending,
    /// or the coordinator would hand a nonexistent path to the transport every reconnect.
    func testAnIndexEntryWithNoFileIsDropped() throws {
        let directory = scratch()
        let ghost = UUID()

        do {
            let queue = PendingPayloadQueue(directory: directory)
            try queue.enqueue(runID: ghost, payload: payload())
            try FileManager.default.removeItem(at: queue.fileURL(for: ghost))
        }

        let relaunched = PendingPayloadQueue(directory: directory)
        XCTAssertNil(relaunched.payload(for: ghost))
        XCTAssertTrue(relaunched.pending.isEmpty)
    }

    // MARK: - AC-FR-E-1-5: eviction

    /// The rule the requirement actually states, and the one a FIFO-by-age policy breaks.
    ///
    /// The acknowledged payload is the **newest** by age, so any age-ordered policy evicts
    /// the older unacknowledged runs first — destroying runs that exist nowhere else while
    /// keeping bytes the phone already has.
    func testEvictionNeverDropsAnUnacknowledgedPayloadInFavourOfAnAcknowledgedOne() throws {
        var configuration = SyncConfiguration()
        configuration.maxPendingRuns = 3

        let directory = scratch()
        let oldest = UUID(), middle = UUID(), newer = UUID(), newestAcked = UUID()
        try seed(directory, [
            entry(oldest, 0, .pending),
            entry(middle, 60, .pending),
            entry(newer, 120, .pending),
            entry(newestAcked, 180, .acknowledged),
        ])

        let queue = PendingPayloadQueue(directory: directory, configuration: configuration)
        XCTAssertTrue(queue.isOverBudget, "the test did not reach the state it meant to")

        XCTAssertEqual(
            queue.evictIfNeeded(), [newestAcked],
            "eviction did not prefer the acknowledged payload"
        )
        for survivor in [oldest, middle, newer] {
            XCTAssertNotNil(
                queue.payload(for: survivor),
                "an unacknowledged run was evicted while an acknowledged one existed"
            )
        }
    }

    /// With a mixed population well over budget, *every* acknowledged and rejected payload
    /// goes before any pending one is touched.
    func testAllAcknowledgedAndRejectedPayloadsGoBeforeAnyPendingOne() throws {
        var configuration = SyncConfiguration()
        configuration.maxPendingRuns = 3

        let directory = scratch()
        let pendingOld = UUID(), pendingNew = UUID(), pendingNewest = UUID()
        let ackedNew = UUID(), ackedNewer = UUID(), rejectedNewest = UUID()

        // Every disposable payload is *newer* than every pending one, so age ordering
        // would get this exactly backwards.
        try seed(directory, [
            entry(pendingOld, 0, .pending),
            entry(pendingNew, 60, .pending),
            entry(pendingNewest, 120, .pending),
            entry(ackedNew, 180, .acknowledged),
            entry(ackedNewer, 240, .acknowledged),
            entry(rejectedNewest, 300, .rejected),
        ])

        let queue = PendingPayloadQueue(directory: directory, configuration: configuration)
        let evicted = queue.evictIfNeeded()

        XCTAssertEqual(
            Set(evicted), Set([ackedNew, ackedNewer, rejectedNewest]),
            "eviction did not clear the disposable payloads first"
        )
        // Acknowledged before rejected, and oldest first within each rank.
        XCTAssertEqual(evicted, [ackedNew, ackedNewer, rejectedNewest])
        for survivor in [pendingOld, pendingNew, pendingNewest] {
            XCTAssertNotNil(queue.payload(for: survivor), "a deliverable run was evicted")
        }
        XCTAssertFalse(queue.isOverBudget)
    }

    /// A rejected run sorts before a pending one: the phone will never accept it, so keeping
    /// it while dropping a deliverable run would trade recoverable data for unrecoverable.
    func testARejectedPayloadIsEvictedBeforeAPendingOne() throws {
        var configuration = SyncConfiguration()
        configuration.maxPendingRuns = 2

        let directory = scratch()
        let pendingOld = UUID(), pendingNew = UUID(), rejectedNewest = UUID()
        try seed(directory, [
            entry(pendingOld, 0, .pending),
            entry(pendingNew, 60, .pending),
            entry(rejectedNewest, 120, .rejected),
        ])

        let queue = PendingPayloadQueue(directory: directory, configuration: configuration)
        XCTAssertEqual(queue.evictIfNeeded(), [rejectedNewest])
        XCTAssertNotNil(queue.payload(for: pendingOld))
        XCTAssertNotNil(queue.payload(for: pendingNew))
    }

    /// When everything queued is still deliverable, the budget must hold anyway — so the
    /// oldest pending payload goes. AC-FR-E-1-5 permits this: it forbids evicting an
    /// unacknowledged payload *in favour of* an acknowledged one, not evicting one at all.
    func testAnAllPendingQueueOverBudgetEvictsTheOldestPending() throws {
        var configuration = SyncConfiguration()
        configuration.maxPendingRuns = 3

        let directory = scratch()
        let oldest = UUID(), middle = UUID(), newer = UUID(), newest = UUID()
        try seed(directory, [
            entry(oldest, 0, .pending),
            entry(middle, 60, .pending),
            entry(newer, 120, .pending),
            entry(newest, 180, .pending),
        ])

        let queue = PendingPayloadQueue(directory: directory, configuration: configuration)
        XCTAssertEqual(queue.evictIfNeeded(), [oldest])
        XCTAssertFalse(queue.isOverBudget)
    }

    /// The byte budget, not just the count budget.
    func testTheByteBudgetIsEnforcedIndependentlyOfTheCountBudget() throws {
        var configuration = SyncConfiguration()
        configuration.maxPendingRuns = 100
        configuration.maxPendingBytes = 10_000

        let queue = PendingPayloadQueue(directory: scratch(), configuration: configuration)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<4 {
            try queue.enqueue(
                runID: UUID(), payload: payload(4_000),
                now: base.addingTimeInterval(Double(index) * 60)
            )
        }

        XCTAssertLessThanOrEqual(queue.totalByteCount, configuration.maxPendingBytes)
        XCTAssertFalse(queue.isOverBudget)
    }

    // MARK: - Rejections and stale contexts

    func testARejectionIsSurfacedRatherThanRetriedSilently() throws {
        let transport = FakeTransport()
        transport.isReachable = true
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let runID = UUID()
        try coordinator.enqueue(try envelope(runID: runID))

        coordinator.apply(PhoneContext(
            sequence: 1,
            acknowledgement: SyncAcknowledgement(
                nacked: [SyncNack(runID: runID, reason: .unsupportedSchema)]
            )
        ))

        XCTAssertEqual(coordinator.rejections.map(\.runID), [runID])
        XCTAssertEqual(queue.payload(for: runID)?.state, .rejected)
        XCTAssertEqual(queue.payload(for: runID)?.rejection, .unsupportedSchema)
        // A rejected run is not offered again — retrying would be pointless traffic.
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    /// `updateApplicationContext` is latest-value-wins but not ordered on receipt. A
    /// late-arriving older context must not undo newer state.
    func testAStaleContextIsIgnored() throws {
        let transport = FakeTransport()
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(queue: queue, transport: transport)

        let first = UUID(), second = UUID()
        try queue.enqueue(runID: first, payload: payload())
        try queue.enqueue(runID: second, payload: payload())

        XCTAssertNotNil(coordinator.apply(PhoneContext(
            sequence: 5, acknowledgement: SyncAcknowledgement(acked: [first])
        )))
        XCTAssertNil(
            coordinator.apply(PhoneContext(
                sequence: 4, acknowledgement: SyncAcknowledgement(acked: [second])
            )),
            "an out-of-order context was applied"
        )
        XCTAssertNotNil(queue.payload(for: second), "a stale context deleted a pending run")
    }

    /// The acknowledgement set is a rolling window precisely so a watch that missed several
    /// contexts still catches up in one delivery.
    func testABatchedAcknowledgementClearsEveryRunItNames() throws {
        let queue = PendingPayloadQueue(directory: scratch())
        let coordinator = SyncCoordinator(
            queue: queue, transport: FakeTransport()
        )

        let ids = (0..<5).map { _ in UUID() }
        for id in ids { try queue.enqueue(runID: id, payload: payload()) }

        coordinator.apply(PhoneContext(
            sequence: 1, acknowledgement: SyncAcknowledgement(acked: ids)
        ))

        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertTrue(queue.all.isEmpty)
    }

    /// An acknowledgement naming a run this watch has never heard of is ignored, not
    /// treated as an error — the phone's rolling window legitimately outlives the queue.
    func testAnAcknowledgementForAnUnknownRunIsHarmless() throws {
        let queue = PendingPayloadQueue(directory: scratch())
        let mine = UUID()
        try queue.enqueue(runID: mine, payload: payload())

        queue.apply(SyncAcknowledgement(acked: [UUID(), UUID()]))

        XCTAssertNotNil(queue.payload(for: mine))
    }

    // MARK: - Metadata

    /// The receiver reads `runID` and `schemaVersion` from metadata without opening the
    /// file, so a round-trip through the dictionary form has to be exact.
    func testTransferMetadataRoundTrips() throws {
        let runID = UUID()
        let metadata = SyncFileMetadata(runID: runID, schemaVersion: 7)
        let parsed = try XCTUnwrap(SyncFileMetadata(dictionary: metadata.dictionary))

        XCTAssertEqual(parsed.runID, runID)
        XCTAssertEqual(parsed.schemaVersion, 7)
    }

    /// `WCSession` round-trips plist types, so an `Int` written on one side can arrive as
    /// `NSNumber`. Both must parse, or a real transfer would be unroutable.
    func testMetadataAcceptsANumericSchemaVersion() throws {
        let runID = UUID()
        let parsed = try XCTUnwrap(SyncFileMetadata(dictionary: [
            SyncFileMetadata.runIDKey: runID.uuidString,
            SyncFileMetadata.schemaVersionKey: 1,
        ]))
        XCTAssertEqual(parsed.schemaVersion, 1)
    }

    func testUnreadableMetadataIsRefusedRatherThanGuessed() {
        XCTAssertNil(SyncFileMetadata(dictionary: [:]))
        XCTAssertNil(SyncFileMetadata(dictionary: [SyncFileMetadata.runIDKey: "not-a-uuid"]))
        XCTAssertNil(SyncFileMetadata(dictionary: [
            SyncFileMetadata.runIDKey: UUID().uuidString,
            SyncFileMetadata.schemaVersionKey: "not-a-number",
        ]))
    }
}
