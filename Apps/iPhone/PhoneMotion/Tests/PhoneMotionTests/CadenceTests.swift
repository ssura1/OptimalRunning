import XCTest

@testable import PhoneMotion

/// Cadence estimation, including the test this whole tier turns on.
final class CadenceTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default

    /// Runs a synthetic signal through the estimation front end and returns the cadence
    /// estimates it produced.
    ///
    /// Deliberately drives the *same* front end `MotionEstimator` uses — resampler,
    /// gait filter, estimator — rather than feeding raw samples straight to the
    /// correlator. A test that skips the filtering would be testing an estimator nobody
    /// runs.
    private func cadences(
        _ signal: SyntheticGaitSignal, configuration: MotionEstimationConfiguration? = nil
    ) -> [CadenceEstimate] {
        let config = configuration ?? self.config
        let rate = config.sampling.nominalHz
        var resampler = UniformResampler(sampleRateHz: rate)
        var gait = BandPassFilter(
            lowCutoffHz: config.filters.gaitLowHz,
            highCutoffHz: config.filters.gaitHighHz,
            sampleRateHz: rate)
        var estimator = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)
        let orientation = OrientationResolver()

        var out: [CadenceEstimate] = []
        for sample in signal.samples {
            guard let channels = orientation.resolve(sample) else { continue }
            for (_, raw) in resampler.ingest(
                timestamp: sample.timestamp, value: channels.vertical ?? 0)
            {
                let filtered = gait.process(raw)
                if let estimate = estimator.append(vertical: filtered, magnitude: abs(raw)) {
                    out.append(estimate)
                }
            }
        }
        return out
    }

    // MARK: - The sweep

    /// AC-FR-S-B-2-5 — the test the published method fails.
    ///
    /// Renaudin et al. resolve the stride-versus-step ambiguity for a swinging hand with
    /// a fixed 1.4 Hz threshold. Running stride frequency crosses 1.4 Hz at **exactly
    /// 168 spm**, so that rule reports half the true cadence for every runner above it —
    /// which is most trained runners. This sweep spans 140–200 spm with an arm-swing
    /// component *larger* than the impact component, which is the configuration that
    /// defeats the threshold, and requires the step rate every time.
    func testResolvesStepRateAcrossTheRunningRangeDespiteADominantArmSwing() {
        for spm in stride(from: 140.0, through: 200.0, by: 1.0) {
            let signal = SyntheticGaitSignal.make(
                stepsPerMinute: spm,
                duration: 30,
                // Arm swing at 1.5× the impact amplitude: the stride-frequency component
                // dominates, exactly as it does in a real hand-held trace.
                armSwingAmplitude: 12,
                impactAmplitude: 8)
            let estimates = cadences(signal)
            guard let last = estimates.last else {
                XCTFail("no cadence estimate at \(spm) spm")
                continue
            }
            XCTAssertEqual(
                last.stepsPerMinute, spm, accuracy: 3,
                "at \(spm) spm the estimator reported \(last.stepsPerMinute) — "
                    + "a factor-of-two error here is the arm swing being read as the step rate")
        }
    }

    /// The same sweep, stated as the specific regression it guards: never half.
    ///
    /// Separated from the accuracy assertion above because the failure modes are
    /// different in kind. Being 4 spm out is a tuning problem; being 50% out is the
    /// algorithm having misidentified what it is looking at, and it deserves a test whose
    /// name says so when it fails.
    func testNeverReportsTheStrideRateAsTheCadence() {
        for spm in stride(from: 140.0, through: 200.0, by: 2.0) {
            let signal = SyntheticGaitSignal.make(
                stepsPerMinute: spm, duration: 30, armSwingAmplitude: 20, impactAmplitude: 4)
            guard let last = cadences(signal).last else { continue }
            XCTAssertGreaterThan(
                last.stepsPerMinute, spm * 0.75,
                "reported \(last.stepsPerMinute) for a \(spm) spm signal — "
                    + "that is the stride rate, not the cadence")
        }
    }

    // MARK: - Range and confidence

    /// AC-FR-S-B-2-3 — out-of-range means no answer, not a clamped one.
    func testReportsNoCadenceRatherThanAnOutOfRangeOne() {
        // 90 spm is a walk, below the configured 120 spm floor. The estimator must
        // decline rather than clamp to 120, which would be a number nobody produced.
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 90, duration: 30)
        for estimate in cadences(signal) {
            XCTAssertGreaterThanOrEqual(estimate.stepsPerMinute, config.cadence.minStepsPerMinute)
            XCTAssertLessThanOrEqual(estimate.stepsPerMinute, config.cadence.maxStepsPerMinute)
        }
    }

    func testAConstantSignalProducesNoCadence() {
        let rate = config.sampling.nominalHz
        var estimator = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)
        var produced: [CadenceEstimate] = []
        for i in 0..<Int(rate * 20) {
            _ = i
            if let estimate = estimator.append(vertical: 0, magnitude: 0) {
                produced.append(estimate)
            }
        }
        XCTAssertTrue(produced.isEmpty, "a flat signal has no period and must yield none")
    }

    /// NFR-S-3 — an estimate within 15 s of the stream starting, so the estimator's own
    /// warm-up does not extend the settling window.
    func testProducesAnEstimateWithinFifteenSeconds() {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 20)
        let rate = config.sampling.nominalHz
        var resampler = UniformResampler(sampleRateHz: rate)
        var gait = BandPassFilter(
            lowCutoffHz: config.filters.gaitLowHz,
            highCutoffHz: config.filters.gaitHighHz,
            sampleRateHz: rate)
        var estimator = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)
        let orientation = OrientationResolver()

        var firstAt: TimeInterval?
        for sample in signal.samples {
            guard let channels = orientation.resolve(sample) else { continue }
            for (time, raw) in resampler.ingest(
                timestamp: sample.timestamp, value: channels.vertical ?? 0)
            {
                let estimate = estimator.append(vertical: gait.process(raw), magnitude: abs(raw))
                if estimate != nil, firstAt == nil { firstAt = time }
            }
        }
        let first = try? XCTUnwrap(firstAt)
        XCTAssertNotNil(first)
        if let first { XCTAssertLessThanOrEqual(first, 15) }
    }

    /// Confidence must actually discriminate, or gating on it is theatre.
    func testConfidenceIsLowerForANoisySignalThanACleanOne() {
        let clean = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 30, noiseAmplitude: 0)
        let noisy = SyntheticGaitSignal.make(
            stepsPerMinute: 176, duration: 30, noiseAmplitude: 25, seed: 99)
        let cleanConfidence = cadences(clean).last?.confidence ?? 0
        let noisyConfidence = cadences(noisy).last?.confidence ?? 0
        XCTAssertGreaterThan(cleanConfidence, noisyConfidence)
    }

    // MARK: - Determinism

    /// NFR-S-14 — the same trace, bit-identical, every time.
    func testIsDeterministic() {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 172, duration: 20, noiseAmplitude: 5)
        let a = cadences(signal).map(\.stepsPerMinute)
        let b = cadences(signal).map(\.stepsPerMinute)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    // MARK: - The disjoint-interval rule, directly

    /// The property design.md §4.3 rests on: the two readings of a lag map to intervals
    /// that touch but never overlap, so a physiological range *determines* the reading.
    ///
    /// Asserted over the configuration rather than over signals, because it is a claim
    /// about the arithmetic and not about any particular gait — and because it is what
    /// `CadenceConfiguration.validate()` enforces.
    func testTheStepAndStrideLagIntervalsAreDisjoint() {
        let cadence = config.cadence
        let stepLow = 60 / cadence.maxStepsPerMinute
        let stepHigh = 60 / cadence.minStepsPerMinute
        let strideLow = 120 / cadence.maxStepsPerMinute
        let strideHigh = 120 / cadence.minStepsPerMinute

        XCTAssertEqual(stepHigh, strideLow, accuracy: 1e-12, "the intervals must meet exactly")
        XCTAssertLessThan(stepLow, stepHigh)
        XCTAssertLessThan(strideLow, strideHigh)
    }

    // MARK: - Stationarity (S-058)

    /// A quiet signal must produce **no** cadence, however periodic it happens to be.
    ///
    /// Found in the field, not here: across thirty seconds of a runner standing motionless
    /// the estimator reported 175–231 spm at confidence up to 0.816 — above
    /// `minimumTrustedConfidence`, so the calibrator would have learned from it. The cause
    /// is that normalised autocorrelation divides out the window's energy and is therefore
    /// blind to amplitude; noise is as periodic as running to a correlator.
    ///
    /// The signal here is a clean sinusoid at a *plausible cadence*, scaled to an amplitude
    /// below the stationary floor. That combination is the point: it is exactly what a
    /// correlator would score highly, so a test using shapeless noise could pass while the
    /// bug survived.
    func testAQuietButPerfectlyPeriodicSignalProducesNoCadence() {
        let rate = config.sampling.nominalHz
        var estimator = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)

        // 0.25 m/s², the gait-band RMS measured while standing still on the bench trace,
        // against a floor of 1.0.
        let amplitude = 0.25 * 2.0.squareRoot()
        let frequency = 180.0 / 60.0
        var produced: [CadenceEstimate] = []
        for index in 0..<Int(rate * 30) {
            let t = Double(index) / rate
            let value = amplitude * sin(2 * .pi * frequency * t)
            if let estimate = estimator.append(vertical: value, magnitude: abs(value)) {
                produced.append(estimate)
            }
        }

        XCTAssertTrue(
            produced.isEmpty,
            "a signal far below the stationary floor produced \(produced.count) cadence "
                + "estimates, the highest at \(produced.map(\.confidence).max() ?? 0) "
                + "confidence — this is the field failure")
        XCTAssertNil(estimator.current)
    }

    /// The gate must not silence real running.
    ///
    /// The counterpart to the test above, and the reason the floor is an absolute value
    /// rather than a relative one: the same waveform at running amplitude must still be
    /// reported, or the fix would have traded a false positive for a false negative.
    func testTheSameWaveformAtRunningAmplitudeIsStillReported() {
        let rate = config.sampling.nominalHz
        var estimator = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)

        // 10.4 m/s² RMS, measured over the running segment of the same trace.
        let amplitude = 10.4 * 2.0.squareRoot()
        let frequency = 180.0 / 60.0
        var produced: [CadenceEstimate] = []
        for index in 0..<Int(rate * 30) {
            let t = Double(index) / rate
            let value = amplitude * sin(2 * .pi * frequency * t)
            if let estimate = estimator.append(vertical: value, magnitude: abs(value)) {
                produced.append(estimate)
            }
        }

        XCTAssertFalse(produced.isEmpty, "running amplitude must still produce cadence")
        let last = try? XCTUnwrap(produced.last)
        XCTAssertEqual(last?.stepsPerMinute ?? 0, 180, accuracy: 3, "±3 spm (NFR-S-7)")
    }

    /// The invariant above only holds while the range spans at most a factor of two, so
    /// a configuration that breaks it must be rejected rather than silently making the
    /// ambiguity unresolvable.
    func testAWiderThanOctaveCadenceRangeIsRejected() {
        var configuration = MotionEstimationConfiguration.default
        configuration.cadence.minStepsPerMinute = 100
        configuration.cadence.maxStepsPerMinute = 240
        XCTAssertThrowsError(try configuration.validate()) { error in
            let described = String(describing: error)
            XCTAssertTrue(
                described.contains("maxStepsPerMinute"),
                "the error must name the field: \(described)")
        }
    }
}
