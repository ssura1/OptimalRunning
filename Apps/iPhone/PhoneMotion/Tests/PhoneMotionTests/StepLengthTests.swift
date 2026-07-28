import XCTest

@testable import PhoneMotion

final class StepLengthTests: XCTestCase {

    private let config = StepLengthConfiguration()

    private func model(height: Double? = 1.75) -> StepLengthModel {
        StepLengthModel(configuration: config, runnerHeightMetres: height)
    }

    // MARK: - The published relation

    /// Verifies that van Oeveren et al.'s relation was **transcribed correctly**, which
    /// is a different and more important check than verifying the model is accurate.
    ///
    /// `SF [strides/min] = 75.01 + 3.006·v` over 1.64–4.68 m/s. Each row computes the
    /// step frequency a runner at that speed would have, hands *only that* to the prior,
    /// and requires the speed back. A transposed digit anywhere in the constants breaks
    /// this immediately, and nothing else in the suite would notice.
    func testThePriorReproducesTheVanOeverenRelation() {
        let expected: [(speed: Double, stepLength: Double)] = [
            (2.5, 0.909),
            (3.0, 1.071),
            (3.5, 1.228),
            (4.0, 1.379),
            (4.5, 1.525),
        ]
        for row in expected {
            let strideFrequencyPerMinute = 75.01 + 3.006 * row.speed
            let stepFrequency = strideFrequencyPerMinute / 30
            let estimate = model().priorStepLength(stepFrequencyHz: stepFrequency)
            XCTAssertEqual(
                estimate?.metres ?? .nan, row.stepLength, accuracy: 0.001,
                "at \(row.speed) m/s the prior must give \(row.stepLength) m")
        }
    }

    /// The narrowness that makes the prior a last resort, asserted rather than described.
    ///
    /// The relation's entire published speed range maps to 159.9–178.2 spm — an 11%
    /// cadence band covering a 185% speed range. That is the quantitative core of why a
    /// cadence-only model cannot work for running (design.md §5.1).
    func testThePriorsValidityBandIsAsNarrowAsTheRelationMakesIt() {
        let low = StepLengthModel.priorMinimumStepFrequencyHz * 60
        let high = StepLengthModel.priorMaximumStepFrequencyHz * 60
        XCTAssertEqual(low, 159.88, accuracy: 0.01)
        XCTAssertEqual(high, 178.16, accuracy: 0.01)
    }

    /// Below the band the inversion returns a negative speed — at 150 spm, −0.0033 m/s.
    /// A model that extrapolated there would report a plausible-looking step length for
    /// a physically impossible speed.
    func testThePriorDeclinesBelowItsValidityBandRatherThanExtrapolating() {
        for cadence in [100.0, 130.0, 150.0, 158.0] {
            XCTAssertNil(
                model().priorStepLength(stepFrequencyHz: cadence / 60),
                "the prior must decline at \(cadence) spm, where the relation is degenerate")
        }
    }

    /// Above the band, 190 spm implies 6.65 m/s — a 4:02/mi pace for anyone with quick
    /// turnover. Declining is the honest answer.
    func testThePriorDeclinesAboveItsValidityBand() {
        for cadence in [180.0, 190.0, 210.0] {
            XCTAssertNil(model().priorStepLength(stepFrequencyHz: cadence / 60))
        }
    }

    func testThePriorScalesWithHeight() throws {
        let stepFrequency = (75.01 + 3.006 * 3.0) / 30
        let short = try XCTUnwrap(
            model(height: 1.60).priorStepLength(stepFrequencyHz: stepFrequency))
        let tall = try XCTUnwrap(
            model(height: 1.90).priorStepLength(stepFrequencyHz: stepFrequency))
        XCTAssertLessThan(short.metres, tall.metres)
    }

    // MARK: - ADR-S-06: no fabricated scale

    /// The heart of ADR-S-06. With no calibration there is no number, and specifically
    /// **not** a default of 1.0 that would silently ship a fabricated scale.
    func testWithoutAScaleThereIsNoEstimateRatherThanADefault() {
        let result = model().stepLength(
            amplitude: 20, stepFrequencyHz: 2.8, scale: nil, gain: 1.0)
        XCTAssertNil(result)
    }

    func testAZeroOrNegativeScaleIsRefused() {
        XCTAssertNil(model().stepLength(amplitude: 20, stepFrequencyHz: 2.8, scale: 0, gain: 1))
        XCTAssertNil(model().stepLength(amplitude: 20, stepFrequencyHz: 2.8, scale: -1, gain: 1))
    }

    // MARK: - Shape

    /// AC-FR-S-B-4-5 — monotonic in amplitude at fixed height and cadence. This is the
    /// property that makes the amplitude term able to carry the speed response at all.
    func testStepLengthIsMonotonicInAmplitude() {
        let m = model()
        var previous = 0.0
        for amplitude in stride(from: 5.0, through: 60.0, by: 0.5) {
            guard
                let estimate = m.stepLength(
                    amplitude: amplitude, stepFrequencyHz: 2.8, scale: 0.55, gain: 1)
            else { continue }
            XCTAssertGreaterThanOrEqual(
                estimate.metres, previous - 1e-12,
                "step length fell as amplitude rose, at A=\(amplitude)")
            previous = estimate.metres
        }
        XCTAssertGreaterThan(previous, 0)
    }

    /// The dimensionless group is the reason `scale` can be a pure number. If `A/(h·f²)`
    /// ever stopped being dimensionless the scale would silently absorb a unit, and
    /// changing the sample rate would change the distances.
    func testTheAmplitudeGroupIsDimensionless() throws {
        let m = model()
        // Doubling A and doubling h·f² together must leave the group unchanged.
        let base = try XCTUnwrap(m.amplitudeGroup(amplitude: 20, stepFrequencyHz: 2.0))
        let scaled = try XCTUnwrap(
            m.amplitudeGroup(amplitude: 40, stepFrequencyHz: 2.0 * 2.0.squareRoot()))
        XCTAssertEqual(base, scaled, accuracy: 1e-12)
    }

    // MARK: - Bounds

    /// AC-FR-S-B-4-4 — a clamp is flagged, never silent. A run full of clamped steps is a
    /// model that is wrong, and it must be visible as that rather than as a suspiciously
    /// tidy distance.
    func testClampsAreFlagged() throws {
        // A huge scale drives the raw length past the 2.5 m ceiling. At 1.2 Hz a 2.5 m
        // step implies 3 m/s, inside the plausibility band, so this reaches the clamp
        // rather than being rejected as an implausible pace first.
        let estimate = try XCTUnwrap(
            model().stepLength(amplitude: 20, stepFrequencyHz: 1.2, scale: 50, gain: 1))
        XCTAssertTrue(estimate.wasClamped)
        XCTAssertEqual(estimate.metres, 2.5, accuracy: 1e-12)
    }

    /// Non-finite input must produce no estimate rather than propagating.
    func testNonFiniteInputsYieldNoEstimate() {
        let m = model()
        for amplitude in [Double.nan, .infinity, -.infinity, 0, -5] {
            XCTAssertNil(
                m.stepLength(amplitude: amplitude, stepFrequencyHz: 2.8, scale: 0.55, gain: 1),
                "amplitude \(amplitude) must not produce an estimate")
        }
        for frequency in [Double.nan, .infinity, 0, -2.8] {
            XCTAssertNil(
                m.stepLength(amplitude: 20, stepFrequencyHz: frequency, scale: 0.55, gain: 1))
        }
        XCTAssertNil(m.stepLength(amplitude: 20, stepFrequencyHz: 2.8, scale: .nan, gain: 1))
        XCTAssertNil(m.stepLength(amplitude: 20, stepFrequencyHz: 2.8, scale: 0.55, gain: .nan))
    }

    /// An implied pace outside the core engine's own plausibility band is rejected at the
    /// *same* boundary the rolling-pace estimator uses, so the two cannot drift apart.
    func testAnImplausibleImpliedPaceIsRejected() {
        // Scale small enough that the clamped 0.5 m floor at 2.8 Hz still implies
        // 1.4 m/s — 19:10/mi, inside the band — so use a very low cadence to push the
        // implied speed below the 30:00/mi floor instead.
        let tooSlow = model().stepLength(
            amplitude: 1e-6, stepFrequencyHz: 0.2, scale: 0.55, gain: 1)
        XCTAssertNil(tooSlow, "0.5 m at 0.2 Hz is 0.1 m/s — far slower than any run")
    }

    // MARK: - Height

    func testAnUnknownHeightIsMarkedAssumed() {
        XCTAssertTrue(
            StepLengthModel(configuration: config, runnerHeightMetres: nil).heightIsAssumed)
        XCTAssertTrue(
            StepLengthModel(configuration: config, runnerHeightMetres: 0.2).heightIsAssumed,
            "an implausible height is not a height")
        XCTAssertFalse(
            StepLengthModel(configuration: config, runnerHeightMetres: 1.8).heightIsAssumed)
    }
}
