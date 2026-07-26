import XCTest
import ORModels
import ORStats

/// The whole-run derivation shared by both watch tiers and the phone's backfill.
///
/// Tested here rather than only from the app packages because it is `Core` judgement logic: three
/// call sites depend on it agreeing with itself, and a disagreement would surface as a run whose
/// lifetime totals shift depending on which path produced it.
final class RunSummaryBuilderTests: XCTestCase {

    private func sample(
        at second: Double,
        distance: Double,
        altitude: Double? = 0,
        heartRate: Double? = 150,
        zone: PaceZone = .onTarget
    ) -> RunSample {
        RunSample(
            timestamp: second,
            cumulativeDistance: distance,
            rollingPace: Pace(secondsPerMetre: 0.3),
            heartRate: heartRate,
            relativeAltitude: altitude,
            smoothedGrade: 0,
            gradeFactor: .identity,
            rawTarget: nil,
            effectiveTarget: nil,
            zone: zone
        )
    }

    // MARK: - Elevation gain

    /// The reason the threshold exists: a naive sum of positive deltas integrates altimeter jitter
    /// into hundreds of metres of climb that never happened.
    ///
    /// This series is dead flat with ±0.4 m of noise — well inside the 1 m threshold — over 3 000
    /// samples. A delta-summing implementation reports several hundred metres of climb; the correct
    /// answer is zero.
    func testAltimeterJitterOnFlatGroundContributesNoClimb() {
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<3_000).map { index in
            sample(
                at: Double(index),
                distance: Double(index) * 3,
                altitude: Double.random(in: -0.4...0.4, using: &generator)
            )
        }

        let gain = RunSummaryBuilder.elevationGain(samples)
        XCTAssertEqual(
            gain, 0, accuracy: 1.5,
            "flat ground with sensor noise reported \(gain) m of climb"
        )
    }

    /// A real climb is credited in full.
    func testASustainedClimbIsCreditedInFull() {
        let samples = (0..<100).map { index in
            sample(at: Double(index), distance: Double(index) * 3, altitude: Double(index))
        }
        XCTAssertEqual(RunSummaryBuilder.elevationGain(samples), 99, accuracy: 1)
    }

    /// Descents are not credited, and do not cancel earlier climb.
    func testADescentNeitherCountsNorCancelsPriorClimb() {
        var samples = (0..<50).map { index in
            sample(at: Double(index), distance: Double(index) * 3, altitude: Double(index))
        }
        samples += (0..<50).map { index in
            sample(
                at: Double(50 + index),
                distance: Double(50 + index) * 3,
                altitude: 49 - Double(index)
            )
        }

        XCTAssertEqual(
            RunSummaryBuilder.elevationGain(samples), 49, accuracy: 1,
            "the descent altered the climb total"
        )
    }

    /// Two hills separated by a descent both count — the reference has to track downward, or the
    /// second climb is measured from the first summit and largely lost.
    func testTwoHillsSeparatedByADescentBothCount() {
        var altitude = 0.0
        var samples: [RunSample] = []
        var second = 0.0

        func move(to target: Double) {
            let step: Double = altitude < target ? 1 : -1
            while abs(altitude - target) > 0.5 {
                altitude += step
                samples.append(sample(at: second, distance: second * 3, altitude: altitude))
                second += 1
            }
        }

        move(to: 40)    // up 40
        move(to: 0)     // back down
        move(to: 30)    // up 30

        XCTAssertEqual(
            RunSummaryBuilder.elevationGain(samples), 70, accuracy: 2,
            "the second climb was measured from the first summit rather than from the valley"
        )
    }

    /// A run with no altimeter reports zero climb rather than deriving a profile from missing data.
    func testAbsentAltitudeReportsNoClimbRatherThanTreatingNilAsGroundLevel() {
        let samples = (0..<100).map { index in
            sample(at: Double(index), distance: Double(index) * 3, altitude: nil)
        }
        XCTAssertEqual(RunSummaryBuilder.elevationGain(samples), 0)
    }

    /// Non-finite readings are skipped rather than poisoning the total.
    func testNonFiniteAltitudesAreIgnored() {
        var samples = (0..<20).map { index in
            sample(at: Double(index), distance: Double(index) * 3, altitude: Double(index))
        }
        samples.append(sample(at: 20, distance: 60, altitude: .nan))
        samples.append(sample(at: 21, distance: 63, altitude: 25))

        let gain = RunSummaryBuilder.elevationGain(samples)
        XCTAssertTrue(gain.isFinite, "a NaN altitude produced a NaN total")
        XCTAssertEqual(gain, 25, accuracy: 1)
    }

    /// The threshold is configurable and actually read (NFR-21).
    func testTheThresholdIsReadFromConfiguration() {
        // A staircase of 0.6 m steps: below the 1 m default, above a 0.5 m setting.
        let samples = (0..<100).map { index in
            sample(
                at: Double(index), distance: Double(index) * 3, altitude: Double(index) * 0.6
            )
        }

        var permissive = StatsConfiguration()
        permissive.elevationGainThresholdMetres = 0.5

        XCTAssertGreaterThan(
            RunSummaryBuilder.elevationGain(samples, config: permissive), 50,
            "a lower threshold did not admit more climb"
        )
    }

    // MARK: - Distance

    /// A run whose first usable fix arrives late opens at a non-zero cumulative reading, and the
    /// distance covered *during the recording* is the difference — not the final value.
    func testDistanceIsMeasuredFromTheFirstSampleNotFromZero() {
        let samples = (0..<100).map { index in
            sample(at: Double(index), distance: 500 + Double(index) * 3)
        }
        XCTAssertEqual(RunSummaryBuilder.distanceCovered(samples), 297, accuracy: 1e-9)
    }

    func testAnEmptySeriesHasNoDistanceRatherThanCrashing() {
        XCTAssertEqual(RunSummaryBuilder.distanceCovered([]), 0)
        XCTAssertEqual(RunSummaryBuilder.elevationGain([]), 0)
    }

    // MARK: - The whole summary

    /// Active time comes from the caller, not from the sample timestamps — those advance while the
    /// run is paused, so deriving it would credit every pause as running time.
    func testActiveTimeIsTakenFromTheCallerNotDerivedFromTimestamps() {
        // 600 s of samples, but only 500 s of them active.
        let samples = (0..<600).map { index in
            sample(at: Double(index), distance: Double(index) * 3)
        }
        let timeline = ZoneTimeline.encode(zones: samples.map(\.zone))

        let summary = RunSummaryBuilder.build(
            samples: samples, activeSeconds: 500, zoneTimeline: timeline
        )

        XCTAssertEqual(summary.activeSeconds, 500)
        // And the average pace uses that figure, not the elapsed span.
        XCTAssertEqual(
            summary.averagePace?.secondsPerMetre ?? 0,
            500 / summary.distanceMetres, accuracy: 1e-9
        )
    }

    func testHeartRateStatisticsIgnoreMissingAndZeroReadings() {
        var samples = (0..<10).map { index in
            sample(at: Double(index), distance: Double(index) * 3, heartRate: 150)
        }
        samples.append(sample(at: 10, distance: 30, heartRate: nil))
        samples.append(sample(at: 11, distance: 33, heartRate: 0))
        samples.append(sample(at: 12, distance: 36, heartRate: 180))

        let timeline = ZoneTimeline.encode(zones: samples.map(\.zone))
        let summary = RunSummaryBuilder.build(
            samples: samples, activeSeconds: 12, zoneTimeline: timeline
        )

        XCTAssertEqual(summary.maxHeartRate, 180)
        // 10 × 150 plus one 180, over 11 valid readings — a 0 counted as a reading would drag this
        // to about 138.
        XCTAssertEqual(summary.averageHeartRate ?? 0, (1_500 + 180) / 11, accuracy: 1e-9)
    }

    func testARunWithNoHeartRateDataReportsNoneRatherThanZero() {
        let samples = (0..<10).map { index in
            sample(at: Double(index), distance: Double(index) * 3, heartRate: nil)
        }
        let summary = RunSummaryBuilder.build(
            samples: samples, activeSeconds: 10,
            zoneTimeline: ZoneTimeline.encode(zones: samples.map(\.zone))
        )

        XCTAssertNil(summary.averageHeartRate)
        XCTAssertNil(summary.maxHeartRate)
    }

    /// Time in zone comes from the timeline, so the summary and the phone's chart cannot disagree.
    func testTimeInZoneComesFromTheTimeline() {
        let zones: [PaceZone] = Array(repeating: .onTarget, count: 60)
            + Array(repeating: .tooFast, count: 30)
        let samples = zones.enumerated().map { index, zone in
            sample(at: Double(index), distance: Double(index) * 3, zone: zone)
        }
        let timeline = ZoneTimeline.encode(zones: zones)

        let summary = RunSummaryBuilder.build(
            samples: samples, activeSeconds: 90, zoneTimeline: timeline
        )

        XCTAssertEqual(summary.timeInZoneSeconds, ZoneTimeline.timeInZone(timeline))
        XCTAssertEqual(summary.timeInZoneSeconds[PaceZone.onTarget.rawValue], 60, accuracy: 1e-9)
        XCTAssertEqual(summary.timeInZoneSeconds[PaceZone.tooFast.rawValue], 30, accuracy: 1e-9)
    }
}
