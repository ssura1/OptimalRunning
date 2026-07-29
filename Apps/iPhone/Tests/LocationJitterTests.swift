import CoreLocation
import XCTest

@testable import OptimalRunner

/// S-058 — the movement gate on GNSS distance accumulation.
///
/// The numbers below are taken from the first field bench test rather than invented. Over
/// thirty seconds of the runner standing motionless the phone reported a healthy 5.1 m
/// horizontal accuracy throughout — so the accuracy gate admitted every fix — and **70.9 m
/// of distance accumulated from position wander alone**, 15% of the whole session.
///
/// That matters more than a wrong number on a screen: the GNSS series is the reference the
/// calibrator fits the step-length model against, so fabricated distance does not stay in
/// the distance column. Replaying the same fixes through the gate returned 401.9 m against
/// CMPedometer's independent 384.5 m, where the ungated figure was 476.6 m — an error of
/// +4.5% rather than +24%.
final class LocationJitterTests: XCTestCase {

    /// Built per test rather than in `setUp`, because the recorder is `@MainActor` and an
    /// isolated `setUp` cannot override the nonisolated one it inherits.
    @MainActor private func makeRecorder() -> MotionCaptureRecorder { MotionCaptureRecorder() }

    /// Builds a fix with an explicit Doppler speed.
    private func fix(
        latitude: CLLocationDegrees = 51.5,
        longitude: CLLocationDegrees = -0.1,
        speed: CLLocationSpeed,
        at seconds: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 10,
            horizontalAccuracy: 5.1,
            verticalAccuracy: 5,
            course: 0,
            speed: speed,
            timestamp: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @MainActor func testAStationaryPhoneContributesNoDistance() {
        // 0.07 m/s is the median speed measured while standing still, with the accuracy
        // that accompanied it — a fix the accuracy gate happily admits.
        let previous = fix(speed: 0.05, at: 0)
        let current = fix(latitude: 51.500018, speed: 0.07, at: 1)
        XCTAssertFalse(
            makeRecorder().isMoving(current, since: previous),
            "GNSS wander while standing still was counted as distance")
    }

    @MainActor func testWalkingContributesDistance() {
        // 1.44 m/s, the median measured while walking.
        let previous = fix(speed: 1.40, at: 0)
        let current = fix(latitude: 51.500013, speed: 1.44, at: 1)
        XCTAssertTrue(makeRecorder().isMoving(current, since: previous), "walking must count")
    }

    @MainActor func testRunningContributesDistance() {
        let previous = fix(speed: 2.60, at: 0)
        let current = fix(latitude: 51.500024, speed: 2.71, at: 1)
        XCTAssertTrue(makeRecorder().isMoving(current, since: previous), "running must count")
    }

    /// An unknown speed is not evidence of motion, but neither is it evidence of rest —
    /// so the implied speed decides rather than a default either way.
    @MainActor func testAnUnavailableSpeedFallsBackToImpliedSpeed() {
        // CoreLocation reports -1 when Doppler speed is unavailable.
        let origin = fix(speed: -1, at: 0)
        // ~0.11 m over one second: far below the threshold.
        let barelyMoved = fix(latitude: 51.500001, speed: -1, at: 1)
        let recorder = makeRecorder()
        XCTAssertFalse(
            recorder.isMoving(barelyMoved, since: origin),
            "an unknown speed with no displacement must not count as motion")

        // ~11 m over one second: unambiguously moving.
        let clearlyMoved = fix(latitude: 51.5001, speed: -1, at: 1)
        XCTAssertTrue(
            recorder.isMoving(clearlyMoved, since: origin),
            "an unknown speed with real displacement must count")
    }

    /// Two fixes sharing a timestamp must not divide by zero.
    @MainActor func testSimultaneousFixesAreNotCountedAsMotion() {
        let a = fix(speed: -1, at: 5)
        let b = fix(latitude: 51.5001, speed: -1, at: 5)
        XCTAssertFalse(makeRecorder().isMoving(b, since: a))
    }

    /// The threshold must stay well clear of both regimes it separates.
    @MainActor func testTheThresholdSitsBetweenStandingAndWalking() {
        let threshold = MotionCaptureRecorder.minimumMovingSpeed
        XCTAssertGreaterThan(
            threshold, 0.07, "must exceed the speed measured while standing still")
        XCTAssertLessThan(
            threshold, 1.44, "must stay below the speed measured while walking")
    }
}
