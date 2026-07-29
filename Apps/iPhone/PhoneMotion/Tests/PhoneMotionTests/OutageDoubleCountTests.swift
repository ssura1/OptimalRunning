import XCTest

@testable import PhoneMotion

/// S-060 — an outage must be billed once.
///
/// Found in the 4.3 mi validation run, where the fused distance came out **worse than
/// either leg on its own** (+3.94%, against +2.65% for GNSS and +1.13% for motion). A
/// fusion that is worse than both its inputs is not a tuning problem, it is an accounting
/// error, and the run made it visible because six laps of one loop give six independent
/// readings of the same distance.
///
/// Two distinct routes produce it, and only one is fixed by correct timestamps:
///
/// 1. The recorder stamped every fix in a delivered batch with *now*, collapsing a 20 s
///    outage to a single instant. `maxPlausibleSpeedMetresPerSecond` catches that, since
///    zero elapsed time admits zero distance.
/// 2. With timestamps corrected, CoreLocation still replays the backlog, and those fixes
///    carry real times from *before* the handover — so their deltas are individually
///    plausible and the bound does not bind. Only `motionCoveredUntil` catches this one.
///
/// The second case is the one these tests exist for: it is what the first fix would have
/// left behind, and it would have been invisible until the next field run.
final class OutageDoubleCountTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default

    private func makeFusion() -> DistanceFusion {
        DistanceFusion(
            configuration: config.fusion,
            calibration: config.calibration,
            calibrator: Calibrator(
                configuration: config.calibration, state: CalibrationState()))
    }

    private func fix(at t: TimeInterval, cumulative: Double) -> LocationFix {
        LocationFix(
            timestamp: t,
            cumulativeDistanceMetres: cumulative,
            horizontalAccuracy: 4,
            speedMetresPerSecond: 3)
    }

    /// The backlog case: fixes with honest timestamps predating the handover.
    ///
    /// Timeline: GNSS runs to t=10 (30 m). It then stops. The fusion notices at
    /// t=10+dropout and runs on the motion leg to t=40, covering that stretch. At t=40
    /// CoreLocation delivers everything it buffered — fixes at t=11…40 whose cumulative
    /// spans the same 90 m the motion leg just accounted for.
    func testABufferedBacklogDoesNotRebillDistanceTheMotionLegCovered() {
        var fusion = makeFusion()
        // Live GNSS: 3 m/s to t = 10 s.
        for step in 0...10 {
            fusion.ingest(fix: fix(at: Double(step), cumulative: Double(step) * 3))
            fusion.tick(at: Double(step))
        }
        let afterLiveGNSS = fusion.cumulativeMetres

        // Outage. The fusion hands over and the motion leg carries the run to t = 40.
        for step in 11...40 {
            fusion.tick(at: Double(step))
            fusion.ingestStep(
                metres: 1.0, unscaled: 1.0, stepsPerMinute: 180, cadenceIsConfident: true)
            fusion.ingestStep(
                metres: 1.0, unscaled: 1.0, stepsPerMinute: 180, cadenceIsConfident: true)
            fusion.ingestStep(
                metres: 1.0, unscaled: 1.0, stepsPerMinute: 180, cadenceIsConfident: true)
        }
        let afterOutage = fusion.cumulativeMetres
        XCTAssertGreaterThan(
            afterOutage, afterLiveGNSS, "precondition: the motion leg carried the outage")

        // GNSS returns and replays the backlog with honest timestamps.
        for step in 11...40 {
            fusion.ingest(fix: fix(at: Double(step), cumulative: Double(step) * 3))
        }
        let afterBacklog = fusion.cumulativeMetres

        XCTAssertEqual(
            afterBacklog, afterOutage, accuracy: 0.001,
            "the backlog re-billed \(afterBacklog - afterOutage) m the motion leg had "
                + "already counted")
    }

    /// The collapsed-timestamp case, as the recorded traces actually contain it.
    ///
    /// Nineteen fixes bearing one timestamp and 50.9 m between them is what the 4.3 mi
    /// trace holds at t=1126.071. No elapsed time can justify any of that distance.
    func testFixesSharingATimestampContributeNoDistance() {
        var fusion = makeFusion()
        for step in 0...10 {
            fusion.ingest(fix: fix(at: Double(step), cumulative: Double(step) * 3))
            fusion.tick(at: Double(step))
        }
        let before = fusion.cumulativeMetres

        // The backlog, all stamped at the delivery instant.
        for index in 1...19 {
            fusion.ingest(fix: fix(at: 10.0, cumulative: 30 + Double(index) * 2.7))
        }

        XCTAssertEqual(
            fusion.cumulativeMetres, before, accuracy: 0.001,
            "fixes sharing an instant contributed \(fusion.cumulativeMetres - before) m")
    }

    /// The bound must not touch ordinary running.
    ///
    /// The counterpart that keeps the fix from being a false negative: at 3 m/s every
    /// delta is far inside the 12 m/s ceiling and no fix predates a handover, so the
    /// fused total must be exactly the GNSS total.
    func testNormalGNSSIsUnaffected() {
        var fusion = makeFusion()
        for step in 0...300 {
            fusion.ingest(fix: fix(at: Double(step), cumulative: Double(step) * 3))
            fusion.tick(at: Double(step))
        }
        XCTAssertEqual(
            fusion.cumulativeMetres, 900, accuracy: 0.5,
            "the guard suppressed distance during ordinary running")
    }
}
