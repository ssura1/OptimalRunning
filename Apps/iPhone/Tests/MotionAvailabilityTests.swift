import CoreMotion
import XCTest

/// S-004 — establishes [CON-S-1](../../../docs/standalone/requirements.md#con-s-1) by
/// measurement rather than by assertion.
///
/// The entire testing strategy of the standalone track rests on the claim that the iOS
/// Simulator has no motion sensors: it is why the estimator lives in a pure package
/// (ADR-S-03), why the capture tool is scheduled before any tuning (S-006), and why every
/// accuracy requirement is marked unvalidated until a recorded trace exists. A claim
/// carrying that much weight should not be a comment.
///
/// **This test passes on both a Simulator and a device**, and deliberately so. A
/// simulator-only assertion (`XCTAssertFalse(isAccelerometerAvailable)`) would fail the
/// moment someone ran the suite on hardware, and would train the next person to delete it.
/// What it asserts instead is the *invariant that matters*: whatever this environment
/// reports, it reports consistently, and the availability flags are the thing to branch on
/// rather than a guess about where the code is running.
final class MotionAvailabilityTests: XCTestCase {

    /// Records what this environment can do, in a form a reader of CI logs can act on.
    func testRecordsMotionSensorAvailabilityForTheRecord() {
        let motion = CMMotionManager()
        let report = """
            motion sensor availability in this test environment:
              deviceMotion:   \(motion.isDeviceMotionAvailable)
              accelerometer:  \(motion.isAccelerometerAvailable)
              gyroscope:      \(motion.isGyroAvailable)
              magnetometer:   \(motion.isMagnetometerAvailable)
              pedometer:      \(CMPedometer.isStepCountingAvailable())
              step counting authorization: \(CMPedometer.authorizationStatus().rawValue)
            """
        print(report)

        // On a Simulator every one of the first three is false, which is CON-S-1. On a
        // device they are true. Both are legitimate; what would not be is the flags
        // disagreeing with each other, because the pipeline reads `isDeviceMotionAvailable`
        // to decide whether a capture can start at all.
        if motion.isDeviceMotionAvailable {
            XCTAssertTrue(
                motion.isAccelerometerAvailable && motion.isGyroAvailable,
                "device motion is fused from the accelerometer and gyroscope; it cannot be "
                    + "available while they are not")
        }
    }

    /// The behaviour the capture tool depends on: asking for updates where there is no
    /// sensor must not crash, and must not silently appear to succeed.
    ///
    /// This is the failure mode CON-S-1 actually produces in practice — not an error
    /// dialog, but a capture that runs happily and records nothing, which is the worst
    /// possible way to discover the constraint (from a run you cannot repeat).
    func testStartingUpdatesWhereThereIsNoSensorDoesNotReportSuccess() {
        let motion = CMMotionManager()
        guard !motion.isDeviceMotionAvailable else {
            // On a device this is not the case under test.
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates()
        XCTAssertFalse(
            motion.isDeviceMotionActive,
            "updates must not report as active where the sensor does not exist — the "
                + "capture tool reads this to refuse a session it could not record")
        XCTAssertNil(motion.deviceMotion)
        motion.stopDeviceMotionUpdates()
    }
}
