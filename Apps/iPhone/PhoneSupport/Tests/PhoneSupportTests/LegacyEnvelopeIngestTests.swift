import XCTest
import ORModels
import ORStats
import SwiftData
@testable import PhoneSupport

/// The phone cannot tell a Legacy-produced run from a Modern one except by `deviceTier`
/// (T-071, FR-E-1, AC-FR-K-1-1).
///
/// ## Why this file is here and not in the Legacy tier
///
/// T-071's acceptance criterion is that "the same integration tests pass" for a Legacy envelope. The
/// weak way to satisfy that is a new suite in the Legacy tier asserting that sync works — parallel
/// assertions that can drift from what Modern is actually held to, which is the exact failure mode
/// Wave 4 exists to prevent. The strong way is to run **these** tests, the ones T-049 already
/// established, against Legacy's real output.
///
/// So the Legacy tier commits the exact bytes it would transmit to
/// `Fixtures/legacy-tier-envelope.payload` (see `EnvelopeProductionTests`), and this file ingests
/// that artifact through the same `RunLibrary` surface every other ingest test uses. No import
/// crosses between `Apps/iPhone` and `Apps/WatchLegacy`; the artifact is the seam, exactly as the
/// goldens are between the two watch tiers.
///
/// If the Legacy builder ever changes shape, this fails on the real bytes rather than on a
/// phone-side guess about what Legacy sends.
final class LegacyEnvelopeIngestTests: XCTestCase {

    /// `<repo>/Apps/iPhone/PhoneSupport/Tests/PhoneSupportTests/…` → `<repo>`.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhoneSupportTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PhoneSupport
            .deletingLastPathComponent()   // iPhone
            .deletingLastPathComponent()   // Apps
            .deletingLastPathComponent()   // repo root
    }

    private func legacyPayload() throws -> Data {
        let url = Self.repositoryRoot
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("legacy-tier-envelope.payload")
        return try Data(contentsOf: url)
    }

    private func makeLibrary() throws -> RunLibrary {
        RunLibrary(context: ModelContext(try RunStoreContainer.inMemory()))
    }

    // MARK: - The headline assertion

    /// A Legacy payload is accepted, stored, and analysable — the whole T-049 path.
    func testALegacyProducedEnvelopeIngestsExactlyLikeAModernOne() throws {
        let library = try makeLibrary()
        let payload = try legacyPayload()

        XCTAssertTrue(
            library.ingest(payload: payload).isAccepted,
            "the phone rejected a valid Legacy-tier payload"
        )
        XCTAssertEqual(try library.runs.count(), 1)

        let envelope = try SyncPayloadCodec.decode(payload)
        let record = try XCTUnwrap(try library.runs.record(for: envelope.runID))

        // The one intended difference.
        XCTAssertEqual(record.deviceTierRaw, DeviceTier.legacy.rawValue)

        // And nothing else is degraded relative to a Modern run: the summary, the step table, the
        // timeline and the samples all survive intact.
        XCTAssertEqual(record.distanceMetres, envelope.summary.distanceMetres, accuracy: 1e-6)
        XCTAssertEqual(record.activeSeconds, envelope.summary.activeSeconds, accuracy: 1e-6)
        XCTAssertEqual(record.steps.count, envelope.steps.count)
        XCTAssertGreaterThan(record.packedSamples?.count ?? 0, 0)

        let analysis = try RunAnalysis(record: record)
        XCTAssertTrue(analysis.hasSamples)
        XCTAssertTrue(analysis.isStructured, "a Legacy interval run did not read as structured")
        XCTAssertFalse(analysis.repRows().isEmpty, "the per-rep table is empty for a Legacy run")
        XCTAssertEqual(
            analysis.zoneShares().reduce(0) { $0 + $1.percentage }, 100, accuracy: 0.1
        )
    }

    /// Re-delivery is idempotent for a Legacy run, the property the whole sync design rests on
    /// (AC-FR-E-1-3).
    func testRedeliveryOfALegacyEnvelopeIsIdempotent() throws {
        let library = try makeLibrary()
        let payload = try legacyPayload()

        library.ingest(payload: payload)
        library.ingest(payload: payload)
        library.ingest(payload: payload)

        XCTAssertEqual(try library.runs.count(), 1, "a Legacy run was stored more than once")
        XCTAssertEqual(
            try library.aggregates.cache().lifetime.runCount, 1,
            "a re-delivered Legacy run was counted twice in lifetime totals"
        )
    }

    /// Lifetime aggregates fold a Legacy run in exactly as they would a Modern one.
    func testAggregatesIncludeALegacyRunOnTheSameTerms() throws {
        let library = try makeLibrary()
        let payload = try legacyPayload()
        let envelope = try SyncPayloadCodec.decode(payload)

        library.ingest(payload: payload)
        let cache = try library.aggregates.cache()

        XCTAssertEqual(cache.lifetime.runCount, 1)
        XCTAssertEqual(
            cache.lifetime.distanceMetres, envelope.summary.distanceMetres, accuracy: 1e-6
        )
    }

    /// The per-rep table a Legacy run produces carries one-based rep numbers.
    ///
    /// The Wave 3 `repIndex` bug shipped on both tiers, so it is worth asserting on the phone side
    /// too — this is the last place the number is read before a runner sees it in the app.
    func testTheLegacyRunsRepTableIsOneBased() throws {
        let library = try makeLibrary()
        let payload = try legacyPayload()
        library.ingest(payload: payload)

        let envelope = try SyncPayloadCodec.decode(payload)
        let record = try XCTUnwrap(try library.runs.record(for: envelope.runID))
        let analysis = try RunAnalysis(record: record)

        let workReps = analysis.repRows().filter { $0.step.kind == .work }
        XCTAssertEqual(workReps.count, 4)
        XCTAssertEqual(
            workReps.map(\.step.repIndex), [1, 2, 3, 4],
            "the Legacy run's reps are not numbered 1…4"
        )
    }

    /// The committed artifact is real, so the tests above are not passing on an empty file.
    func testTheCommittedLegacyPayloadIsSubstantial() throws {
        let payload = try legacyPayload()
        XCTAssertGreaterThan(payload.count, 10_000, "the committed Legacy payload looks truncated")

        let envelope = try SyncPayloadCodec.decode(payload)
        XCTAssertEqual(envelope.deviceTier, .legacy)
        XCTAssertGreaterThan(envelope.samples.count, 1_000)
    }
}
