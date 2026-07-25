import XCTest
import ORModels
import ORStats

/// T-055 — largest-triangle-three-buckets downsampling (AC-FR-F-2-8, NFR-4).
///
/// The property tests matter more than any single example here. An LTTB implementation that is
/// subtly wrong still returns plausible-looking output for a smooth series; what it gets wrong
/// is the *feature* a runner is looking at — the one sharp surge in an otherwise steady run —
/// and a hand-picked example is unlikely to be the case that exposes it.
final class DownsampleTests: XCTestCase {

    private func ramp(_ count: Int) -> (x: [Double], y: [Double]) {
        let x = (0..<count).map(Double.init)
        let y = x.map { sin($0 / 40) * 30 + 300 }
        return (x, y)
    }

    // MARK: - Properties

    /// Output never exceeds the threshold, for any input length. The property AC-FR-F-2-8 is.
    ///
    /// Swept across lengths that bracket every awkward case: below the threshold, exactly at it,
    /// one either side, and well past — plus thresholds down to the degenerate 2.
    func testOutputNeverExceedsTheThresholdForAnyInputLength() {
        for threshold in [2, 3, 10, 97, 100, 1_000] {
            for count in [0, 1, 2, 3, threshold - 1, threshold, threshold + 1, threshold * 3, 5_400] {
                guard count >= 0 else { continue }
                let (x, y) = ramp(count)
                let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: threshold)

                XCTAssertLessThanOrEqual(
                    indices.count, max(threshold, min(count, 2)),
                    "count=\(count) threshold=\(threshold) produced \(indices.count) points"
                )
                XCTAssertLessThanOrEqual(indices.count, max(count, 0))
            }
        }
    }

    /// First and last points are always retained — the endpoints anchor the axis, and losing
    /// either silently truncates the chart.
    func testFirstAndLastPointsAreAlwaysRetained() {
        for count in [2, 3, 5, 101, 999, 1_000, 1_001, 5_400] {
            for threshold in [2, 10, 500, 1_000] {
                let (x, y) = ramp(count)
                let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: threshold)

                XCTAssertEqual(indices.first, 0, "count=\(count) threshold=\(threshold)")
                XCTAssertEqual(
                    indices.last, count - 1, "count=\(count) threshold=\(threshold)"
                )
            }
        }
    }

    /// Indices come back strictly increasing and in range. A chart fed unsorted indices draws a
    /// line that doubles back on itself.
    func testIndicesAreStrictlyIncreasingAndInRange() {
        let (x, y) = ramp(5_400)
        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000)

        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count, "duplicate indices returned")
        XCTAssertTrue(indices.allSatisfy { $0 >= 0 && $0 < 5_400 })
    }

    /// Randomised lengths and thresholds, because the interesting failures are at boundaries
    /// nobody thought to enumerate.
    func testPropertiesHoldForRandomLengthsAndThresholds() {
        var generator = SystemRandomNumberGenerator()

        for _ in 0..<300 {
            let count = Int.random(in: 0...4_000, using: &generator)
            let threshold = Int.random(in: 2...1_200, using: &generator)
            let x = (0..<count).map(Double.init)
            let y = (0..<count).map { _ in Double.random(in: 0...500, using: &generator) }

            let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: threshold)

            XCTAssertLessThanOrEqual(indices.count, max(threshold, 2))
            XCTAssertLessThanOrEqual(indices.count, max(count, 0))
            XCTAssertEqual(indices, indices.sorted())
            if count >= 2 {
                XCTAssertEqual(indices.first, 0)
                XCTAssertEqual(indices.last, count - 1)
            }
        }
    }

    // MARK: - Peak preservation

    /// A sharp spike buried in flat data must survive.
    ///
    /// This is the failure mode of a naive bucket-average implementation: it returns a smooth,
    /// believable curve with the spike averaged away — deleting exactly the feature a runner
    /// opened the chart to look at. Nothing about the output's shape or length would reveal it.
    func testASharpSpikeInFlatDataSurvivesDownsampling() {
        let count = 5_400
        let spikeIndex = 2_700
        let baseline = 300.0
        let spike = 900.0

        let x = (0..<count).map(Double.init)
        var y = [Double](repeating: baseline, count: count)
        y[spikeIndex] = spike

        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000)
        let kept = indices.map { y[$0] }

        XCTAssertTrue(
            indices.contains(spikeIndex),
            "the spike at index \(spikeIndex) was dropped entirely"
        )
        XCTAssertEqual(
            kept.max(), spike,
            "the peak was smoothed away — max of the output is \(kept.max() ?? 0), not \(spike)"
        )
    }

    /// The same for a trough, since a runner cares about the slowest moment as much as the
    /// fastest.
    func testASharpTroughInFlatDataSurvivesDownsampling() {
        let count = 5_400
        let troughIndex = 1_234
        var y = [Double](repeating: 300, count: count)
        y[troughIndex] = 60

        let x = (0..<count).map(Double.init)
        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000)

        XCTAssertTrue(indices.contains(troughIndex), "the trough was dropped")
        XCTAssertEqual(indices.map { y[$0] }.min(), 60)
    }

    /// Several peaks, spread out, all survive — one preserved peak could be luck.
    func testMultipleSeparatedPeaksAllSurvive() {
        let count = 5_400
        let peakIndices = [200, 1_100, 2_500, 3_900, 5_100]
        var y = [Double](repeating: 300, count: count)
        for (offset, index) in peakIndices.enumerated() {
            y[index] = 700 + Double(offset) * 20
        }

        let x = (0..<count).map(Double.init)
        let indices = Set(Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000))

        for peak in peakIndices {
            XCTAssertTrue(indices.contains(peak), "peak at \(peak) was dropped")
        }
    }

    /// The extremes of a realistic noisy series stay within the retained range, so the chart's
    /// y-axis does not silently shrink.
    func testTheOutputRangeCoversTheInputRange() {
        var generator = SystemRandomNumberGenerator()
        let count = 5_400
        let x = (0..<count).map(Double.init)
        var y = (0..<count).map { index in
            sin(Double(index) / 90) * 40 + 300 + Double.random(in: -3...3, using: &generator)
        }
        y[1_500] = 850
        y[4_200] = 95

        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000)
        let kept = indices.map { y[$0] }

        XCTAssertEqual(kept.max(), y.max(), "the series maximum was lost")
        XCTAssertEqual(kept.min(), y.min(), "the series minimum was lost")
    }

    // MARK: - Degenerate input

    func testEmptyAndSingleAndTwoPointSeries() {
        XCTAssertTrue(Downsample.largestTriangleThreeBuckets(x: [], y: [], threshold: 100).isEmpty)
        XCTAssertEqual(
            Downsample.largestTriangleThreeBuckets(x: [1], y: [2], threshold: 100), [0]
        )
        XCTAssertEqual(
            Downsample.largestTriangleThreeBuckets(x: [1, 2], y: [3, 4], threshold: 100), [0, 1]
        )
    }

    /// A series already inside the threshold is returned untouched — downsampling a 200-point
    /// run to 200 points must not drop or reorder anything.
    func testASeriesWithinTheThresholdIsReturnedIntact() {
        let (x, y) = ramp(200)
        XCTAssertEqual(
            Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000),
            Array(0..<200)
        )
    }

    /// Mismatched column lengths are refused rather than read out of bounds.
    func testMismatchedInputLengthsDoNotCrash() {
        let indices = Downsample.largestTriangleThreeBuckets(
            x: [0, 1, 2], y: [0, 1], threshold: 10
        )
        XCTAssertTrue(indices.allSatisfy { $0 < 2 }, "an index beyond the shorter column")
    }

    /// A constant series is legitimate — a runner holding exactly steady — and must not produce
    /// NaN areas or an empty result.
    func testAConstantSeriesDownsamplesCleanly() {
        let count = 3_000
        let x = (0..<count).map(Double.init)
        let y = [Double](repeating: 300, count: count)

        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 500)

        XCTAssertLessThanOrEqual(indices.count, 500)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, count - 1)
    }

    // MARK: - Cost (NFR-4)

    /// 5 400 points to 1 000 in well under 5 ms.
    ///
    /// A generous bound rather than a tight one: this runs on whatever machine CI provisions, and
    /// a threshold set near the real figure would fail on a loaded runner. The requirement is
    /// that the algorithm is linear, and 5 ms against an observed sub-millisecond cost is enough
    /// margin to catch an accidental quadratic without failing spuriously.
    func testDownsamplingFiveThousandPointsIsFast() {
        let (x, y) = ramp(5_400)

        let start = Date()
        for _ in 0..<10 {
            _ = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1_000)
        }
        let average = Date().timeIntervalSince(start) / 10

        XCTAssertLessThan(average, 0.005, "averaged \(average * 1_000) ms per downsample")
    }

    /// `reduce` returns the points themselves, and agrees with the index form.
    func testReduceAgreesWithTheIndexForm() {
        let (x, y) = ramp(3_000)
        let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 400)
        let reduced = Downsample.reduce(x: x, y: y, threshold: 400)

        XCTAssertEqual(reduced.count, indices.count)
        for (point, index) in zip(reduced, indices) {
            XCTAssertEqual(point.x, x[index])
            XCTAssertEqual(point.y, y[index])
        }
    }
}
