import XCTest
@testable import WatchSupport

final class GPSAvailabilityTrackerTests: XCTestCase {

    func testAvailableWhileFixesArriveRegularly() {
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        for t in stride(from: 0.0, through: 100.0, by: 1.0) {
            tracker.record(timestamp: t, isUsableFix: true)
            XCTAssertTrue(tracker.isAvailable, "should stay available at t=\(t)")
        }
    }

    func testBecomesUnavailableAfterTimeoutWithNoFix() {
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        tracker.record(timestamp: 0, isUsableFix: true)
        tracker.record(timestamp: 9, isUsableFix: false)
        XCTAssertTrue(tracker.isAvailable, "9 s without a fix is still within the 10 s timeout")
        tracker.record(timestamp: 11, isUsableFix: false)
        XCTAssertFalse(tracker.isAvailable, "11 s without a fix exceeds the 10 s timeout")
    }

    func testRecoversOnceAGoodFixArrives() {
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        tracker.record(timestamp: 0, isUsableFix: true)
        tracker.record(timestamp: 20, isUsableFix: false)
        XCTAssertFalse(tracker.isAvailable)
        tracker.record(timestamp: 21, isUsableFix: true)
        XCTAssertTrue(tracker.isAvailable)
    }

    func testStartsAvailableBeforeAnyFixHasArrived() {
        // The opening seconds of a run are not yet a loss — GPS has not had time
        // to converge, and treating that as unavailable would immediately kick
        // the run onto the pedometer for no reason.
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        tracker.record(timestamp: 3, isUsableFix: false)
        XCTAssertTrue(tracker.isAvailable)
    }

    func testBecomesUnavailableIfNoFixEverArrivesPastTheTimeout() {
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        tracker.record(timestamp: 15, isUsableFix: false)
        XCTAssertFalse(tracker.isAvailable)
    }

    func testResetReturnsToTheStartingState() {
        var tracker = GPSAvailabilityTracker(timeoutSeconds: 10)
        tracker.record(timestamp: 100, isUsableFix: false)
        XCTAssertFalse(tracker.isAvailable)
        tracker.reset()
        tracker.record(timestamp: 3, isUsableFix: false)
        XCTAssertTrue(tracker.isAvailable)
    }
}
