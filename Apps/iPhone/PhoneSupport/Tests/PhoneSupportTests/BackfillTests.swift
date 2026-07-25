import XCTest
import ORModels
import SwiftData
@testable import PhoneSupport

/// A workout source the test controls.
struct FakeHealthSource: HealthWorkoutSource {
    var workouts: [HealthWorkout] = []

    func runningWorkouts(from: Date, to: Date) async throws -> [HealthWorkout] {
        workouts.filter { $0.startedAt >= from && $0.startedAt <= to }
    }
}

/// T-051 — reconstructing a run from HealthKit when no sidecar arrived, and above all never
/// destroying better data in the process.
final class BackfillTests: XCTestCase {

    private let windowStart = Date(timeIntervalSince1970: 1_600_000_000)
    private let windowEnd = Date(timeIntervalSince1970: 1_900_000_000)

    private func makeContext() throws -> ModelContext {
        ModelContext(try RunStoreContainer.inMemory())
    }

    private func workout(
        uuid: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        distance: Double = 10_000,
        activeSeconds: TimeInterval = 3_000,
        route: [RoutePoint]? = nil
    ) -> HealthWorkout {
        HealthWorkout(
            workoutUUID: uuid,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(activeSeconds),
            distanceMetres: distance,
            activeSeconds: activeSeconds,
            averageHeartRate: 148,
            maxHeartRate: 171,
            route: route
        )
    }

    private func backfill(
        _ context: ModelContext, _ workouts: [HealthWorkout]
    ) async throws -> BackfillReport {
        try await BackfillService(context: context).backfill(
            from: FakeHealthSource(workouts: workouts),
            window: (windowStart, windowEnd)
        )
    }

    // MARK: - Ordering 1: the sidecar is genuinely lost

    /// AC-FR-E-1-6 — a run whose payload never arrives still appears, with what HealthKit knows.
    func testAWorkoutWithNoPayloadBecomesADegradedRecord() async throws {
        let context = try makeContext()
        let route = FixtureEnvelopes.syntheticRoute(pointCount: 50)
        let health = workout(distance: 10_000, activeSeconds: 3_000, route: route)

        let report = try await backfill(context, [health])
        XCTAssertEqual(report.created, [health.workoutUUID])

        let records = try context.fetch(FetchDescriptor<RunRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)

        XCTAssertTrue(record.isDegraded)
        XCTAssertEqual(record.healthKitWorkoutUUID, health.workoutUUID)
        XCTAssertEqual(record.distanceMetres, 10_000, accuracy: 1e-9)
        XCTAssertEqual(record.activeSeconds, 3_000, accuracy: 1e-9)
        XCTAssertEqual(record.averageHeartRate, 148)
        XCTAssertEqual(record.maxHeartRate, 171)
        XCTAssertEqual(try record.route()?.count, 50)

        // And what is genuinely missing stays missing rather than being invented.
        XCTAssertNil(record.packedSamples, "a degraded record must not fabricate samples")
        XCTAssertNil(try record.configSnapshot())
        XCTAssertTrue(try record.zoneTimeline().isEmpty)
        XCTAssertEqual(record.elevationGainMetres, 0)
        XCTAssertTrue(record.degradationFlags.contains(DegradationFlag.noTargetPace.rawValue))
        XCTAssertTrue(
            record.degradationFlags.contains(DegradationFlag.altimeterUnavailable.rawValue),
            "the detail view reads this to hide the elevation chart rather than draw a flat line"
        )
    }

    /// A backfilled run must not claim a personal best. HealthKit gives whole-run totals only,
    /// so awarding a 5 k best from an average pace over 10 km would be fiction.
    func testABackfilledRunSetsNoPersonalBest() async throws {
        let context = try makeContext()
        try await backfill(context, [workout(distance: 10_000, activeSeconds: 2_400)])

        let cache = try AggregateRepository(context: context).cache()
        XCTAssertEqual(cache.lifetime.runCount, 1, "the run should count toward totals")
        XCTAssertTrue(cache.bests.isEmpty, "a backfilled run claimed a personal best")
    }

    /// Running twice must not duplicate — a backfill pass is scheduled, not one-shot.
    func testBackfillIsIdempotentAcrossPasses() async throws {
        let context = try makeContext()
        let health = workout()

        let first = try await backfill(context, [health])
        let second = try await backfill(context, [health])

        XCTAssertEqual(first.created, [health.workoutUUID])
        XCTAssertTrue(second.created.isEmpty)
        XCTAssertEqual(second.skippedExistingDegraded, [health.workoutUUID])
        XCTAssertEqual(try RunRepository(context: context).count(), 1)

        let cache = try AggregateRepository(context: context).cache()
        XCTAssertEqual(cache.lifetime.runCount, 1, "a second pass double-counted the run")
    }

    // MARK: - Ordering 2: a complete record already exists

    /// The requirement's own words: backfill never overwrites a complete record.
    func testBackfillSkipsAWorkoutThatAlreadyHasACompleteRecord() async throws {
        let context = try makeContext()
        let workoutUUID = UUID()

        // The sidecar arrived first, stamped with the HealthKit workout it belongs to.
        let built = try FixtureEnvelopes.build("hilly-10k", healthKitWorkoutUUID: workoutUUID)
        let ingestor = EnvelopeIngestor(context: context)
        XCTAssertTrue(
            ingestor.ingest(payload: try SyncPayloadCodec.encode(built.envelope)).isAccepted
        )
        let completeDistance = built.envelope.summary.distanceMetres

        // Now HealthKit reports the same workout with different totals.
        let report = try await backfill(
            context, [workout(uuid: workoutUUID, distance: 1.0, activeSeconds: 1.0)]
        )

        XCTAssertEqual(report.skippedComplete, [workoutUUID])
        XCTAssertTrue(report.created.isEmpty)

        let records = try context.fetch(FetchDescriptor<RunRecord>())
        XCTAssertEqual(records.count, 1, "backfill added a second record for one run")
        let record = try XCTUnwrap(records.first)
        XCTAssertFalse(record.isDegraded, "backfill degraded a complete record")
        XCTAssertEqual(
            record.distanceMetres, completeDistance, accuracy: 1e-6,
            "backfill overwrote a complete record's totals with HealthKit's"
        )
        XCTAssertNotNil(record.packedSamples, "backfill destroyed the sample blob")
    }

    // MARK: - Ordering 3: the sidecar arrives *after* a backfill — the dangerous one

    /// The case a naive implementation gets wrong.
    ///
    /// The placeholder was created under a `runID` this app invented, because the watch's own
    /// was unknowable. The sidecar then arrives carrying a *different* `runID` for the same
    /// physical run. Keyed only on `runID`, the upsert cannot see the placeholder, so the store
    /// ends up holding two records for one run — and every lifetime total counts it twice.
    /// That is worse than either failure alone, and it is silent.
    func testASidecarArrivingAfterABackfillReplacesThePlaceholderRatherThanDuplicatingIt() async throws {
        let context = try makeContext()
        let workoutUUID = UUID()

        // 1. Backfill creates a degraded placeholder.
        try await backfill(context, [workout(uuid: workoutUUID, distance: 9_000, activeSeconds: 2_700)])
        let placeholderRunID = try XCTUnwrap(
            try context.fetch(FetchDescriptor<RunRecord>()).first?.runID
        )
        let afterBackfill = try AggregateRepository(context: context).cache().lifetime
        XCTAssertEqual(afterBackfill.runCount, 1)

        // 2. The real payload turns up, under the watch's own runID.
        let built = try FixtureEnvelopes.build("hilly-10k", healthKitWorkoutUUID: workoutUUID)
        XCTAssertNotEqual(
            built.envelope.runID, placeholderRunID,
            "the test must use a different runID or it is not exercising the trap"
        )
        let outcome = EnvelopeIngestor(context: context)
            .ingest(payload: try SyncPayloadCodec.encode(built.envelope))
        XCTAssertTrue(outcome.isAccepted)

        // 3. Exactly one record, and it is the complete one.
        let records = try context.fetch(FetchDescriptor<RunRecord>())
        XCTAssertEqual(
            records.count, 1,
            "the store holds \(records.count) records for one run — the placeholder was not superseded"
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.runID, built.envelope.runID)
        XCTAssertFalse(record.isDegraded, "the complete payload did not clear the degraded flag")
        XCTAssertNotNil(record.packedSamples)
        XCTAssertEqual(
            record.distanceMetres, built.envelope.summary.distanceMetres, accuracy: 1e-6
        )

        // 4. And the totals count the run once, with the payload's figures — not the sum of
        //    the placeholder's and the real one's.
        let lifetime = try AggregateRepository(context: context).cache().lifetime
        XCTAssertEqual(lifetime.runCount, 1, "the run is counted twice in lifetime totals")
        XCTAssertEqual(
            lifetime.distanceMetres, built.envelope.summary.distanceMetres, accuracy: 1e-6,
            "the placeholder's distance is still included in the lifetime total"
        )

        // 5. The incremental cache agrees with a full recomputation — the check that catches
        //    a removal that corrected the record but not the totals.
        let runs = RunRepository(context: context)
        let rebuilt = try AggregateRepository(context: context).rebuildAll(runs: runs)
        XCTAssertEqual(rebuilt.lifetime.runCount, 1)
        XCTAssertEqual(rebuilt.lifetime.distanceMetres, lifetime.distanceMetres, accuracy: 1e-6)
    }

    /// A payload with no `healthKitWorkoutUUID` cannot be reconciled — and must not guess.
    ///
    /// Matching such a payload to a placeholder by start time would be a heuristic that
    /// silently merges two different runs recorded minutes apart. Leaving both records is the
    /// honest outcome: visible, and correctable by the user.
    func testAPayloadWithNoWorkoutUUIDDoesNotGuessAtAPlaceholder() async throws {
        let context = try makeContext()
        let workoutUUID = UUID()

        try await backfill(context, [workout(uuid: workoutUUID)])
        let built = try FixtureEnvelopes.build("tempo-5mi-rolling", healthKitWorkoutUUID: nil)
        EnvelopeIngestor(context: context)
            .ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        XCTAssertEqual(
            try RunRepository(context: context).count(), 2,
            "an unlinkable payload was merged into a placeholder by guesswork"
        )
    }

    /// Re-delivery of a payload that already superseded a placeholder must stay idempotent.
    func testReDeliveryAfterSupersedingAPlaceholderStaysIdempotent() async throws {
        let context = try makeContext()
        let workoutUUID = UUID()

        try await backfill(context, [workout(uuid: workoutUUID)])
        let built = try FixtureEnvelopes.build("hilly-10k", healthKitWorkoutUUID: workoutUUID)
        let payload = try SyncPayloadCodec.encode(built.envelope)
        let ingestor = EnvelopeIngestor(context: context)

        ingestor.ingest(payload: payload)
        ingestor.ingest(payload: payload)
        ingestor.ingest(payload: payload)

        XCTAssertEqual(try RunRepository(context: context).count(), 1)
        let lifetime = try AggregateRepository(context: context).cache().lifetime
        XCTAssertEqual(lifetime.runCount, 1)
        XCTAssertEqual(
            lifetime.distanceMetres, built.envelope.summary.distanceMetres, accuracy: 1e-6
        )
    }

    /// And a backfill pass *after* the sidecar superseded the placeholder finds nothing to do.
    func testABackfillAfterSupersessionDoesNotRecreateThePlaceholder() async throws {
        let context = try makeContext()
        let workoutUUID = UUID()
        let health = workout(uuid: workoutUUID)

        try await backfill(context, [health])
        let built = try FixtureEnvelopes.build("hilly-10k", healthKitWorkoutUUID: workoutUUID)
        EnvelopeIngestor(context: context)
            .ingest(payload: try SyncPayloadCodec.encode(built.envelope))

        let report = try await backfill(context, [health])

        XCTAssertEqual(report.skippedComplete, [workoutUUID])
        XCTAssertEqual(try RunRepository(context: context).count(), 1)
    }

    // MARK: - Window and ordering

    func testWorkoutsOutsideTheWindowAreIgnored() async throws {
        let context = try makeContext()
        let inside = workout(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let outside = workout(startedAt: Date(timeIntervalSince1970: 1_500_000_000))

        let report = try await backfill(context, [inside, outside])

        XCTAssertEqual(report.created, [inside.workoutUUID])
        XCTAssertEqual(try RunRepository(context: context).count(), 1)
    }

    /// Backfill applies oldest-first so the incremental cache matches a rebuild, which walks
    /// runs in chronological order.
    func testABackfillOfManyWorkoutsMatchesAFullRebuild() async throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Deliberately handed over newest-first, to prove the service orders them itself.
        let workouts = (0..<12).reversed().map { index in
            workout(
                startedAt: base.addingTimeInterval(Double(index) * 86_400 * 3),
                distance: 5_000 + Double(index) * 500,
                activeSeconds: 1_500 + Double(index) * 60
            )
        }

        try await backfill(context, workouts)

        let aggregates = AggregateRepository(context: context)
        let incremental = try aggregates.cache()
        let rebuilt = try aggregates.rebuildAll(runs: RunRepository(context: context))

        XCTAssertEqual(incremental.lifetime.runCount, 12)
        XCTAssertEqual(incremental.lifetime.runCount, rebuilt.lifetime.runCount)
        XCTAssertEqual(
            incremental.lifetime.distanceMetres, rebuilt.lifetime.distanceMetres, accuracy: 1e-6
        )
        XCTAssertEqual(
            incremental.lifetime.activeSeconds, rebuilt.lifetime.activeSeconds, accuracy: 1e-6
        )
        XCTAssertEqual(incremental.byWeek.count, rebuilt.byWeek.count)
    }
}
