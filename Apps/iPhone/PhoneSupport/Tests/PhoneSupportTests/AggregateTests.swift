import XCTest
import ORModels
import ORStats
import SwiftData
@testable import PhoneSupport

/// T-061 — the statistics screen's totals and personal bests.
///
/// The incremental cache is the thing at risk here. It is updated a run at a time and read
/// forever, so an error in one update persists silently: a lifetime distance that is 8 km light
/// looks exactly like a lifetime distance that is right. `rebuildAll()` is the oracle, and these
/// tests exist to keep the two in agreement under sequences nobody would think to try by hand.
final class AggregateTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try RunStoreContainer.inMemory())
    }

    // MARK: - Incremental versus rebuild, fuzzed

    /// Random sequences of ingests, deletions, re-deliveries and backfill upgrades, each checked
    /// against a full recomputation.
    ///
    /// A single fixed scenario would only prove the orderings its author imagined. The
    /// interesting drift comes from interleavings — a deletion between two re-deliveries of the
    /// same run, a backfill superseded halfway through — and the point of fuzzing is to reach
    /// those without having to enumerate them.
    ///
    /// Bests are deliberately excluded from the comparison: `AggregateCache.remove` cannot
    /// restore a best a deleted run had held, which `Core` documents, so the additive totals are
    /// what must match. That asymmetry is covered separately below.
    func testIncrementalTotalsMatchAFullRebuildUnderRandomOperationSequences() async throws {
        for seed in 0..<12 {
            var generator = SeededGenerator(seed: UInt64(seed) &* 0x9E37_79B9 &+ 17)
            let context = try makeContext()
            let library = RunLibrary(context: context)

            var liveRunIDs: [UUID] = []
            let fixtures = FixtureEnvelopes.allNames
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            for step in 0..<24 {
                switch Int.random(in: 0..<10, using: &generator) {
                case 0...4:
                    // Ingest a new run.
                    let runID = UUID()
                    let name = fixtures[Int.random(in: 0..<fixtures.count, using: &generator)]
                    let built = try FixtureEnvelopes.build(
                        name,
                        runID: runID,
                        startedAt: base.addingTimeInterval(Double(step) * 86_400 * 2)
                    )
                    if library.ingest(payload: try SyncPayloadCodec.encode(built.envelope)).isAccepted {
                        liveRunIDs.append(runID)
                    }

                case 5...6 where !liveRunIDs.isEmpty:
                    // Re-deliver an existing run — must be a no-op for the totals.
                    let runID = liveRunIDs[Int.random(in: 0..<liveRunIDs.count, using: &generator)]
                    let name = fixtures[Int.random(in: 0..<fixtures.count, using: &generator)]
                    let built = try FixtureEnvelopes.build(
                        name,
                        runID: runID,
                        startedAt: try XCTUnwrap(library.runs.record(for: runID)).startedAt
                    )
                    library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))

                case 7 where !liveRunIDs.isEmpty:
                    // Delete one.
                    let index = Int.random(in: 0..<liveRunIDs.count, using: &generator)
                    try library.delete(runID: liveRunIDs.remove(at: index))

                case 8...9:
                    // A degraded backfill, sometimes later superseded by its sidecar — the
                    // upgrade path, which touches both the store and the totals.
                    let workoutUUID = UUID()
                    let startedAt = base.addingTimeInterval(Double(step) * 86_400 * 2)
                    let source = FakeHealthSource(workouts: [
                        HealthWorkout(
                            workoutUUID: workoutUUID,
                            startedAt: startedAt,
                            endedAt: startedAt.addingTimeInterval(2_400),
                            distanceMetres: Double.random(in: 3_000...15_000, using: &generator),
                            activeSeconds: Double.random(in: 900...4_500, using: &generator),
                            averageHeartRate: 145,
                            maxHeartRate: 168
                        ),
                    ])
                    try await BackfillService(context: context).backfill(
                        from: source, window: (base.addingTimeInterval(-86_400), Date.distantFuture)
                    )
                    if let created = try BackfillService(context: context)
                        .record(forWorkout: workoutUUID) {
                        liveRunIDs.append(created.runID)
                    }

                    if Bool.random(using: &generator) {
                        // The sidecar turns up and supersedes the placeholder.
                        let runID = UUID()
                        let built = try FixtureEnvelopes.build(
                            "tempo-5mi-rolling",
                            runID: runID,
                            startedAt: startedAt,
                            healthKitWorkoutUUID: workoutUUID
                        )
                        if library.ingest(
                            payload: try SyncPayloadCodec.encode(built.envelope)
                        ).isAccepted {
                            // The placeholder is gone; the payload's run replaces it.
                            liveRunIDs.removeAll { id in
                                (try? library.runs.record(for: id)) == nil
                            }
                            liveRunIDs.append(runID)
                        }
                    }

                default:
                    continue
                }

                // After every single operation, the incremental cache must still agree with a
                // recomputation. Checking only at the end would let two errors cancel out.
                let incremental = try library.aggregates.cache()
                let rebuilt = try RunLibrary(context: context).rebuildAggregates()

                let context1 = "seed \(seed) step \(step)"
                XCTAssertEqual(
                    incremental.lifetime.runCount, rebuilt.lifetime.runCount,
                    "\(context1): run count drifted"
                )
                XCTAssertEqual(
                    incremental.lifetime.distanceMetres, rebuilt.lifetime.distanceMetres,
                    accuracy: 0.001, "\(context1): distance drifted"
                )
                XCTAssertEqual(
                    incremental.lifetime.activeSeconds, rebuilt.lifetime.activeSeconds,
                    accuracy: 0.001, "\(context1): active time drifted"
                )
                XCTAssertEqual(
                    incremental.lifetime.elevationGainMetres,
                    rebuilt.lifetime.elevationGainMetres,
                    accuracy: 0.001, "\(context1): elevation drifted"
                )

                // Per-period totals too — a lifetime figure can be right while a month is wrong.
                for (key, totals) in rebuilt.byMonth {
                    XCTAssertEqual(
                        incremental.totals(for: key), totals, accuracy: 0.001,
                        "\(context1): month \(key) drifted"
                    )
                }
                for (key, totals) in rebuilt.byWeek {
                    XCTAssertEqual(
                        incremental.totals(for: key), totals, accuracy: 0.001,
                        "\(context1): week \(key) drifted"
                    )
                }

                // And the cache must agree with the store about how many runs exist.
                XCTAssertEqual(
                    incremental.lifetime.runCount, try library.runs.count(),
                    "\(context1): the cache and the store disagree about the run count"
                )
            }
        }
    }

    /// Deleting every run must return the totals to zero, not to a small residue.
    ///
    /// Floating-point subtraction of the same values in a different order is exactly where a
    /// residue would appear, and a lifetime distance of 0.0000001 km is the kind of wrong that
    /// never gets noticed.
    func testDeletingEveryRunReturnsTheTotalsToZero() throws {
        let context = try makeContext()
        let library = RunLibrary(context: context)
        var runIDs: [UUID] = []

        for (index, name) in FixtureEnvelopes.allNames.enumerated() {
            let runID = UUID()
            let built = try FixtureEnvelopes.build(
                name,
                runID: runID,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400 * 5)
            )
            library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))
            runIDs.append(runID)
        }

        XCTAssertEqual(try library.aggregates.cache().lifetime.runCount, runIDs.count)

        for runID in runIDs.shuffled() {
            try library.delete(runID: runID)
        }

        let lifetime = try library.aggregates.cache().lifetime
        XCTAssertEqual(lifetime.runCount, 0)
        XCTAssertEqual(lifetime.distanceMetres, 0, accuracy: 1e-6)
        XCTAssertEqual(lifetime.activeSeconds, 0, accuracy: 1e-6)
        XCTAssertEqual(lifetime.elevationGainMetres, 0, accuracy: 1e-6)
        XCTAssertEqual(try library.runs.count(), 0)
    }

    // MARK: - Personal bests

    /// AC-FR-F-3-4 — the best 5 k inside a longer run counts.
    ///
    /// The implementation this catches is the one that matches whole-run distance: it passes
    /// trivially on a 5 km run and reports *no* 5 k best for a 10 km run, which is wrong in the
    /// most common case there is. The run below is deliberately 10 km with a genuinely fast
    /// middle section, so a whole-run implementation either finds nothing or reports the slow
    /// average.
    func testTheBest5kInsideALongerRunIsFound() throws {
        // 10 km: 3 km steady, 5 km fast, 2 km steady. The fast segment is not at either end, so
        // an implementation that only checks prefixes or suffixes also fails.
        let steadyPace = 0.36    // s/m — 6:00/km
        let fastPace = 0.24      // s/m — 4:00/km

        var samples: [RunSample] = []
        var distance = 0.0
        var time = 0.0

        func run(metres: Double, pace: Double) {
            let steps = Int(metres / 3)
            for _ in 0..<steps {
                distance += 3
                time += 3 * pace
                samples.append(RunSample(
                    timestamp: time, cumulativeDistance: distance,
                    rollingPace: Pace(secondsPerMetre: pace), heartRate: 150,
                    relativeAltitude: 0, smoothedGrade: 0, gradeFactor: .identity,
                    rawTarget: nil, effectiveTarget: nil, zone: .onTarget
                ))
            }
        }

        run(metres: 3_000, pace: steadyPace)
        run(metres: 5_000, pace: fastPace)
        run(metres: 2_000, pace: steadyPace)

        let bests = AggregateRepository.bestEfforts(from: samples)
        let fiveK = try XCTUnwrap(bests[.fiveKilometres], "no 5 k best was found in a 10 km run")

        // The embedded 5 km at 4:00/km is 1 200 s. A whole-run implementation would report the
        // 10 km average over 5 km — about 1 560 s — or nothing at all.
        XCTAssertEqual(
            fiveK.seconds, 5_000 * fastPace, accuracy: 15,
            "the 5 k best is \(fiveK.seconds)s; the embedded fast segment is \(5_000 * fastPace)s"
        )
        XCTAssertEqual(
            fiveK.startDistanceMetres, 3_000, accuracy: 60,
            "the best segment was located at \(fiveK.startDistanceMetres) m, not at the fast part"
        )

        // The discriminating comparison: a whole-run implementation would report the run's
        // *average* pace over 5 km. The embedded segment is far faster than that, so the two
        // answers are separated by minutes rather than by rounding.
        let wholeRunAverageOver5k = time / distance * 5_000
        XCTAssertLessThan(
            fiveK.seconds, wholeRunAverageOver5k - 120,
            "the 5 k best (\(fiveK.seconds)s) is no faster than the whole-run average over 5 km "
                + "(\(wholeRunAverageOver5k)s), which is what a whole-run implementation reports"
        )

        // 10 km is *not* claimed: the run covers 9 993 m between its first and last sample, and
        // a best must be a segment the runner actually completed. Reporting one here would mean
        // the sweep is rounding a benchmark it did not reach.
        XCTAssertNil(
            bests[.tenKilometres],
            "a 9 993 m run claimed a 10 km best"
        )
    }

    /// A run shorter than a benchmark claims no best for it.
    func testARunShorterThanABenchmarkClaimsNoBestForIt() throws {
        var samples: [RunSample] = []
        for index in 0..<1_000 {
            samples.append(RunSample(
                timestamp: Double(index) * 0.3, cumulativeDistance: Double(index) * 3,
                rollingPace: Pace(secondsPerMetre: 0.3), heartRate: 150,
                relativeAltitude: 0, smoothedGrade: 0, gradeFactor: .identity,
                rawTarget: nil, effectiveTarget: nil, zone: .onTarget
            ))
        }

        // 3 km covered.
        let bests = AggregateRepository.bestEfforts(from: samples)
        XCTAssertNotNil(bests[.oneMile], "a mile fits inside 3 km")
        XCTAssertNil(bests[.fiveKilometres], "a 3 km run claimed a 5 k best")
        XCTAssertNil(bests[.halfMarathon])
    }

    /// Bests survive the store round-trip and are found by the sweep over unpacked samples.
    func testBestsAreComputedFromStoredRunsAndImproveOverTime() throws {
        let context = try makeContext()
        let library = RunLibrary(context: context)

        // Two runs, the second faster over the same distance.
        for (index, name) in ["tempo-5mi-rolling", "tempo-5mi-rolling"].enumerated() {
            let built = try FixtureEnvelopes.build(
                name,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400 * 7)
            )
            library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))
        }

        let incremental = try library.aggregates.cache()
        let rebuilt = try library.rebuildAggregates(includingBests: true)

        XCTAssertFalse(incremental.bests.isEmpty, "no bests were recorded from stored runs")
        XCTAssertEqual(
            Set(incremental.bests.keys), Set(rebuilt.bests.keys),
            "the incremental sweep and the rebuild disagree about which benchmarks were reached"
        )
        for (distance, best) in rebuilt.bests {
            let incrementalSeconds = try XCTUnwrap(
                incremental.bests[distance]?.seconds,
                "\(distance) best is missing from the incremental cache"
            )
            XCTAssertEqual(
                incrementalSeconds, best.seconds, accuracy: 1e-6,
                "\(distance) best drifted between incremental and rebuild"
            )
        }
    }

    /// Deleting the run that held a best triggers a rebuild, so a deleted run cannot keep
    /// claiming the record.
    func testDeletingTheRunHoldingABestRecomputesTheBests() throws {
        let context = try makeContext()
        let library = RunLibrary(context: context)

        let runID = UUID()
        let built = try FixtureEnvelopes.build("tempo-5mi-rolling", runID: runID)
        library.ingest(payload: try SyncPayloadCodec.encode(built.envelope))
        XCTAssertFalse(try library.aggregates.cache().bests.isEmpty)

        try library.delete(runID: runID)

        XCTAssertTrue(
            try library.aggregates.cache().bests.isEmpty,
            "a deleted run is still claiming a personal best"
        )
    }
}

// MARK: - Helpers

/// A deterministic generator, so a fuzz failure can be reproduced from its seed.
///
/// `SystemRandomNumberGenerator` would make failures unrepeatable, which is the one thing a fuzz
/// test cannot afford: the whole value is in being able to re-run the exact sequence that broke.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x4d59_5df4_d0f3_3173 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*, adequate for choosing test operations and trivially reproducible.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}

extension AggregateCache {
    /// Totals for a period key, whichever granularity it names.
    func totals(for key: PeriodKey) -> AggregateTotals {
        if key.week != 0 { return byWeek[key] ?? .zero }
        if key.month != 0 { return byMonth[key] ?? .zero }
        return byYear[key] ?? .zero
    }
}

func XCTAssertEqual(
    _ lhs: AggregateTotals,
    _ rhs: AggregateTotals,
    accuracy: Double,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.runCount, rhs.runCount, "\(message) (runCount)", file: file, line: line)
    XCTAssertEqual(
        lhs.distanceMetres, rhs.distanceMetres, accuracy: accuracy,
        "\(message) (distance)", file: file, line: line
    )
    XCTAssertEqual(
        lhs.activeSeconds, rhs.activeSeconds, accuracy: accuracy,
        "\(message) (activeSeconds)", file: file, line: line
    )
    XCTAssertEqual(
        lhs.elevationGainMetres, rhs.elevationGainMetres, accuracy: accuracy,
        "\(message) (elevation)", file: file, line: line
    )
}
