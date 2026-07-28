import XCTest

@testable import PhoneMotion

/// Vector maths, orientation resolution, filtering and autocorrelation — the arithmetic
/// everything downstream stands on.
final class SignalTests: XCTestCase {

    // MARK: - Orientation

    /// AC-FR-S-B-3-3 — the whole reason a hand-held phone is workable at all. A phone
    /// rotated to any attitude must produce the same vertical channel.
    ///
    /// The synthetic generator places a world-frame vertical acceleration into the device
    /// frame through a rotation, so recovering it exactly is a real check of the
    /// projection rather than a circular one: the generator does not know what the
    /// resolver does.
    func testTheVerticalChannelIsInvariantToDeviceAttitude() {
        let resolver = OrientationResolver()
        let axes = [
            Vector3(x: 1, y: 0, z: 0),
            Vector3(x: 0, y: 1, z: 0),
            Vector3(x: 1, y: 1, z: 1),
            Vector3(x: -0.3, y: 0.8, z: 0.5),
        ]
        for axis in axes {
            for degrees in stride(from: 0.0, through: 350.0, by: 10.0) {
                let rotation = Rotation.axisAngle(
                    axis: axis, radians: degrees * .pi / 180)
                let sample = MotionSample(
                    timestamp: 0,
                    userAcceleration: rotation.apply(Vector3(x: 0, y: 0, z: 7.5)),
                    gravity: rotation.apply(Vector3(x: 0, y: 0, z: -9.81)))
                let channels = resolver.resolve(sample)
                XCTAssertEqual(
                    channels?.vertical ?? .nan, 7.5, accuracy: 1e-9,
                    "attitude changed the vertical channel at \(degrees)° about \(axis)")
            }
        }
    }

    /// The sign convention, asserted rather than left to a comment. Every peak-detection
    /// convention downstream assumes positive means up.
    func testUpwardAccelerationIsPositiveOnTheVerticalChannel() {
        let resolver = OrientationResolver()
        let up = MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(x: 0, y: 0, z: 3),
            gravity: Vector3(x: 0, y: 0, z: -9.81))
        XCTAssertEqual(resolver.resolve(up)?.vertical ?? .nan, 3, accuracy: 1e-12)
    }

    /// A degenerate gravity vector must yield *no* vertical channel. Returning zero would
    /// read as a runner standing perfectly still, forever, with no error anywhere.
    func testDegenerateGravityYieldsNoVerticalChannel() {
        let resolver = OrientationResolver()
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(x: 1, y: 2, z: 3),
            gravity: .zero)
        let channels = resolver.resolve(sample)
        XCTAssertNil(channels?.vertical)
        XCTAssertEqual(channels?.magnitude ?? .nan, (1.0 + 4 + 9).squareRoot(), accuracy: 1e-12)
    }

    func testNonFiniteSamplesAreRejected() {
        let resolver = OrientationResolver()
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(x: .nan, y: 0, z: 0),
            gravity: Vector3(x: 0, y: 0, z: -9.81))
        XCTAssertNil(resolver.resolve(sample))
    }

    // MARK: - Filters

    /// Measures a filter's gain at a frequency by driving it with a sinusoid and reading
    /// the steady-state amplitude, discarding the transient.
    private func gain(
        of filter: inout BandPassFilter, atHz frequency: Double, sampleRateHz rate: Double
    ) -> Double {
        var peak = 0.0
        let total = Int(rate * 12)
        let settle = Int(rate * 8)
        for i in 0..<total {
            let t = Double(i) / rate
            let y = filter.process(sin(2 * .pi * frequency * t))
            if i > settle { peak = max(peak, abs(y)) }
        }
        return peak
    }

    private func gain(
        of filter: inout Biquad, atHz frequency: Double, sampleRateHz rate: Double
    ) -> Double {
        var peak = 0.0
        let total = Int(rate * 12)
        let settle = Int(rate * 8)
        for i in 0..<total {
            let t = Double(i) / rate
            let y = filter.process(sin(2 * .pi * frequency * t))
            if i > settle { peak = max(peak, abs(y)) }
        }
        return peak
    }

    /// The defining property of a Butterworth cutoff: −3.01 dB, i.e. 1/√2, exactly there.
    func testButterworthSectionsAreMinusThreeDecibelsAtTheirCutoff() {
        let rate = 100.0
        var lowPass = Biquad.lowPass(cutoffHz: 7, sampleRateHz: rate)
        XCTAssertEqual(
            gain(of: &lowPass, atHz: 7, sampleRateHz: rate),
            1 / 2.0.squareRoot(), accuracy: 0.02)

        var highPass = Biquad.highPass(cutoffHz: 0.7, sampleRateHz: rate)
        XCTAssertEqual(
            gain(of: &highPass, atHz: 0.7, sampleRateHz: rate),
            1 / 2.0.squareRoot(), accuracy: 0.02)
    }

    /// The gait band must pass the step fundamental and reject both DC drift and impact
    /// ringing. **This is the test that would catch transplanting the walking
    /// literature's 3 Hz low-pass**, which sits on top of the running step fundamental.
    func testTheGaitBandPassesRunningStepFrequenciesAndRejectsTheImpactBand() {
        let rate = 100.0
        let config = MotionFilterConfiguration()

        for frequency in [1.3, 2.5, 3.0, 3.2] {
            var filter = BandPassFilter(
                lowCutoffHz: config.gaitLowHz,
                highCutoffHz: config.gaitHighHz,
                sampleRateHz: rate)
            let g = gain(of: &filter, atHz: frequency, sampleRateHz: rate)
            XCTAssertGreaterThan(
                g, 0.7,
                "the gait band must pass \(frequency) Hz — a running step fundamental "
                    + "sits at 2.5–3.2 Hz and a 3 Hz low-pass would attenuate it")
        }

        for frequency in [0.05, 20.0, 30.0] {
            var filter = BandPassFilter(
                lowCutoffHz: config.gaitLowHz,
                highCutoffHz: config.gaitHighHz,
                sampleRateHz: rate)
            XCTAssertLessThan(gain(of: &filter, atHz: frequency, sampleRateHz: rate), 0.2)
        }
    }

    func testTheImpactBandRejectsTheArmSwing() {
        let rate = 100.0
        let config = MotionFilterConfiguration()
        var filter = BandPassFilter(
            lowCutoffHz: config.impactLowHz,
            highCutoffHz: config.impactHighHz,
            sampleRateHz: rate)
        // Stride frequency — the arm swing. It must not reach the step detector.
        XCTAssertLessThan(gain(of: &filter, atHz: 1.5, sampleRateHz: rate), 0.15)
    }

    /// A filter that drifts over a long run is a filter that produces a different answer
    /// at minute 60 than at minute 1.
    func testFiltersAreStableOverALongRun() {
        var filter = BandPassFilter(lowCutoffHz: 0.7, highCutoffHz: 7, sampleRateHz: 100)
        var last = 0.0
        for i in 0..<360_000 {
            last = filter.process(sin(2 * .pi * 2.9 * Double(i) / 100))
        }
        XCTAssertTrue(last.isFinite)
        XCTAssertLessThan(abs(last), 2)
    }

    // MARK: - Resampling

    /// AC-FR-S-B-1-3 — timing comes from timestamps, not from an assumed rate.
    func testResamplerPlacesIrregularSamplesOnAUniformGrid() {
        var resampler = UniformResampler(sampleRateHz: 100)
        var times: [TimeInterval] = []
        // Deliberately jittered delivery, including a dropped interval.
        let arrivals: [(TimeInterval, Double)] = [
            (0.000, 0), (0.011, 1), (0.019, 2), (0.041, 4), (0.050, 5),
        ]
        for (t, v) in arrivals {
            for (gridTime, _) in resampler.ingest(timestamp: t, value: v) {
                times.append(gridTime)
            }
        }
        XCTAssertFalse(times.isEmpty)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertEqual(b - a, 0.01, accuracy: 1e-9, "grid spacing must be exactly 1/rate")
        }
    }

    func testResamplerInterpolatesLinearly() {
        var resampler = UniformResampler(sampleRateHz: 10)
        _ = resampler.ingest(timestamp: 0, value: 0)
        let points = resampler.ingest(timestamp: 1.0, value: 10)
        // Grid at 0.0, 0.1, … 1.0 → values 0, 1, … 10.
        XCTAssertEqual(points.first?.1 ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(points.last?.1 ?? .nan, 10, accuracy: 1e-9)
    }

    /// Out-of-order delivery is dropped rather than folded in: a filter cannot un-process
    /// a sample, so rewriting emitted grid points is not an option.
    func testOutOfOrderSamplesAreDropped() {
        var resampler = UniformResampler(sampleRateHz: 100)
        _ = resampler.ingest(timestamp: 0, value: 0)
        _ = resampler.ingest(timestamp: 1.0, value: 1)
        XCTAssertTrue(resampler.ingest(timestamp: 0.5, value: 5).isEmpty)
    }

    // MARK: - Autocorrelation

    /// The parabolic refinement is what makes NFR-S-7 reachable: one sample of lag error
    /// at 180 spm is already 5.4 spm against a ±3 spm bound. A **non-integer** period is
    /// used deliberately — an integer one would pass without any refinement at all.
    func testRecoversANonIntegerPeriodToWellUnderOneSample() {
        let rate = 100.0
        for periodSamples in [33.3, 28.7, 41.9, 37.5] {
            let period = periodSamples / rate
            var correlator = Autocorrelator(
                sampleRateHz: rate, windowSeconds: 5.12,
                minLagSeconds: 0.25, maxLagSeconds: 1.0)
            for i in 0..<Int(rate * 10) {
                correlator.append(sin(2 * .pi * Double(i) / periodSamples))
            }
            let peak = correlator.dominantPeak()
            XCTAssertNotNil(peak, "no peak for a pure sinusoid at \(periodSamples) samples")
            if let peak {
                let error = abs(peak.lag - period) / period
                XCTAssertLessThan(
                    error, 0.003,
                    "period error \(error * 100)% at \(periodSamples) samples — "
                        + "the parabolic refinement is not doing its job")
            }
        }
    }

    func testAConstantSignalHasNoPeak() {
        var correlator = Autocorrelator(
            sampleRateHz: 100, windowSeconds: 5.12, minLagSeconds: 0.25, maxLagSeconds: 1.0)
        for _ in 0..<1024 { correlator.append(1.0) }
        // A constant signal correlates perfectly at every lag, so there is no *local
        // maximum* — which is exactly why the peak search requires one rather than
        // taking the largest value.
        XCTAssertNil(correlator.dominantPeak())
    }

    func testNoPeakBeforeTheWindowIsFull() {
        var correlator = Autocorrelator(
            sampleRateHz: 100, windowSeconds: 5.12, minLagSeconds: 0.25, maxLagSeconds: 1.0)
        for i in 0..<100 { correlator.append(sin(Double(i))) }
        XCTAssertNil(correlator.dominantPeak())
    }
}
