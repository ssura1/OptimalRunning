import XCTest

import ORModels

@testable import PhoneMotion

/// Invariants that must hold for *all* inputs, not just the ones someone thought of
/// (standalone/design.md §10.2).
///
/// The same discipline as the core track's `PropertyTests`: hand-rolled generators, no
/// external dependency, and **seeded** so a failure reproduces — a failure that cannot be
/// reproduced is not a finding, it is a rumour.
///
/// Every property here is structural. None of them asserts an accuracy percentage,
/// because the inputs are generated and a percentage measured against a generated input
/// would be measuring the generator (CON-S-7). Accuracy lives in the trace goldens, and
/// `Tools/check-motion-fixtures.sh` enforces the separation.
final class PropertyTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default
    private let cases = 500

    // MARK: - Step length

    /// Property: monotonic in amplitude, at fixed height and cadence.
    func testStepLengthIsMonotonicInAmplitudeForAnyParameters() {
        var rng = SplitMix64(seed: 0xA11CE)
        for _ in 0..<cases {
            let height = 1.4 + rng.nextUnit() * 0.7
            let frequency = 2.0 + rng.nextUnit() * 1.5
            let scale = 0.1 + rng.nextUnit() * 2
            let model = StepLengthModel(
                configuration: config.stepLength, runnerHeightMetres: height)
            var previous = -Double.infinity
            for amplitude in stride(from: 2.0, through: 80.0, by: 2.0) {
                guard
                    let estimate = model.stepLength(
                        amplitude: amplitude, stepFrequencyHz: frequency,
                        scale: scale, gain: 1)
                else { continue }
                XCTAssertGreaterThanOrEqual(estimate.metres, previous - 1e-12)
                previous = estimate.metres
            }
        }
    }

    /// Property: the estimate is always inside the clamp, or absent — for **all** finite
    /// and non-finite inputs, including the ones a real sensor produces on a bad day.
    func testStepLengthIsAlwaysBoundedOrAbsent() {
        var rng = SplitMix64(seed: 0xB01D)
        let model = StepLengthModel(configuration: config.stepLength, runnerHeightMetres: 1.75)
        let hostile: [Double] = [.nan, .infinity, -.infinity, 0, -1, 1e300, 1e-300]
        for _ in 0..<cases {
            let amplitude = hostile.randomElement(using: &rng) ?? rng.nextUnit() * 1e6
            let frequency = hostile.randomElement(using: &rng) ?? rng.nextUnit() * 100
            let scale = hostile.randomElement(using: &rng) ?? rng.nextUnit() * 1e6
            guard
                let estimate = model.stepLength(
                    amplitude: amplitude, stepFrequencyHz: frequency, scale: scale, gain: 1)
            else { continue }
            XCTAssertTrue(estimate.metres.isFinite)
            XCTAssertGreaterThanOrEqual(estimate.metres, config.stepLength.minimumMetres - 1e-9)
            XCTAssertLessThanOrEqual(estimate.metres, config.stepLength.maximumMetres + 1e-9)
        }
    }

    // MARK: - Calibration

    /// Property: the gain stays inside its bounds under any observation sequence.
    func testCalibrationGainsAreAlwaysBounded() {
        var rng = SplitMix64(seed: 0xCAFE)
        for _ in 0..<20 {
            var calibrator = Calibrator(configuration: config.calibration)
            for _ in 0..<100 {
                calibrator.apply(CalibrationObservation(
                    referenceMetres: rng.nextUnit() * 5_000,
                    unscaledSum: 0.001 + rng.nextUnit() * 500,
                    meanStepsPerMinute: 120 + rng.nextUnit() * 120))
            }
            for band in calibrator.state.bands.values {
                XCTAssertGreaterThanOrEqual(band.gain, config.calibration.minimumGain - 1e-9)
                XCTAssertLessThanOrEqual(band.gain, config.calibration.maximumGain + 1e-9)
            }
        }
    }

    /// Property: after the bootstrap, no single window moves the scale by more than the
    /// cap. This is what stops the calibrator being an amplifier of GPS noise.
    func testNoSingleWindowMovesTheScaleMoreThanTheCap() {
        var rng = SplitMix64(seed: 0xD00D)
        for seed in 0..<20 {
            _ = seed
            var calibrator = Calibrator(configuration: config.calibration)
            calibrator.apply(CalibrationObservation(
                referenceMetres: 100, unscaledSum: 100, meanStepsPerMinute: 170))
            var previous = calibrator.state.scale ?? 1
            for _ in 0..<50 {
                calibrator.apply(CalibrationObservation(
                    referenceMetres: rng.nextUnit() * 10_000,
                    unscaledSum: 0.01 + rng.nextUnit() * 100,
                    meanStepsPerMinute: 170))
                let current = calibrator.state.scale ?? .nan
                XCTAssertLessThanOrEqual(
                    abs(current - previous),
                    config.calibration.maximumWindowDeltaFraction * previous + 1e-9)
                previous = current
            }
        }
    }

    // MARK: - Fusion

    /// Property: fused cumulative distance never decreases, under any interleaving of
    /// fixes, steps and dropouts.
    func testFusedDistanceIsMonotonicUnderAnySourceSequence() {
        var rng = SplitMix64(seed: 0xF00D)
        for _ in 0..<20 {
            var fusion = DistanceFusion(
                configuration: config.fusion,
                calibration: config.calibration,
                calibrator: Calibrator(
                    configuration: config.calibration,
                    state: CalibrationState(scale: 0.55, observationCount: 8)))
            var previous = 0.0
            var gnss = 0.0
            for second in 0..<400 {
                let t = Double(second)
                if rng.nextUnit() < 0.6 {
                    gnss += rng.nextUnit() * 6
                    fusion.ingest(fix: LocationFix(
                        timestamp: t,
                        cumulativeDistanceMetres: gnss,
                        horizontalAccuracy: rng.nextUnit() < 0.2 ? 80 : 6))
                }
                if rng.nextUnit() < 0.9 {
                    fusion.ingestStep(
                        metres: 0.8 + rng.nextUnit() * 1.2,
                        unscaled: 1.5 + rng.nextUnit(),
                        stepsPerMinute: 150 + rng.nextUnit() * 40,
                        cadenceIsConfident: rng.nextUnit() < 0.8)
                }
                fusion.tick(at: t)
                XCTAssertGreaterThanOrEqual(fusion.cumulativeMetres, previous)
                previous = fusion.cumulativeMetres
            }
        }
    }

    /// Property: measured plus estimated always equals the total. If they ever diverge,
    /// the provenance display is lying about where the distance came from.
    func testProvenanceTotalsAlwaysReconcile() {
        var rng = SplitMix64(seed: 0x5EED5)
        for _ in 0..<20 {
            var fusion = DistanceFusion(
                configuration: config.fusion,
                calibration: config.calibration,
                calibrator: Calibrator(
                    configuration: config.calibration,
                    state: CalibrationState(scale: 0.55, observationCount: 8)))
            var gnss = 0.0
            for second in 0..<300 {
                let t = Double(second)
                if rng.nextUnit() < 0.5 {
                    gnss += rng.nextUnit() * 5
                    fusion.ingest(fix: LocationFix(
                        timestamp: t, cumulativeDistanceMetres: gnss, horizontalAccuracy: 5))
                }
                fusion.ingestStep(
                    metres: 1.0, unscaled: 1.8,
                    stepsPerMinute: 170, cadenceIsConfident: true)
                fusion.tick(at: t)
            }
            XCTAssertEqual(
                fusion.measuredMetres + fusion.estimatedMetres,
                fusion.cumulativeMetres, accuracy: 1e-6)
        }
    }

    // MARK: - Detection

    /// Property: two step events are never closer than the refractory interval — for any
    /// cadence, amplitude ratio and noise level.
    func testStepEventsNeverViolateTheRefractoryInterval() {
        var rng = SplitMix64(seed: 0x1234)
        for _ in 0..<12 {
            let spm = 120 + rng.nextUnit() * 110
            let signal = SyntheticGaitSignal.make(
                stepsPerMinute: spm,
                duration: 40,
                armSwingAmplitude: 4 + rng.nextUnit() * 25,
                impactAmplitude: 2 + rng.nextUnit() * 20,
                noiseAmplitude: rng.nextUnit() * 10,
                seed: rng.next())
            var estimator = MotionEstimator(configuration: config)
            var events: [StepEvent] = []
            for sample in signal.samples { events.append(contentsOf: estimator.ingest(sample)) }
            let minimumGap = config.cadence.minimumStepPeriod * config.steps.refractoryFraction
            for (a, b) in zip(events, events.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.timestamp - a.timestamp, minimumGap - 1e-9)
            }
        }
    }

    /// Property: reported cadence is inside the physiological range, or absent. Never a
    /// clamped value, which would be a number nobody produced.
    func testCadenceIsAlwaysInRangeOrAbsent() {
        var rng = SplitMix64(seed: 0x9999)
        for _ in 0..<12 {
            let signal = SyntheticGaitSignal.make(
                stepsPerMinute: 60 + rng.nextUnit() * 240,
                duration: 30,
                noiseAmplitude: rng.nextUnit() * 20,
                seed: rng.next())
            var estimator = MotionEstimator(configuration: config)
            for sample in signal.samples {
                _ = estimator.ingest(sample)
                let estimate = estimator.tick(at: sample.timestamp)
                guard let spm = estimate.cadenceStepsPerMinute else { continue }
                XCTAssertGreaterThanOrEqual(spm, config.cadence.minStepsPerMinute - 1e-9)
                XCTAssertLessThanOrEqual(spm, config.cadence.maxStepsPerMinute + 1e-9)
            }
        }
    }

    // MARK: - Determinism

    /// NFR-S-14 — the same input produces bit-identical output, end to end.
    func testTheWholePipelineIsDeterministic() {
        let signal = SyntheticGaitSignal.make(
            stepsPerMinute: 174, duration: 45, noiseAmplitude: 8, seed: 31337)

        func run() -> (Double, Int, [Double]) {
            var estimator = MotionEstimator(
                configuration: config,
                calibration: CalibrationState(scale: 0.55, observationCount: 8))
            var cadences: [Double] = []
            var gnss = 0.0
            for sample in signal.samples {
                _ = estimator.ingest(sample)
                gnss += 0.03
                estimator.ingest(LocationFix(
                    timestamp: sample.timestamp,
                    cumulativeDistanceMetres: gnss,
                    horizontalAccuracy: 5))
                let estimate = estimator.tick(at: sample.timestamp)
                if let spm = estimate.cadenceStepsPerMinute { cadences.append(spm) }
            }
            let final = estimator.tick(at: signal.samples.last?.timestamp ?? 0)
            return (final.cumulativeDistanceMetres, final.stepCount, cadences)
        }

        let first = run()
        let second = run()
        XCTAssertEqual(first.0.bitPattern, second.0.bitPattern, "distance differed bitwise")
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(first.2, second.2)
    }
}

// MARK: - Generator support

extension Array {
    /// Deterministic pick, so a property failure reproduces from its seed.
    fileprivate func randomElement(using rng: inout SplitMix64) -> Element? {
        guard !isEmpty else { return nil }
        return self[Int(rng.next() % UInt64(count))]
    }
}
