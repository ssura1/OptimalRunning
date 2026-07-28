import XCTest

import ORModels

@testable import PhoneMotion

final class ConfigurationTests: XCTestCase {

    func testTheDefaultConfigurationValidates() throws {
        try MotionEstimationConfiguration.default.validate()
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(MotionEstimationConfiguration.default)
        let decoded = try JSONDecoder().decode(MotionEstimationConfiguration.self, from: data)
        XCTAssertEqual(decoded, MotionEstimationConfiguration.default)
    }

    /// Each rejection names its field, because a validation failure that does not say
    /// which knob was turned too far has failed at the only job it has.
    func testEachOutOfRangeValueIsRejectedByName() {
        func expect(_ field: String, _ mutate: (inout MotionEstimationConfiguration) -> Void) {
            var configuration = MotionEstimationConfiguration.default
            mutate(&configuration)
            XCTAssertThrowsError(try configuration.validate(), field) { error in
                let described = String(describing: error)
                XCTAssertTrue(
                    described.contains(field),
                    "expected the error to name \(field), got: \(described)")
            }
        }

        expect("sampling.nominalHz") { $0.sampling.nominalHz = 5 }
        expect("sampling.minimumDeliveryFraction") { $0.sampling.minimumDeliveryFraction = 2 }
        expect("cadence.windowSeconds") { $0.cadence.windowSeconds = 0.1 }
        expect("cadence.maxStepsPerMinute") { $0.cadence.maxStepsPerMinute = 400 }
        expect("steps.refractoryFraction") { $0.steps.refractoryFraction = 1.5 }
        expect("stepLength.amplitudeExponent") { $0.stepLength.amplitudeExponent = 0 }
        expect("stepLength.minimumMetres") { $0.stepLength.minimumMetres = 5 }
        expect("calibration.learningRate") { $0.calibration.learningRate = 0 }
        expect("calibration.minimumGain") { $0.calibration.minimumGain = 1.2 }
        expect("fusion.disagreementFraction") { $0.fusion.disagreementFraction = 1.5 }
    }

    /// Nyquist. A cutoff above half the sample rate is not a filter, it is a
    /// misunderstanding — and it produces a plausible-looking useless signal rather than
    /// an error, which is exactly why it is worth a validation rule.
    func testAFilterCutoffAboveNyquistIsRejected() {
        var configuration = MotionEstimationConfiguration.default
        configuration.sampling.nominalHz = 40
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertTrue(String(describing: error).contains("Nyquist"))
        }
    }

    /// The one number this package deliberately duplicates from `Core`, with a test
    /// standing where the coupling would otherwise be silent.
    ///
    /// `PhoneMotion` does not depend on `PaceEngineConfiguration` — it has no business
    /// knowing about pace bands or grade models — so the GNSS accuracy threshold is
    /// restated here. AC-FR-S-C-1-2 requires the two to agree, and duplication without a
    /// test is how two constants named the same thing come to mean different things.
    func testTheGNSSAccuracyThresholdAgreesWithTheCoreEngine() {
        XCTAssertEqual(
            MotionEstimationConfiguration.default.fusion.maxHorizontalAccuracyMetres,
            PaceEngineConfiguration.default.rollingPace.maxHorizontalAccuracyMetres,
            accuracy: 1e-12,
            "the standalone tier must accept exactly the fixes the pace engine accepts "
                + "(AC-FR-A-1-2); if one moved, move the other")
    }

    /// The plausibility band is likewise shared with the core engine's rolling-pace
    /// estimator, expressed through `Pace` rather than as bare seconds-per-metre.
    func testThePlausibilityBandMatchesTheCoreEnginesBounds() {
        XCTAssertEqual(PlausibleRunningPace.fastest.minutesPerMile, 2, accuracy: 1e-9)
        XCTAssertEqual(PlausibleRunningPace.slowest.minutesPerMile, 30, accuracy: 1e-9)

        XCTAssertTrue(PlausibleRunningPace.admits(metresPerSecond: 3.0))
        XCTAssertFalse(PlausibleRunningPace.admits(metresPerSecond: 0.5))
        XCTAssertFalse(PlausibleRunningPace.admits(metresPerSecond: 20))
        XCTAssertFalse(PlausibleRunningPace.admits(metresPerSecond: 0))
        XCTAssertFalse(PlausibleRunningPace.admits(metresPerSecond: .nan))
    }

    /// NFR-S-19 — the handover bound is deliberately *not* configurable, and this test
    /// records that as an intention rather than leaving its absence to look like an
    /// oversight.
    func testTheHandoverBoundIsAConstantAndNotATunable() {
        XCTAssertEqual(DistanceFusion.maxSwitchJumpMetres, 5.0)
    }
}
