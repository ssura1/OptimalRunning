import XCTest
import ORModels
import ORStats
import SwiftData
@testable import PhoneSupport

/// T-049 — receive, validate, upsert idempotently, update aggregates, acknowledge.
///
/// Every test here is about a failure that would be *silent*: a duplicated run, a
/// double-counted total, a payload swallowed without a message. "It didn't crash" is not the
/// bar — the bar is that the stored history is exactly right afterwards.
final class IngestTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try RunStoreContainer.inMemory()
        return ModelContext(container)
    }

    // MARK: - AC-FR-E-1-3 / NFR-13: idempotent ingest

    /// The same payload delivered twice — a retried transfer, or a relaunch mid-transfer.
    func testDuplicateDeliveryOfTheSamePayloadCreatesExactlyOneRecord() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runs = RunRepository(context: context)

        let runID = UUID()
        let payload = try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID)

        XCTAssertTrue(ingestor.ingest(payload: payload).isAccepted)
        XCTAssertTrue(ingestor.ingest(payload: payload).isAccepted)
        XCTAssertTrue(ingestor.ingest(payload: payload).isAccepted)

        XCTAssertEqual(try runs.count(), 1, "re-delivery created duplicate records")
        XCTAssertNotNil(try runs.record(for: runID))
    }

    /// The dangerous half of idempotency: the *totals* must not double-count either. A second
    /// delivery that leaves one record but twice the distance is exactly the silent corruption
    /// this wave is about.
    func testDuplicateDeliveryDoesNotDoubleCountAggregates() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let aggregates = AggregateRepository(context: context)

        let payload = try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: UUID())

        ingestor.ingest(payload: payload)
        let afterFirst = try aggregates.cache().lifetime

        ingestor.ingest(payload: payload)
        let afterSecond = try aggregates.cache().lifetime

        XCTAssertEqual(afterSecond.runCount, 1)
        XCTAssertEqual(afterFirst.runCount, 1)
        XCTAssertEqual(afterSecond.distanceMetres, afterFirst.distanceMetres, accuracy: 1e-6)
        XCTAssertEqual(afterSecond.activeSeconds, afterFirst.activeSeconds, accuracy: 1e-6)
        XCTAssertEqual(
            afterSecond.elevationGainMetres, afterFirst.elevationGainMetres, accuracy: 1e-6
        )
    }

    /// Two contexts over one container, both ingesting the same run — a background importer
    /// racing the main context. This is the reachable form of "delivered while an in-flight
    /// ingest of the same runID is still running", and the case `@Attribute(.unique)` exists
    /// to collapse.
    func testConcurrentIngestOfTheSameRunAcrossTwoContextsYieldsOneRecord() throws {
        let container = try RunStoreContainer.inMemory()
        let runID = UUID()
        let payload = try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID)

        let first = EnvelopeIngestor(context: ModelContext(container))
        let second = EnvelopeIngestor(context: ModelContext(container))

        // Interleaved rather than sequential: both read "no existing record" before either
        // writes, which is the ordering that produces a duplicate if uniqueness is not
        // enforced by the store.
        XCTAssertTrue(first.ingest(payload: payload).isAccepted)
        XCTAssertTrue(second.ingest(payload: payload).isAccepted)

        let verifier = RunRepository(context: ModelContext(container))
        XCTAssertEqual(try verifier.count(), 1, "a concurrent re-delivery duplicated the run")
    }

    /// A revised payload for the same run replaces rather than accumulates — the path a
    /// sidecar takes when it arrives after a degraded backfill.
    func testAReDeliveredPayloadReplacesTheStoredRecord() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runs = RunRepository(context: context)

        let runID = UUID()
        ingestor.ingest(payload: try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID))
        let first = try XCTUnwrap(try runs.record(for: runID))
        let firstDistance = first.distanceMetres

        // A different fixture under the same runID stands in for a revised payload.
        ingestor.ingest(payload: try FixtureEnvelopes.payload("hilly-10k", runID: runID))

        XCTAssertEqual(try runs.count(), 1)
        let second = try XCTUnwrap(try runs.record(for: runID))
        XCTAssertNotEqual(
            second.distanceMetres, firstDistance,
            "the revised payload did not replace the stored totals"
        )

        // And the aggregate reflects only the revision.
        let lifetime = try AggregateRepository(context: context).cache().lifetime
        XCTAssertEqual(lifetime.runCount, 1)
        XCTAssertEqual(lifetime.distanceMetres, second.distanceMetres, accuracy: 1e-6)
    }

    /// Steps are replaced, not accumulated — otherwise a re-delivered interval run would show
    /// eight reps for a 4×1000.
    func testReDeliveryDoesNotAccumulateSteps() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runs = RunRepository(context: context)

        let runID = UUID()
        let payload = try FixtureEnvelopes.payload("intervals-4x1000", runID: runID)

        ingestor.ingest(payload: payload)
        let firstCount = try XCTUnwrap(try runs.record(for: runID)).steps.count
        XCTAssertGreaterThan(firstCount, 0, "the fixture produced no steps to test with")

        ingestor.ingest(payload: payload)
        XCTAssertEqual(
            try XCTUnwrap(try runs.record(for: runID)).steps.count, firstCount,
            "re-delivery duplicated the step rows"
        )
    }

    // MARK: - AC-FR-E-1-4: unknown schema versions

    /// A version-2 payload against a version-1 phone. Tested with a synthetic future envelope
    /// rather than by trusting the version switch to be exhaustive.
    func testAFutureSchemaVersionIsRejectedGracefullyFromMetadata() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        let runID = UUID()
        let payload = try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID)
        let declared = SyncFileMetadata(runID: runID, schemaVersion: 2)

        let outcome = ingestor.ingest(payload: payload, declared: declared)

        guard case let .rejected(nack, message) = outcome else {
            return XCTFail("a version-2 payload was accepted")
        }
        XCTAssertEqual(nack.runID, runID)
        XCTAssertEqual(nack.reason, .unsupportedSchema)
        // The message has to be actionable, not a raw error.
        XCTAssertTrue(message.contains("Update the iPhone app"), "unhelpful message: \(message)")
        XCTAssertTrue(message.contains("kept on your watch"), "does not reassure: \(message)")
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    /// The same, with no metadata at all, so the version has to be caught from the bytes. The
    /// declared version is a hint; the payload is authoritative.
    func testAFutureSchemaVersionIsRejectedFromThePayloadItself() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        // A genuine future envelope: valid JSON, schemaVersion 2, fields this build has never
        // seen. Built by rewriting the version in a real payload rather than by hand, so it is
        // otherwise structurally exact.
        let built = try FixtureEnvelopes.build("tempo-5mi-rolling")
        var json = try JSONSerialization.jsonObject(
            with: try RunEnvelopeCoder.encode(built.envelope)
        ) as! [String: Any]
        json["schemaVersion"] = 2
        json["somethingFromTheFuture"] = ["nested": [1, 2, 3]]
        let future = try SyncPayloadCodec.compress(
            try JSONSerialization.data(withJSONObject: json)
        )

        let outcome = ingestor.ingest(payload: future)

        guard case let .rejected(nack, _) = outcome else {
            return XCTFail("a version-2 payload was accepted")
        }
        XCTAssertEqual(nack.reason, .unsupportedSchema)
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    func testAnOlderSchemaVersionIsAlsoRefusedWithItsOwnMessage() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runID = UUID()

        let outcome = ingestor.ingest(
            payload: try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID),
            declared: SyncFileMetadata(runID: runID, schemaVersion: 0)
        )

        guard case let .rejected(nack, message) = outcome else {
            return XCTFail("a version-0 payload was accepted")
        }
        XCTAssertEqual(nack.reason, .unsupportedSchema)
        XCTAssertTrue(message.contains("too old"), "unhelpful message: \(message)")
    }

    // MARK: - Malformed input

    func testATruncatedPayloadIsRejectedWithAMessageAndStoresNothing() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        let runID = UUID()
        let payload = try FixtureEnvelopes.payload("tempo-5mi-rolling", runID: runID)
        let truncated = Data(payload.prefix(payload.count / 3))

        let outcome = ingestor.ingest(
            payload: truncated, declared: SyncFileMetadata(runID: runID)
        )

        guard case let .rejected(nack, message) = outcome else {
            return XCTFail("a truncated payload was accepted")
        }
        XCTAssertEqual(nack.reason, .malformed)
        XCTAssertEqual(nack.runID, runID)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    func testRandomBytesAreRejectedRatherThanCrashing() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) })

        guard case .rejected = ingestor.ingest(payload: noise) else {
            return XCTFail("random bytes were accepted as a run")
        }
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    func testEmptyPayloadIsRejected() throws {
        let context = try makeContext()
        guard case .rejected = EnvelopeIngestor(context: context).ingest(payload: Data()) else {
            return XCTFail("an empty payload was accepted")
        }
    }

    /// A configuration snapshot outside its validated range must be refused, not stored — a
    /// stored one would silently mis-draw the run's band forever.
    func testAnOutOfRangeConfigurationSnapshotIsRejected() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        let built = try FixtureEnvelopes.build("tempo-5mi-rolling")
        var json = try JSONSerialization.jsonObject(
            with: try RunEnvelopeCoder.encode(built.envelope)
        ) as! [String: Any]
        var config = json["configSnapshot"] as! [String: Any]
        var rollingPace = config["rollingPace"] as! [String: Any]
        rollingPace["windowMetres"] = 999_999   // far outside 100...400
        config["rollingPace"] = rollingPace
        json["configSnapshot"] = config

        let payload = try SyncPayloadCodec.compress(
            try JSONSerialization.data(withJSONObject: json)
        )

        guard case let .rejected(nack, message) = ingestor.ingest(payload: payload) else {
            return XCTFail("an invalid configuration snapshot was accepted")
        }
        XCTAssertEqual(nack.reason, .invalidConfiguration)
        XCTAssertTrue(message.contains("settings this version cannot interpret"))
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    func testUnreadableMetadataIsRejectedWithoutStoringAnything() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString).gz")
        try FixtureEnvelopes.payload("tempo-5mi-rolling").write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        guard case let .rejected(nack, _) = ingestor.ingest(fileAt: url, metadata: [:]) else {
            return XCTFail("a payload with no metadata was accepted")
        }
        XCTAssertEqual(nack.reason, .malformed)
        XCTAssertEqual(try RunRepository(context: context).count(), 0)
    }

    func testAMissingFileIsRejectedRatherThanCrashing() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runID = UUID()

        let outcome = ingestor.ingest(
            fileAt: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).gz"),
            metadata: SyncFileMetadata(runID: runID).dictionary
        )

        guard case let .rejected(nack, _) = outcome else {
            return XCTFail("a missing file was accepted")
        }
        XCTAssertEqual(nack.reason, .malformed)
        XCTAssertEqual(nack.runID, runID)
    }

    // MARK: - Fidelity

    /// Every fixture survives the whole pipeline with its totals intact. This is the check
    /// that a field silently dropped in the envelope → store round-trip gets caught, for all
    /// seven recorded traces rather than one convenient one.
    func testEveryFixtureRoundTripsThroughIngestWithItsTotalsIntact() throws {
        for name in FixtureEnvelopes.allNames {
            let context = try makeContext()
            let ingestor = EnvelopeIngestor(context: context)
            let runs = RunRepository(context: context)

            let built = try FixtureEnvelopes.build(name)
            let outcome = ingestor.ingest(payload: try SyncPayloadCodec.encode(built.envelope))
            XCTAssertTrue(outcome.isAccepted, "\(name) was refused: \(outcome)")

            let record = try XCTUnwrap(try runs.record(for: built.envelope.runID), name)
            let expected = built.envelope.summary

            XCTAssertEqual(record.distanceMetres, expected.distanceMetres, accuracy: 1e-6, name)
            XCTAssertEqual(record.activeSeconds, expected.activeSeconds, accuracy: 1e-6, name)
            XCTAssertEqual(
                record.elevationGainMetres, expected.elevationGainMetres, accuracy: 1e-6, name
            )
            XCTAssertEqual(record.timeInZoneSeconds, expected.timeInZoneSeconds, name)
            XCTAssertEqual(record.runType, built.envelope.runType, name)
            XCTAssertFalse(record.isDegraded, name)

            // The blobs decode back to what went in.
            let samples = try XCTUnwrap(try record.samples(), name)
            XCTAssertEqual(samples.count, built.outputs.count, name)
            XCTAssertEqual(try record.zoneTimeline(), built.envelope.zoneTimeline, name)
            XCTAssertEqual(try record.configSnapshot(), built.envelope.configSnapshot, name)
            XCTAssertEqual(try record.profileSnapshot(), built.envelope.profileSnapshot, name)
        }
    }

    /// Degradation flags survive, because the detail view uses them to say what is missing.
    func testDegradationFlagsSurviveIngest() throws {
        let context = try makeContext()
        let ingestor = EnvelopeIngestor(context: context)
        let runs = RunRepository(context: context)

        // The treadmill fixture is flagged indoor and altimeter-unavailable by the engine.
        let built = try FixtureEnvelopes.build("treadmill-indoor")
        XCTAssertFalse(built.envelope.degradations.isEmpty, "fixture carries no flags to test")

        ingestor.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let record = try XCTUnwrap(try runs.record(for: built.envelope.runID))
        XCTAssertEqual(
            Set(record.degradationFlags), Set(built.envelope.degradations.map(\.rawValue))
        )
    }
}
