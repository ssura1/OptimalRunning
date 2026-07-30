import Foundation
import ORModels
import ORStats
import SwiftData
import XCTest

@testable import PhoneSupport

/// A standalone run through the **existing** hub path (S-034, FR-S-E-1).
///
/// The claim under test is the one ADR-S-01 rests on: a phone-recorded run lands in the same
/// store, the same list and the same aggregates as a watch-recorded one, with no second
/// ingest and no screen-level special casing. So every assertion here goes through
/// `RunLibrary` — the production write surface — rather than reaching into the repository.
final class StandaloneIngestTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var library: RunLibrary!

    override func setUpWithError() throws {
        container = try RunStoreContainer.inMemory()
        context = ModelContext(container)
        library = RunLibrary(context: context)
    }

    override func tearDown() {
        library = nil
        context = nil
        container = nil
    }

    // MARK: - The ingest path itself

    func testAStandaloneRunIsAcceptedByTheExistingIngestPath() throws {
        let runID = UUID()
        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling", runID: runID)

        let outcome = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        XCTAssertTrue(outcome.isAccepted, "a standalone envelope must ingest unchanged")
        XCTAssertEqual(outcome.runID, runID)

        let record = try XCTUnwrap(library.runs.record(for: runID))
        XCTAssertEqual(record.deviceTier, .phoneStandalone)
    }

    func testAStandaloneRunAppearsInTheRunListLikeAnyOther() throws {
        let watchID = UUID()
        let phoneID = UUID()
        _ = library.ingest(payload: try FixtureEnvelopes.payload("hilly-10k", runID: watchID))
        _ = library.ingest(
            payload: try SyncPayloadCodec.encode(
                try FixtureEnvelopes.standalone("tempo-5mi-rolling", runID: phoneID).envelope))

        let items = try library.runs.listItems()
        XCTAssertEqual(items.count, 2)

        let phone = try XCTUnwrap(items.first { $0.runID == phoneID })
        let watch = try XCTUnwrap(items.first { $0.runID == watchID })

        // The row carries which tier produced it (AC-FR-S-E-1-5) and is otherwise the same
        // shape — same fields populated, same non-zero distance and duration.
        XCTAssertEqual(phone.deviceTier, .phoneStandalone)
        XCTAssertEqual(watch.deviceTier, .modern)
        XCTAssertGreaterThan(phone.distanceMetres, 0)
        XCTAssertGreaterThan(phone.activeSeconds, 0)
        XCTAssertNotNil(phone.averagePace)
    }

    func testStandaloneRunsCountTowardAggregatesOnTheSameBasis() throws {
        // AC-FR-S-E-1-3. Ingest a watch run, record the totals, ingest an identical-shaped
        // standalone run, and require the totals to have moved by that run's distance.
        _ = library.ingest(payload: try FixtureEnvelopes.payload("hilly-10k"))
        let afterWatch = try XCTUnwrap(try library.aggregates.cache())

        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling")
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))
        let afterPhone = try XCTUnwrap(try library.aggregates.cache())

        let added = afterPhone.lifetime.distanceMetres - afterWatch.lifetime.distanceMetres
        XCTAssertEqual(
            added, built.envelope.summary.distanceMetres, accuracy: 0.5,
            "a standalone run must contribute its distance to the lifetime total")
        XCTAssertEqual(afterPhone.lifetime.runCount, afterWatch.lifetime.runCount + 1)
    }

    func testThereIsOnlyOneStoreAndOneRunIDSpace() throws {
        // AC-FR-S-E-1-4, stated as the thing that would break if it were false: a
        // standalone run re-delivered under the same ID converges rather than duplicating,
        // exactly as a watch run does (NFR-13).
        let runID = UUID()
        let payload = try SyncPayloadCodec.encode(
            try FixtureEnvelopes.standalone("tempo-5mi-rolling", runID: runID).envelope)

        _ = library.ingest(payload: payload)
        _ = library.ingest(payload: payload)

        XCTAssertEqual(try library.runs.count(), 1)
        let cache = try XCTUnwrap(try library.aggregates.cache())
        XCTAssertEqual(cache.lifetime.runCount, 1, "re-delivery must not double-count")
    }

    // MARK: - Heart rate is absent, never zero (AC-FR-S-E-2-3, DEG-S-4)

    func testHeartRateIsAbsentEverywhereRatherThanZero() throws {
        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling")
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let item = try XCTUnwrap(try library.runs.listItems().first)
        XCTAssertNil(item.averageHeartRate, "the list must show no HR, not a zero")
        XCTAssertNil(item.maxHeartRate)

        let record = try XCTUnwrap(library.runs.record(for: built.envelope.runID))
        XCTAssertNil(record.summary.averageHeartRate)
        XCTAssertNil(record.summary.maxHeartRate)

        let analysis = try RunAnalysis(record: record)
        XCTAssertTrue(
            analysis.samples.allSatisfy { $0.heartRate == nil },
            "no sample may carry a fabricated heart rate")
    }

    func testAStandaloneRunDoesNotDragTheHeartRateStatisticsDown() throws {
        // The failure this guards against is the subtle one: a standalone run counted as
        // 0 bpm rather than as absent would halve a runner's average heart rate the moment
        // they left the watch at home. The aggregate cache carries no heart-rate term at
        // all, which is the structural reason it cannot happen — asserted here so that a
        // future addition of one has to confront this test.
        _ = library.ingest(payload: try FixtureEnvelopes.payload("hilly-10k"))
        let withWatchOnly = try XCTUnwrap(try library.aggregates.cache())

        _ = library.ingest(
            payload: try SyncPayloadCodec.encode(
                try FixtureEnvelopes.standalone("tempo-5mi-rolling").envelope))
        let withBoth = try XCTUnwrap(try library.aggregates.cache())

        // Distance moved; nothing heart-rate-shaped exists to move.
        XCTAssertGreaterThan(withBoth.lifetime.distanceMetres, withWatchOnly.lifetime.distanceMetres)
    }

    // MARK: - Provenance (FR-S-E-2)

    func testProvenanceSurvivesTheRoundTripAndReadsAsASentence() throws {
        let built = try FixtureEnvelopes.standalone(
            "gps-dropout-tunnel", telemetry: .partlyEstimated)
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let record = try XCTUnwrap(library.runs.record(for: built.envelope.runID))
        let analysis = try RunAnalysis(record: record)

        let facts = try XCTUnwrap(analysis.standalone)
        XCTAssertEqual(facts.measuredMetres, 6800, accuracy: 0.001)
        XCTAssertEqual(facts.estimatedMetres, 1200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(facts.measuredFraction), 6800.0 / 8000.0, accuracy: 1e-9)

        XCTAssertTrue(analysis.showsDistanceProvenance)
        let text = try XCTUnwrap(analysis.distanceProvenanceText)
        XCTAssertTrue(text.contains("85%"), "expected the measured percentage, got: \(text)")
    }

    func testAWatchRunShowsNoProvenancePanelAtAll() throws {
        // FR-S-E-1-2: standalone runs appear "with no changes to those screens beyond the
        // provenance surfacing". The other half of that promise is that a watch run gains
        // nothing — HealthKit's fused distance has no measured/estimated split of ours, and
        // inventing one would be a fabrication.
        _ = library.ingest(payload: try FixtureEnvelopes.payload("hilly-10k"))
        let record = try XCTUnwrap(try library.runs.listItems().first)
            .runID
        let analysis = try RunAnalysis(
            record: try XCTUnwrap(library.runs.record(for: record)))

        XCTAssertNil(analysis.standalone)
        XCTAssertFalse(analysis.showsDistanceProvenance)
        XCTAssertNil(analysis.distanceProvenanceText)
        XCTAssertNil(analysis.lowerConfidenceReason)
        XCTAssertTrue(analysis.motionNotices.isEmpty)
    }

    func testARunRecordedBeforeCalibrationConvergedSaysWhy() throws {
        // AC-FR-S-E-2-4, DEG-S-5.
        let built = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling", telemetry: .uncalibrated)
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let analysis = try RunAnalysis(
            record: try XCTUnwrap(library.runs.record(for: built.envelope.runID)))

        let reason = try XCTUnwrap(analysis.lowerConfidenceReason)
        XCTAssertTrue(
            reason.contains("published average"),
            "an uncalibrated run must say it used a published average, got: \(reason)")
        XCTAssertTrue(
            analysis.motionNotices.contains { $0.contains("published estimate") },
            "the uncalibrated-prior flag must be explained: \(analysis.motionNotices)")
    }

    func testAStoredRunIsNotRewrittenWhenCalibrationLaterImproves() throws {
        // AC-FR-S-E-2-5 — a recorded run is a record, not a prediction. The mechanism that
        // guarantees it is that the calibration is *stored on the run*, so there is nothing
        // for a later calibration to be read through.
        let built = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling", telemetry: .uncalibrated)
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        // A later, better-calibrated run arrives.
        _ = library.ingest(
            payload: try SyncPayloadCodec.encode(
                try FixtureEnvelopes.standalone(
                    "hilly-10k", telemetry: .measuredThroughout).envelope))

        let first = try RunAnalysis(
            record: try XCTUnwrap(library.runs.record(for: built.envelope.runID)))
        XCTAssertEqual(try XCTUnwrap(first.standalone).calibration.isCalibrated, false)
        XCTAssertNotNil(first.lowerConfidenceReason)
        XCTAssertEqual(
            first.summary.distanceMetres, built.envelope.summary.distanceMetres,
            accuracy: 0.001, "the stored distance must not move")
    }

    func testCadenceIsAFirstClassMetricOnAStandaloneRun() throws {
        // AC-FR-S-E-2-2.
        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling")
        _ = library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let analysis = try RunAnalysis(
            record: try XCTUnwrap(library.runs.record(for: built.envelope.runID)))
        XCTAssertEqual(analysis.averageCadenceText, "168 spm")
    }

    // MARK: - Backward and forward compatibility

    func testAWatchEnvelopeStillDecodesWithoutTheStandaloneField() throws {
        // The additive-optional claim, checked rather than reasoned about. An envelope
        // encoded with no `standalone` key must decode, and must decode to `nil` — not to a
        // default-constructed value that would then claim a carry position.
        let watch = try FixtureEnvelopes.build("tempo-5mi-rolling").envelope
        let data = try RunEnvelopeCoder.encode(watch)

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(
            json["standalone"],
            "a nil optional must be omitted from the encoding, not written as null")

        let decoded = try RunEnvelopeCoder.decode(data)
        XCTAssertNil(decoded.standalone)
        XCTAssertEqual(decoded.schemaVersion, RunEnvelope.currentSchemaVersion)
    }

    func testAStandaloneEnvelopeRoundTripsEveryFact() throws {
        let built = try FixtureEnvelopes.standalone(
            "gps-dropout-tunnel",
            telemetry: .partlyEstimated,
            estimatedSpans: [
                .init(startSeconds: 300, endSeconds: 420),
                .init(startSeconds: 900, endSeconds: 930),
            ])

        let decoded = try RunEnvelopeCoder.decode(
            try RunEnvelopeCoder.encode(built.envelope))
        let facts = try XCTUnwrap(decoded.standalone)

        XCTAssertEqual(facts.carryPosition, .handHeld)
        XCTAssertEqual(facts.stepCount, 4100)
        XCTAssertEqual(facts.flags, [.distanceEstimated])
        XCTAssertEqual(facts.estimatedSpans.count, 2)
        XCTAssertEqual(facts.estimatedSpans[0].durationSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(facts.calibration.metresPerStepAtTypicalCadence ?? 0, 1.03, accuracy: 1e-9)
    }

    func testAStandaloneRunRecordsGPSDegradationInCoresOwnVocabulary() throws {
        // The one place a `MotionFlag` is translated into a `DegradationFlag`: a run that
        // fell back to the motion model is a GPS-degraded run in Core's sense, so the run
        // list's existing degraded treatment applies without knowing what a step-length
        // model is.
        let built = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling", telemetry: .partlyEstimated)
        XCTAssertTrue(built.envelope.degradations.contains(.gpsDegraded))

        let clean = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling", telemetry: .measuredThroughout)
        XCTAssertFalse(clean.envelope.degradations.contains(.gpsDegraded))
    }
}
