import XCTest

@testable import PhoneMotion

final class CalibratorTests: XCTestCase {

    private let config = CalibrationConfiguration()

    private func observation(
        reference: Double, unscaled: Double, spm: Double = 170
    ) -> CalibrationObservation {
        CalibrationObservation(
            referenceMetres: reference, unscaledSum: unscaled, meanStepsPerMinute: spm)
    }

    // MARK: - Bootstrap

    /// ADR-S-06 — the first observation is taken **whole**. Averaging toward a nonexistent
    /// prior is meaningless, and the alternative (a fabricated starting value) is what
    /// that ADR exists to forbid.
    func testTheFirstObservationIsTakenWhole() {
        var calibrator = Calibrator(configuration: config)
        XCTAssertFalse(calibrator.isCalibrated)
        calibrator.apply(observation(reference: 300, unscaled: 200))
        XCTAssertTrue(calibrator.isCalibrated)
        XCTAssertEqual(calibrator.state.scale ?? .nan, 1.5, accuracy: 1e-12)
    }

    /// Every subsequent observation goes through the cap, so no single window can move
    /// the model far. This is the difference between a calibrator and an amplifier of
    /// GPS noise.
    func testASubsequentObservationIsCapped() {
        var calibrator = Calibrator(configuration: config)
        calibrator.apply(observation(reference: 100, unscaled: 100))  // scale 1.0
        // A window claiming the scale should be 3.0 — a 200% jump.
        calibrator.apply(observation(reference: 300, unscaled: 100))
        let maximum = 1.0 + config.maximumWindowDeltaFraction
        XCTAssertLessThanOrEqual(calibrator.state.scale ?? .nan, maximum + 1e-12)
        XCTAssertGreaterThan(calibrator.state.scale ?? 0, 1.0)
    }

    /// AC-FR-S-C-2-4 — bounded movement holds for *any* sequence, including adversarial
    /// ones, so it is asserted over many alternating extremes rather than one case.
    func testNoObservationSequenceMovesTheScaleMoreThanTheCapPerWindow() {
        var calibrator = Calibrator(configuration: config)
        calibrator.apply(observation(reference: 100, unscaled: 100))
        var previous = calibrator.state.scale ?? 1
        var rng = SplitMix64(seed: 4242)
        for _ in 0..<500 {
            // Wildly contradictory windows, alternating between absurd extremes.
            let unscaled = 1 + rng.nextUnit() * 500
            calibrator.apply(observation(reference: 100, unscaled: unscaled))
            let current = calibrator.state.scale ?? .nan
            XCTAssertLessThanOrEqual(
                abs(current - previous),
                config.maximumWindowDeltaFraction * previous + 1e-9,
                "a single window moved the scale by more than the cap")
            previous = current
        }
    }

    // MARK: - Bands

    /// AC-FR-S-C-2-5 — a band falls back to the global scale until it has evidence of its
    /// own. A gain fitted from one window would be a worse estimate than the global one
    /// it replaced.
    func testABandFallsBackToTheGlobalScaleUntilItHasEnoughEvidence() {
        var calibrator = Calibrator(configuration: config)
        calibrator.apply(observation(reference: 100, unscaled: 100, spm: 170))
        XCTAssertEqual(calibrator.gain(forStepsPerMinute: 170), 1.0, accuracy: 1e-12)

        for _ in 0..<config.minimumObservationsPerBand {
            calibrator.apply(observation(reference: 120, unscaled: 100, spm: 170))
        }
        XCTAssertNotEqual(calibrator.gain(forStepsPerMinute: 170), 1.0)
        // A band nobody has run in stays at the global scale.
        XCTAssertEqual(calibrator.gain(forStepsPerMinute: 220), 1.0, accuracy: 1e-12)
    }

    func testBandsAreKeyedByCadence() {
        let calibrator = Calibrator(configuration: config)
        XCTAssertNotEqual(
            calibrator.band(forStepsPerMinute: 155), calibrator.band(forStepsPerMinute: 185))
        XCTAssertEqual(
            calibrator.band(forStepsPerMinute: 170), calibrator.band(forStepsPerMinute: 175),
            "10 spm bands must group 170 and 175")
    }

    /// AC-FR-S-C-2-3 — a fit outside the bounds is evidence of a bad window, not of an
    /// unusual runner.
    func testBandGainsStayInsideTheirBoundsUnderAnyObservationSequence() {
        var calibrator = Calibrator(configuration: config)
        calibrator.apply(observation(reference: 100, unscaled: 100, spm: 170))
        var rng = SplitMix64(seed: 7)
        for _ in 0..<400 {
            let reference = 1 + rng.nextUnit() * 10_000
            calibrator.apply(observation(reference: reference, unscaled: 100, spm: 170))
            let gain = calibrator.gain(forStepsPerMinute: 170)
            XCTAssertGreaterThanOrEqual(gain, config.minimumGain - 1e-9)
            XCTAssertLessThanOrEqual(gain, config.maximumGain + 1e-9)
        }
    }

    // MARK: - Rejection

    func testDegenerateObservationsAreRejected() {
        var calibrator = Calibrator(configuration: config)
        XCTAssertFalse(calibrator.apply(observation(reference: 0, unscaled: 100)))
        XCTAssertFalse(calibrator.apply(observation(reference: 100, unscaled: 0)))
        XCTAssertFalse(calibrator.apply(observation(reference: .nan, unscaled: 100)))
        XCTAssertFalse(calibrator.apply(observation(reference: 100, unscaled: .infinity)))
        XCTAssertFalse(calibrator.isCalibrated, "no bad observation may bootstrap the scale")
    }

    // MARK: - Convergence and persistence

    /// AC-FR-S-C-2-6 — convergence is a reportable fact, because a run recorded before it
    /// must be marked lower-confidence.
    func testConvergenceRequiresTheConfiguredNumberOfObservations() {
        var calibrator = Calibrator(configuration: config)
        for i in 0..<config.convergenceObservations {
            XCTAssertFalse(calibrator.isConverged, "converged after only \(i) observations")
            calibrator.apply(observation(reference: 100, unscaled: 100))
        }
        XCTAssertTrue(calibrator.isConverged)
    }

    /// AC-FR-S-C-2-2 — the state persists between runs, so a runner's second run starts
    /// calibrated.
    func testStateRoundTripsThroughJSON() throws {
        var calibrator = Calibrator(configuration: config)
        for _ in 0..<5 {
            calibrator.apply(observation(reference: 130, unscaled: 100, spm: 168))
        }
        let data = try JSONEncoder().encode(calibrator.state)
        let decoded = try JSONDecoder().decode(CalibrationState.self, from: data)
        XCTAssertEqual(decoded, calibrator.state)

        let restored = Calibrator(configuration: config, state: decoded)
        XCTAssertTrue(restored.isCalibrated)
        XCTAssertEqual(restored.state.scale, calibrator.state.scale)
    }

    func testResetClearsEverything() {
        var calibrator = Calibrator(configuration: config)
        calibrator.apply(observation(reference: 100, unscaled: 100))
        calibrator.reset()
        XCTAssertFalse(calibrator.isCalibrated)
        XCTAssertNil(calibrator.state.scale)
        XCTAssertTrue(calibrator.state.bands.isEmpty)
    }
}
