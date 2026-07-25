import XCTest
import ORAlerts
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-042 — the `AlertCommand` → pattern mapping.
///
/// Whether the three patterns actually *feel* different is hardware-only and sits on the
/// manual protocol. What is checkable here is that they are three distinct patterns
/// rather than one played three times, and that VO2 max cannot produce a pace pattern.
final class HapticDispatcherTests: XCTestCase {

    private let fast = AlertCommand.paceTooFast(
        current: Pace(minutesPerMile: 7), target: Pace(minutesPerMile: 8)
    )
    private let slow = AlertCommand.paceTooSlow(
        current: Pace(minutesPerMile: 9), target: Pace(minutesPerMile: 8)
    )
    private let transition = AlertCommand.stepTransition(StepTransition(
        from: ResolvedStep(
            index: 0, kind: .work, goal: .distance(metres: 400),
            target: nil, repIndex: 0, repCount: 4
        ),
        to: ResolvedStep(
            index: 1, kind: .recovery, goal: .distance(metres: 200),
            target: nil, repIndex: 0, repCount: 4
        ),
        wasAutomatic: true,
        completedDistanceMetres: 400,
        completedActiveSeconds: 90,
        atActiveElapsed: 90
    ))

    func testEachAlertKindMapsToItsOwnPattern() {
        XCTAssertEqual(HapticDispatcher.pattern(for: fast), .slowDown)
        XCTAssertEqual(HapticDispatcher.pattern(for: slow), .speedUp)
        XCTAssertEqual(HapticDispatcher.pattern(for: transition), .stepTransition)
        XCTAssertEqual(HapticDispatcher.pattern(for: .workoutComplete), .workoutComplete)
    }

    /// AC-FR-B-1-3 — the three a runner hears mid-run must be distinguishable, which
    /// starts with them being three different patterns.
    func testTheThreeRunTimePatternsAreDistinct() {
        let patterns = Set([
            HapticDispatcher.pattern(for: fast),
            HapticDispatcher.pattern(for: slow),
            HapticDispatcher.pattern(for: transition),
        ])
        XCTAssertEqual(patterns.count, 3)
    }

    /// FR-C-4 — no pace haptic in VO2 max, at the mapping layer as well as at the engine
    /// that already suppresses it. Belt and braces on a requirement the memo is emphatic
    /// about, so a refactor that breaks the engine's suppression fails here too.
    func testVO2MaxPermitsNoPaceHapticButPermitsTransitions() {
        XCTAssertFalse(HapticDispatcher.permits(fast, runType: .vo2max))
        XCTAssertFalse(HapticDispatcher.permits(slow, runType: .vo2max))
        XCTAssertTrue(HapticDispatcher.permits(transition, runType: .vo2max))
        XCTAssertTrue(HapticDispatcher.permits(.workoutComplete, runType: .vo2max))
    }

    func testEveryOtherRunTypePermitsPaceHaptics() {
        for runType in RunType.allCases where runType != .vo2max {
            XCTAssertTrue(
                HapticDispatcher.permits(fast, runType: runType),
                "\(runType) suppressed pace haptics"
            )
        }
    }
}
