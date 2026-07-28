import XCTest

import ORModels

@testable import PhoneMotion

final class FusionTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default

    private func makeFusion(calibration: CalibrationState = .init()) -> DistanceFusion {
        DistanceFusion(
            configuration: config.fusion,
            calibration: config.calibration,
            calibrator: Calibrator(configuration: config.calibration, state: calibration))
    }

    private func fix(_ t: Double, _ metres: Double, accuracy: Double = 5) -> LocationFix {
        LocationFix(
            timestamp: t, cumulativeDistanceMetres: metres, horizontalAccuracy: accuracy)
    }

    // MARK: - Monotonicity and handover

    /// AC-FR-S-C-1-1 — non-decreasing under every source-switch sequence.
    func testCumulativeDistanceIsMonotonicAcrossSourceSwitches() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 0.55, observationCount: 5))
        var previous = 0.0
        var gnss = 0.0
        for second in 0..<600 {
            let t = Double(second)
            // GNSS present for 100 s, absent for 100 s, repeatedly.
            let hasFix = (second / 100).isMultiple(of: 2)
            if hasFix {
                gnss += 3.0
                fusion.ingest(fix: fix(t, gnss))
            }
            fusion.ingestStep(
                metres: 1.07, unscaled: 1.9, stepsPerMinute: 170, cadenceIsConfident: true)
            fusion.tick(at: t)
            XCTAssertGreaterThanOrEqual(
                fusion.cumulativeMetres, previous,
                "distance went backwards at t=\(t)")
            previous = fusion.cumulativeMetres
        }
        XCTAssertGreaterThan(previous, 0)
    }

    /// AC-FR-S-C-1-4 / NFR-S-12 — a handover moves cumulative distance by at most 5 m.
    ///
    /// The scenario is the one that would break a naive implementation: GNSS vanishes for
    /// three minutes while the runner keeps going, and the first fix afterwards carries a
    /// cumulative that jumped by the whole outage. Accumulating deltas without
    /// re-anchoring would add that outage twice.
    func testAHandoverBackToGNSSDoesNotDoubleCountTheOutage() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 0.55, observationCount: 5))
        // 100 m of GNSS.
        for second in 0...33 {
            fusion.ingest(fix: fix(Double(second), Double(second) * 3))
            fusion.tick(at: Double(second))
        }
        let beforeOutage = fusion.cumulativeMetres

        // Three minutes with no fixes at all; the motion leg carries the run.
        for second in 34...214 {
            fusion.tick(at: Double(second))
            fusion.ingestStep(
                metres: 3.0, unscaled: 5.4, stepsPerMinute: 170, cadenceIsConfident: true)
        }
        let afterOutage = fusion.cumulativeMetres
        XCTAssertGreaterThan(afterOutage, beforeOutage)

        // GNSS returns, its cumulative having advanced by the entire outage.
        let atReturn = fusion.cumulativeMetres
        fusion.ingest(fix: fix(215, 215 * 3))
        fusion.tick(at: 215)
        XCTAssertLessThanOrEqual(
            fusion.cumulativeMetres - atReturn, DistanceFusion.maxSwitchJumpMetres + 1e-9,
            "the handover added the whole outage a second time")
    }

    /// An unusable fix is not evidence of anything — it must neither advance distance nor
    /// reset the dropout timer. Treating a 200 m-accurate fix as "GPS is working" is how
    /// a run keeps reporting confident pace inside a building.
    func testAnInaccurateFixNeitherAdvancesDistanceNorKeepsGNSSAlive() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 0.55, observationCount: 5))
        fusion.ingest(fix: fix(0, 0))
        fusion.tick(at: 0)
        let before = fusion.cumulativeMetres
        for second in 1...30 {
            fusion.ingest(fix: fix(Double(second), Double(second) * 3, accuracy: 200))
            fusion.tick(at: Double(second))
        }
        XCTAssertEqual(fusion.cumulativeMetres, before, accuracy: 1e-9)
        XCTAssertEqual(fusion.source, .motionModel, "the dropout timer must have expired")
    }

    // MARK: - Provenance

    /// AC-FR-S-C-1-5 — measured and estimated metres are tracked separately and sum to
    /// the whole, which is what FR-S-E-2's provenance display reads.
    func testMeasuredAndEstimatedMetresSumToTheTotal() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 0.55, observationCount: 5))
        var gnss = 0.0
        for second in 0..<400 {
            let t = Double(second)
            if second < 200 {
                gnss += 3
                fusion.ingest(fix: fix(t, gnss))
            }
            fusion.tick(at: t)
            fusion.ingestStep(
                metres: 3.0, unscaled: 5.4, stepsPerMinute: 170, cadenceIsConfident: true)
        }
        XCTAssertEqual(
            fusion.measuredMetres + fusion.estimatedMetres,
            fusion.cumulativeMetres, accuracy: 1e-6)
        XCTAssertGreaterThan(fusion.measuredMetres, 0)
        XCTAssertGreaterThan(fusion.estimatedMetres, 0)
    }

    /// The motion leg is computed continuously whether or not it is in use, so a trace
    /// always carries both series for comparison (design.md §6.1).
    func testTheMotionLegAccumulatesEvenWhileGNSSIsPrimary() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 0.55, observationCount: 5))
        for second in 0..<100 {
            fusion.ingest(fix: fix(Double(second), Double(second) * 3))
            fusion.tick(at: Double(second))
            fusion.ingestStep(
                metres: 3.0, unscaled: 5.4, stepsPerMinute: 170, cadenceIsConfident: true)
        }
        XCTAssertEqual(fusion.source, .location)
        XCTAssertEqual(fusion.estimatedMetres, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(fusion.motionOnlyMetres, 0)
    }

    // MARK: - Calibration

    /// ADR-S-06 — the scale is learned from GNSS rather than shipped.
    func testCalibrationBootstrapsFromTheFirstQualifyingWindow() {
        var fusion = makeFusion()
        XCTAssertFalse(fusion.isCalibrated)
        // 150 m of GNSS with a known unscaled sum, so the recovered scale is predictable:
        // 50 steps × 2.0 unscaled = 100; 150 / 100 = 1.5.
        for second in 0..<50 {
            fusion.ingest(fix: fix(Double(second), Double(second + 1) * 3))
            fusion.ingestStep(
                metres: nil, unscaled: 2.0, stepsPerMinute: 170, cadenceIsConfident: true)
            fusion.tick(at: Double(second))
        }
        XCTAssertTrue(fusion.isCalibrated)
        XCTAssertEqual(fusion.scale ?? .nan, 1.5, accuracy: 0.2)
    }

    /// AC-FR-S-C-2-7 — a window whose cadence was not trusted teaches nothing.
    func testAWindowWithoutConfidentCadenceDoesNotCalibrate() {
        var fusion = makeFusion()
        for second in 0..<50 {
            fusion.ingest(fix: fix(Double(second), Double(second + 1) * 3))
            fusion.ingestStep(
                metres: nil, unscaled: 2.0, stepsPerMinute: 170, cadenceIsConfident: false)
            fusion.tick(at: Double(second))
        }
        XCTAssertFalse(fusion.isCalibrated)
    }

    // MARK: - Disagreement

    /// AC-FR-S-C-1-6 and AC-FR-S-C-1-7 — the corrupted-GNSS fixture, in miniature.
    ///
    /// The assertion that matters is the *third* one: GNSS still wins. Letting the weaker
    /// estimator veto the stronger one on disagreement would make the system's accuracy a
    /// function of its worst component.
    func testACorruptedGNSSSegmentIsFlaggedSuspendsCalibrationAndDoesNotOverrideGNSS() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 1.0, observationCount: 5))
        var gnss = 0.0
        // GNSS reports 6 m/s while the motion leg reports 3 m/s — a 100% disagreement,
        // far past the 15% threshold.
        for second in 0..<200 {
            gnss += 6
            fusion.ingest(fix: fix(Double(second), gnss))
            fusion.ingestStep(
                metres: 3.0, unscaled: 3.0, stepsPerMinute: 170, cadenceIsConfident: true)
            fusion.tick(at: Double(second))
        }
        XCTAssertTrue(fusion.flags.contains(.sourceDisagreement))
        XCTAssertEqual(fusion.source, .location, "GNSS must still be preferred")
        XCTAssertEqual(
            fusion.cumulativeMetres, fusion.measuredMetres, accuracy: 1e-6,
            "every metre should have come from GNSS")
    }

    /// The damage a bad window can do is permanent, so the important half of the
    /// disagreement check is that the calibrator stops learning.
    func testCalibrationDoesNotMoveWhileDisagreementIsSuspended() {
        var fusion = makeFusion(calibration: CalibrationState(scale: 1.0, observationCount: 5))
        var gnss = 0.0
        for second in 0..<200 {
            gnss += 6
            fusion.ingest(fix: fix(Double(second), gnss))
            fusion.ingestStep(
                metres: 3.0, unscaled: 3.0, stepsPerMinute: 170, cadenceIsConfident: true)
            fusion.tick(at: Double(second))
        }
        // With a 2× disagreement and no suspension the scale would have been dragged
        // toward 2.0 by the observation. The cap alone allows at most +15% per window, so
        // the check is that it has not moved even that far.
        XCTAssertLessThanOrEqual(fusion.scale ?? .nan, 1.0 + 1e-9)
    }
}
