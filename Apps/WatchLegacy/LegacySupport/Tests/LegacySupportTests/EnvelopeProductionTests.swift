import XCTest
import ORIntervals
import ORModels
import ORPace
import ORStats
@testable import LegacySupport

/// This tier produces an envelope the phone cannot distinguish from a Modern one except by
/// `deviceTier` (T-071, FR-E-1).
///
/// ## How T-071's requirement is actually tested
///
/// T-071 says the strongest test is not a parallel "does Legacy sync work" suite — that could
/// quietly diverge from what Modern is held to — but **the ingest tests already written for T-049,
/// run against a Legacy-produced envelope**. Those tests live in `Apps/iPhone/PhoneSupport`, and
/// importing `LegacySupport` from there would wire a dependency from the phone to a watch tier that
/// has no business existing.
///
/// So the envelope crosses as an *artifact*, the same way the goldens do: this test drives a real
/// fixture through the real `RunEnvelopeBuilder` and the real `SyncPayloadCodec`, and writes the
/// exact bytes this tier would transmit to `Fixtures/legacy-tier-envelope.payload`. PhoneSupport's
/// `LegacyEnvelopeIngestTests` then ingests that file with the same assertions T-049 established.
///
/// The payload is committed rather than generated at test time on the phone side, and that is the
/// point: it is a real recording of this tier's output, so if the Legacy builder ever changes shape,
/// the phone's tests fail on the actual bytes rather than on a phone-side reconstruction of what
/// Legacy might send.
final class EnvelopeProductionTests: XCTestCase {

    private static let fixtureName = "intervals-4x1000"

    /// Where the transmitted bytes are committed for the phone tier to ingest.
    private var payloadURL: URL {
        FixtureLocating.repositoryRoot
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("legacy-tier-envelope.payload")
    }

    /// Builds the envelope exactly as a finished run would.
    private func buildEnvelope() throws -> RunEnvelope {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: Self.fixtureName))
        let replay = FixtureReplay.run(fixture)
        let plan = try XCTUnwrap(fixture.plan)

        var accumulator = StepSummaryAccumulator()
        for output in replay.outputs { accumulator.ingest(output) }
        accumulator.finish(with: replay.outputs.last)

        let samples = replay.outputs.map(\.sample)

        return RunEnvelopeBuilder.build(
            runID: UUID(uuidString: "1E6AC7DE-0000-4000-8000-000000000001")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + (samples.last?.timestamp ?? 0)),
            plan: plan,
            profile: fixture.profile,
            config: .default,
            healthKitWorkoutUUID: UUID(uuidString: "1E6AC7DE-0000-4000-8000-000000000002")!,
            samples: samples,
            zones: replay.outputs.map(\.zone),
            steps: accumulator.completed,
            activeSeconds: replay.outputs.last?.activeElapsed ?? 0,
            route: nil,
            degradations: [],
            appVersion: "1.0-legacy"
        )
    }

    /// The envelope is tagged `.legacy` and nothing else about it is tier-specific.
    func testTheEnvelopeIsTaggedLegacyAndOtherwiseStandard() throws {
        let envelope = try buildEnvelope()

        XCTAssertEqual(envelope.deviceTier, .legacy)
        XCTAssertEqual(
            envelope.schemaVersion, RunEnvelope.currentSchemaVersion,
            "a tier-specific schema version would make the phone's version gate tier-aware"
        )
        // The substance is present — a tier that shipped an empty payload would still "sync".
        XCTAssertGreaterThan(envelope.samples.count, 1_000)
        XCTAssertEqual(envelope.steps.count, 10, "the 4×1000 m plan resolves to ten steps")
        XCTAssertFalse(envelope.zoneTimeline.isEmpty)
        XCTAssertGreaterThan(envelope.summary.distanceMetres, 0)
        XCTAssertNotNil(envelope.plan)
    }

    /// The transmitted bytes round-trip, and are committed for the phone tier to ingest.
    func testTheTransmittedPayloadRoundTripsAndIsCommitted() throws {
        let envelope = try buildEnvelope()
        let payload = try SyncPayloadCodec.encode(envelope)

        // Round-trips through this tier's own codec first — if that fails, the committed artifact
        // would be meaningless.
        let decoded = try SyncPayloadCodec.decode(payload)
        XCTAssertEqual(decoded.runID, envelope.runID)
        XCTAssertEqual(decoded.deviceTier, .legacy)
        XCTAssertEqual(decoded.samples.count, envelope.samples.count)

        if ProcessInfo.processInfo.environment["REGENERATE_LEGACY_PAYLOAD"] == "1" {
            try payload.write(to: payloadURL)
            print("wrote \(payloadURL.lastPathComponent), \(payload.count) bytes")
            return
        }

        let committed = try Data(contentsOf: payloadURL)
        let committedEnvelope = try SyncPayloadCodec.decode(committed)

        // Compared as decoded envelopes rather than as bytes: gzip output is not guaranteed
        // byte-stable across zlib versions, and a byte comparison would fail on a toolchain upgrade
        // while the payload remained perfectly valid. What must be stable is the *content*.
        XCTAssertEqual(
            committedEnvelope.runID, envelope.runID,
            """
            Fixtures/legacy-tier-envelope.payload is stale. Regenerate with \
            REGENERATE_LEGACY_PAYLOAD=1 and re-run PhoneSupport's LegacyEnvelopeIngestTests, which \
            ingests this exact file (T-071).
            """
        )
        XCTAssertEqual(committedEnvelope.deviceTier, .legacy)
        XCTAssertEqual(committedEnvelope.samples.count, envelope.samples.count)
        XCTAssertEqual(committedEnvelope.steps.count, envelope.steps.count)
    }

    /// Compression is real, not an identity pass-through.
    ///
    /// `SyncPayloadCodec` throws rather than silently falling back when `Compression` is
    /// unavailable, so this confirms the platform actually compressed — a 1 800-sample columnar
    /// payload should shrink substantially.
    func testThePayloadIsGenuinelyCompressed() throws {
        let envelope = try buildEnvelope()
        let payload = try SyncPayloadCodec.encode(envelope)
        let raw = try JSONEncoder().encode(envelope)

        XCTAssertLessThan(
            payload.count, raw.count / 2,
            "the payload (\(payload.count) B) is not much smaller than raw JSON (\(raw.count) B)"
        )
    }
}
