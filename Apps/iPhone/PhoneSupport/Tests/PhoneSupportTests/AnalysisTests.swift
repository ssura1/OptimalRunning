import XCTest
import ORModels
import ORStats
import SwiftData
@testable import PhoneSupport

/// T-056 … T-060 — the run detail screen's data, checked against Wave 1's recorded traces.
///
/// Every test here goes through the **whole pipeline**: build an envelope from a fixture,
/// compress it, ingest it, read it back from the store, and analyse it. A test that constructed
/// a `RunAnalysis` directly from samples would skip the two places a field can silently vanish —
/// the envelope and the store round-trip — and those are exactly where this wave's risk lives.
final class AnalysisTests: XCTestCase {

    /// Pushes a fixture through sync and storage, returning the analysis of what came back.
    private func analyse(
        _ fixture: String,
        route: [RoutePoint]? = nil
    ) throws -> RunAnalysis {
        let context = ModelContext(try RunStoreContainer.inMemory())
        let built = try FixtureEnvelopes.build(fixture, route: route)

        let outcome = EnvelopeIngestor(context: context)
            .ingest(payload: try SyncPayloadCodec.encode(built.envelope))
        XCTAssertTrue(outcome.isAccepted, "\(fixture) was refused: \(outcome)")

        let record = try XCTUnwrap(
            try RunRepository(context: context).record(for: built.envelope.runID)
        )
        return try RunAnalysis(record: record)
    }

    // MARK: - T-059: splits and the per-rep table

    /// The user-specified case: `intervals-4x1000` must show exactly four work reps with
    /// correct distance, time, pace and heart rate.
    ///
    /// Replayed end to end rather than against a synthetic interval fixture, because a golden
    /// one already exists and its rep boundaries are pinned by committed goldens.
    func testTheFourByThousandFixtureShowsExactlyFourWorkReps() throws {
        let analysis = try analyse("intervals-4x1000")

        XCTAssertTrue(analysis.isStructured)
        let rows = analysis.repRows()
        let work = rows.filter { $0.step.kind == .work }

        XCTAssertEqual(work.count, 4, "expected four work reps, got \(work.count)")

        for (index, row) in work.enumerated() {
            let step = row.step
            XCTAssertEqual(row.label, "WORK \(index + 1)/4", "rep \(index + 1) mislabelled")
            // One-based, as `ResolvedStep.repIndex` declares and `WorkoutPlan.flatten`
            // produces. Asserted against the real resolver's numbering rather than against a
            // hand-built value, which is what let an off-by-one survive in the watch tier.
            XCTAssertEqual(step.repIndex, index + 1)
            XCTAssertEqual(step.repCount, 4)

            // Each closed rep measures 1000 m. The engine ends a rep on the first tick at or
            // past its goal, so a slight overshoot is correct; a shortfall would mean the rep
            // was cut off.
            XCTAssertEqual(
                step.distanceMetres, 1_000, accuracy: 5,
                "rep \(index + 1) measured \(step.distanceMetres) m"
            )
            XCTAssertGreaterThan(step.activeSeconds, 0, "rep \(index + 1) has no duration")

            // Pace must agree with distance ÷ time rather than being carried separately.
            let pace = try XCTUnwrap(step.averagePace, "rep \(index + 1) has no pace")
            XCTAssertEqual(
                pace.secondsPerMetre, step.activeSeconds / step.distanceMetres,
                accuracy: 1e-9, "rep \(index + 1)'s pace disagrees with its distance and time"
            )

            XCTAssertNotNil(step.averageHeartRate, "rep \(index + 1) has no heart rate")
            XCTAssertNotNil(step.maxHeartRate)
            let average = try XCTUnwrap(step.averageHeartRate)
            XCTAssertGreaterThan(average, 60, "rep \(index + 1) heart rate is implausible")
            XCTAssertLessThanOrEqual(average, try XCTUnwrap(step.maxHeartRate))
        }

        // Reps are distinct rather than four copies of one accumulator's state.
        XCTAssertEqual(Set(work.map(\.step.index)).count, 4)
        XCTAssertGreaterThan(
            Set(work.map { Int($0.step.activeSeconds) }).count, 1,
            "all four reps have identical times, which suggests the accumulator is not resetting"
        )
    }

    /// The recovery steps are there too, and the open-goal warm-up and cool-down are not
    /// mislabelled as reps.
    func testTheStructuredTableCoversRecoveriesAndOpenGoalSteps() throws {
        let rows = try analyse("intervals-4x1000").repRows()

        XCTAssertEqual(rows.filter { $0.step.kind == .recovery }.count, 4)
        XCTAssertEqual(rows.filter { $0.step.kind == .warmup }.first?.label, "WARM UP")
        // An open-goal step has no prescribed distance, so it can never be "partial".
        XCTAssertFalse(rows.first { $0.step.kind == .warmup }?.isPartial ?? true)
    }

    /// Per-distance splits respect the unit preference, and the leftover is labelled partial.
    func testSplitsRespectTheUnitPreferenceAndLabelThePartialFinalSplit() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        let total = analysis.summary.distanceMetres

        for unit in [UnitPreference.miles, .kilometres] {
            let splits = analysis.splits(unit: unit)
            XCTAssertFalse(splits.isEmpty, "\(unit) produced no splits")

            let expectedFull = Int(total / unit.metresPerUnit)
            let full = splits.filter { !$0.isPartial }
            XCTAssertEqual(full.count, expectedFull, "\(unit): wrong number of full splits")

            // Full splits are one unit long.
            for split in full {
                XCTAssertEqual(
                    split.distanceMetres, unit.metresPerUnit, accuracy: 1e-6,
                    "\(unit): split \(split.number) is not a full unit"
                )
            }

            // At most one partial, and it is last.
            let partials = splits.filter(\.isPartial)
            XCTAssertLessThanOrEqual(partials.count, 1)
            if let partial = partials.first {
                XCTAssertEqual(partial.number, splits.count, "the partial split is not last")
                XCTAssertLessThan(partial.distanceMetres, unit.metresPerUnit)
            }

            // The splits account for the whole run — the check that catches interpolation
            // that loses or double-counts a fraction of a unit at each boundary.
            XCTAssertEqual(
                splits.reduce(0) { $0 + $1.distanceMetres }, total, accuracy: 1.0,
                "\(unit): splits sum to \(splits.reduce(0) { $0 + $1.distanceMetres }) of \(total) m"
            )
            XCTAssertEqual(
                splits.reduce(0) { $0 + $1.activeSeconds },
                analysis.samples.last!.timestamp - analysis.samples.first!.timestamp,
                accuracy: 1.0,
                "\(unit): split times do not sum to the run's duration"
            )
        }
    }

    /// Miles and kilometres must produce genuinely different splits, not the same numbers
    /// relabelled.
    func testMilesAndKilometresProduceDifferentSplits() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        let miles = analysis.splits(unit: .miles)
        let kilometres = analysis.splits(unit: .kilometres)

        XCTAssertGreaterThan(kilometres.count, miles.count, "a km is shorter than a mile")
        XCTAssertNotEqual(miles.first?.distanceMetres, kilometres.first?.distanceMetres)
    }

    func testSplitPaceAgreesWithDistanceOverTime() throws {
        for split in try analyse("hilly-10k").splits(unit: .kilometres) {
            let pace = try XCTUnwrap(split.averagePace)
            XCTAssertEqual(
                pace.secondsPerMetre, split.activeSeconds / split.distanceMetres,
                accuracy: 1e-9, "split \(split.number)'s pace is inconsistent"
            )
        }
    }

    // MARK: - T-058: time in zone

    /// AC-FR-F-2-4 — percentages sum to 100 ± 0.1, for every fixture.
    func testZonePercentagesSumToOneHundredForEveryFixture() throws {
        for name in FixtureEnvelopes.allNames {
            let shares = try analyse(name).zoneShares()
            let total = shares.reduce(0) { $0 + $1.percentage }
            XCTAssertEqual(total, 100, accuracy: 0.1, "\(name): percentages sum to \(total)")
            XCTAssertEqual(shares.count, PaceZone.allCases.count, "\(name): missing a zone row")
        }
    }

    /// The rounding-error case the requirement is really about: many very short spans, where a
    /// per-row rounding approach accumulates error fastest.
    ///
    /// `boundary-oscillation` is the fixture that hugs a zone boundary, so its timeline is the
    /// most fragmented of the seven. This builds an even harsher case on top — dozens of
    /// one-second spans — to check the arithmetic rather than the fixture's luck.
    func testZonePercentagesSumToOneHundredWithManyVeryShortSpans() throws {
        let record = RunRecord(
            runID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_101),
            runTypeRaw: RunType.tempo.rawValue,
            deviceTierRaw: DeviceTier.modern.rawValue,
            distanceMetres: 300,
            activeSeconds: 101,
            averagePaceSecondsPerMetre: 0.33,
            averageHeartRate: 150,
            maxHeartRate: 160,
            elevationGainMetres: 0,
            timeInZoneSeconds: []
        )

        // 101 spans of one second, cycling through every zone — so no zone divides evenly into
        // the total and every percentage is a repeating decimal.
        let spans = (0..<101).map { index in
            ZoneSpan(
                zone: PaceZone.allCases[index % PaceZone.allCases.count],
                startSeconds: Double(index),
                durationSeconds: 1
            )
        }
        record.zoneTimelineData = try RunEnvelopeCoder.makeEncoder().encode(spans)

        let shares = try RunAnalysis(record: record).zoneShares()
        let total = shares.reduce(0) { $0 + $1.percentage }

        XCTAssertEqual(total, 100, accuracy: 0.1, "percentages sum to \(total)")
        XCTAssertEqual(
            shares.reduce(0) { $0 + $1.seconds }, 101, accuracy: 1e-9,
            "the seconds column does not sum to the timeline's duration"
        )
    }

    /// A degraded record has no timeline. Every share is zero and nothing divides by zero.
    func testADegradedRecordReportsZeroInEveryZoneWithoutDividingByZero() throws {
        let record = RunRecord(
            runID: UUID(),
            startedAt: Date(), endedAt: Date(),
            runTypeRaw: RunType.easy.rawValue, deviceTierRaw: DeviceTier.modern.rawValue,
            distanceMetres: 5_000, activeSeconds: 1_500, averagePaceSecondsPerMetre: 0.3,
            averageHeartRate: 145, maxHeartRate: 160, elevationGainMetres: 0,
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count),
            isDegraded: true
        )

        let analysis = try RunAnalysis(record: record)
        let shares = analysis.zoneShares()

        XCTAssertEqual(shares.count, PaceZone.allCases.count)
        XCTAssertTrue(shares.allSatisfy { $0.percentage == 0 })
        XCTAssertFalse(analysis.hasSamples)
        XCTAssertFalse(analysis.hasElevationData)
        XCTAssertFalse(analysis.hasRoute)
    }

    // MARK: - T-057: elevation and grade

    /// `hilly-10k` must show the grade-adjusted target actually diverging from the raw one.
    func testTheHillyFixtureShowsTheAdjustedTargetDivergingFromTheRawTarget() throws {
        let analysis = try analyse("hilly-10k")

        XCTAssertTrue(analysis.hasElevationData, "the hilly fixture reports no elevation data")
        XCTAssertTrue(analysis.hasGradeAdjustment, "no grade adjustment was applied on hills")

        let series = analysis.elevationSeries(unit: .miles)
        XCTAssertTrue(series.isAvailable)
        XCTAssertFalse(series.elevation.isEmpty)
        XCTAssertFalse(series.rawTarget.isEmpty)
        XCTAssertFalse(series.adjustedTarget.isEmpty)

        // The two target curves must differ somewhere — that divergence *is* the feature.
        let divergences = zip(series.rawTarget, series.adjustedTarget)
            .map { abs($0.y - $1.y) }
        let maximum = try XCTUnwrap(divergences.max())
        XCTAssertGreaterThan(
            maximum, 1.0,
            "the adjusted target never diverged from the raw target by more than \(maximum) s/mi"
        )

        // And the elevation profile actually rises and falls.
        let altitudes = series.elevation.map(\.y)
        let highest = try XCTUnwrap(altitudes.max())
        let lowest = try XCTUnwrap(altitudes.min())
        XCTAssertGreaterThan(
            highest - lowest, 5,
            "the elevation profile is flat for a hilly run"
        )
    }

    /// A run with no altimeter hides the overlay rather than drawing a flat line at zero
    /// (AC-FR-F-2-3). `treadmill-indoor` is flagged `altimeterUnavailable` by the engine.
    func testARunWithoutAltimeterDataHidesTheElevationOverlay() throws {
        let analysis = try analyse("treadmill-indoor")

        XCTAssertTrue(
            analysis.degradations.contains(.altimeterUnavailable),
            "the treadmill fixture is not flagged as lacking an altimeter"
        )
        XCTAssertFalse(analysis.hasElevationData)

        let series = analysis.elevationSeries(unit: .miles)
        XCTAssertFalse(series.isAvailable, "the overlay would render for a run with no altimeter")
        XCTAssertTrue(series.elevation.isEmpty, "a flat line at zero would be drawn")
    }

    /// A flat outdoor run has altitude data but no meaningful adjustment — the overlay shows,
    /// the divergence does not.
    func testAFlatRunShowsElevationButNoGradeDivergence() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        // The rolling fixture is gently undulating; whichever way it falls, the two flags must
        // be consistent with each other rather than contradictory.
        if analysis.hasGradeAdjustment {
            XCTAssertTrue(
                analysis.hasElevationData,
                "grade was adjusted from altitude data the analysis claims does not exist"
            )
        }
    }

    // MARK: - T-056: pace chart

    /// The band is drawn from the run's own configuration snapshot (AC-FR-F-2-1).
    func testThePaceBandComesFromTheRunsConfigurationSnapshotNotTodaysSettings() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        let configuration = try XCTUnwrap(analysis.configuration)
        let band = configuration.band(for: .tempo)

        let series = analysis.paceSeries(axis: .distance, unit: .miles)
        XCTAssertFalse(series.pace.isEmpty)
        XCTAssertFalse(series.target.isEmpty)

        // Every band edge sits at the configured percentage of the target it accompanies.
        for (target, fast) in zip(series.target, series.bandFast) {
            XCTAssertEqual(
                fast.y, target.y * (1 - band.fastNear), accuracy: 1e-6,
                "the fast band edge does not match the snapshot's band"
            )
        }
        for (target, slow) in zip(series.target, series.bandSlow) {
            XCTAssertEqual(slow.y, target.y * (1 + band.slowNear), accuracy: 1e-6)
        }
    }

    /// AC-FR-F-2-8 — no series exceeds the cap, on either axis.
    func testEveryChartSeriesRespectsTheDownsamplingCap() throws {
        for name in FixtureEnvelopes.allNames {
            let analysis = try analyse(name)
            for axis in RunAnalysis.ChartAxis.allCases {
                let series = analysis.paceSeries(axis: axis, unit: .miles, maxPoints: 250)
                XCTAssertLessThanOrEqual(series.pace.count, 250, "\(name)/\(axis) pace")
                XCTAssertLessThanOrEqual(series.target.count, 250, "\(name)/\(axis) target")
                XCTAssertLessThanOrEqual(series.heartRate.count, 250, "\(name)/\(axis) HR")
                XCTAssertLessThanOrEqual(series.bandFast.count, 250, "\(name)/\(axis) band")
            }
        }
    }

    /// The series share x-positions, so pace and heart rate cannot disagree about what happened
    /// at a given distance. Downsampling each independently would break this.
    func testPaceAndHeartRateSeriesShareTheirXPositions() throws {
        let series = try analyse("hilly-10k").paceSeries(unit: .miles, maxPoints: 200)
        let paceX = Set(series.pace.map(\.x))

        for point in series.heartRate {
            XCTAssertTrue(
                paceX.contains(point.x),
                "a heart-rate point sits at \(point.x), where the pace series has no sample"
            )
        }
    }

    func testBothAxesAreAvailableAndDiffer() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        let byDistance = analysis.paceSeries(axis: .distance, unit: .miles)
        let byTime = analysis.paceSeries(axis: .time, unit: .miles)

        XCTAssertFalse(byDistance.pace.isEmpty)
        XCTAssertFalse(byTime.pace.isEmpty)
        XCTAssertNotEqual(
            byDistance.pace.map(\.x), byTime.pace.map(\.x),
            "the distance and time axes produced identical x-values"
        )
    }

    /// Pace on the chart is in the runner's units, so miles and kilometres must differ.
    func testChartPaceIsExpressedInTheRunnersUnits() throws {
        let analysis = try analyse("tempo-5mi-rolling")
        let miles = analysis.paceSeries(unit: .miles).pace.first?.y ?? 0
        let kilometres = analysis.paceSeries(unit: .kilometres).pace.first?.y ?? 0

        XCTAssertGreaterThan(miles, kilometres, "seconds per mile must exceed seconds per km")
        XCTAssertEqual(miles / kilometres, Pace.metresPerMile / 1_000, accuracy: 1e-6)
    }

    // MARK: - T-060: route

    func testTheRouteIsSplitIntoZoneColouredSegments() throws {
        let route = FixtureEnvelopes.syntheticRoute(pointCount: 400)
        let analysis = try analyse("tempo-5mi-rolling", route: route)

        XCTAssertTrue(analysis.hasRoute)
        let segments = analysis.routeSegments()
        XCTAssertEqual(segments.count, route.count - 1, "one segment per adjacent pair")

        // The zones come from the timeline, so early segments are the settling neutral and
        // later ones are judged.
        XCTAssertEqual(segments.first?.zone, .neutral, "the run's opening is not neutral")
        XCTAssertTrue(
            segments.contains { $0.zone != .neutral },
            "no segment was ever assigned a judged zone"
        )
    }

    func testARunWithoutARouteHidesTheMap() throws {
        let analysis = try analyse("treadmill-indoor")
        XCTAssertFalse(analysis.hasRoute)
        XCTAssertTrue(analysis.routeSegments().isEmpty)
    }

    /// A single stray point is not a route — a one-point polyline renders as nothing and would
    /// leave an empty map frame on screen.
    func testASingleRoutePointDoesNotCountAsARoute() throws {
        let analysis = try analyse(
            "tempo-5mi-rolling", route: FixtureEnvelopes.syntheticRoute(pointCount: 1)
        )
        XCTAssertFalse(analysis.hasRoute)
        XCTAssertTrue(analysis.routeSegments().isEmpty)
    }
}
