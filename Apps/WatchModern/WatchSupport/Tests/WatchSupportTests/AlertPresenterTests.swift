import XCTest
import ORAlerts
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-043 — every FR-B-2 acceptance criterion that can be asserted without a screen.
///
/// AC-FR-B-2-4's "returns to the same scroll position" is the one that cannot: scroll
/// position is a `ScrollViewReader` behaviour with no model state behind it. It is on the
/// manual protocol in the README rather than silently claimed here.
final class AlertPresenterTests: XCTestCase {

    private let current = Pace(minutesPerMile: 7.5)
    private let target = Pace(minutesPerMile: 8.0)

    private func tooSlow() -> AlertCommand {
        .paceTooSlow(current: Pace(minutesPerMile: 8.6), target: target)
    }

    private func tooFast() -> AlertCommand {
        .paceTooFast(current: current, target: target)
    }

    private func step(_ index: Int, kind: StepKind, rep: Int = 0, of reps: Int = 1) -> ResolvedStep {
        ResolvedStep(
            index: index, kind: kind, goal: .distance(metres: 1_000),
            target: nil, repIndex: rep, repCount: reps
        )
    }

    private func transition() -> AlertCommand {
        .stepTransition(StepTransition(
            from: step(0, kind: .work),
            to: step(1, kind: .recovery),
            wasAutomatic: true,
            completedDistanceMetres: 1_000,
            completedActiveSeconds: 240,
            atActiveElapsed: 240
        ))
    }

    // MARK: - AC-FR-B-2-1

    func testAPaceWarningStatesDirectionCurrentTargetAndSignedDelta() {
        var presenter = AlertPresenter()
        XCTAssertTrue(presenter.offer(tooFast(), now: 10, isLuminanceReduced: false, unit: .miles))

        guard case let .paceWarning(warning)? = presenter.visible else {
            return XCTFail("expected a pace warning")
        }
        XCTAssertEqual(warning.zone, .tooFast)
        XCTAssertEqual(warning.current, current)
        XCTAssertEqual(warning.target, target)
        // 7:30 against 8:00 is 30 s per mile fast, so a negative signed delta.
        XCTAssertEqual(warning.signedDelta, -30, accuracy: 0.5)
    }

    func testTooSlowProducesAPositiveDelta() {
        var presenter = AlertPresenter()
        presenter.offer(tooSlow(), now: 0, isLuminanceReduced: false, unit: .miles)

        guard case let .paceWarning(warning)? = presenter.visible else {
            return XCTFail("expected a pace warning")
        }
        XCTAssertEqual(warning.zone, .tooSlow)
        XCTAssertGreaterThan(warning.signedDelta, 0)
    }

    // MARK: - AC-FR-B-2-2

    func testTheWarningAutoDismissesAtFourSeconds() {
        var presenter = AlertPresenter()
        presenter.offer(tooFast(), now: 100, isLuminanceReduced: false, unit: .miles)

        presenter.tick(now: 103.9, isLuminanceReduced: false)
        XCTAssertNotNil(presenter.visible, "dismissed early")

        presenter.tick(now: 104, isLuminanceReduced: false)
        XCTAssertNil(presenter.visible, "did not dismiss at 4 s")
    }

    /// The duration is a declared tunable (AC-FR-B-2-2 says so), so it must come from
    /// configuration rather than a literal.
    func testTheDismissDurationIsConfigurable() {
        var config = PresentationConfiguration()
        config.warningAutoDismissSeconds = 10

        var presenter = AlertPresenter(config: config)
        presenter.offer(tooFast(), now: 0, isLuminanceReduced: false, unit: .miles)

        presenter.tick(now: 5, isLuminanceReduced: false)
        XCTAssertNotNil(presenter.visible)
        presenter.tick(now: 10, isLuminanceReduced: false)
        XCTAssertNil(presenter.visible)
    }

    // MARK: - AC-FR-B-2-3

    func testTapOrCrownRotationDismissesImmediately() {
        var presenter = AlertPresenter()
        presenter.offer(tooFast(), now: 0, isLuminanceReduced: false, unit: .miles)
        XCTAssertNotNil(presenter.visible)

        presenter.dismiss()
        XCTAssertNil(presenter.visible)
    }

    // MARK: - AC-FR-B-2-5

    /// Dropped, not queued. The distinction is the whole requirement: a warning held
    /// until the wrist comes up would describe a pace from seconds ago.
    func testAWarningRaisedWhileDimmedIsDroppedRatherThanQueued() {
        var presenter = AlertPresenter()

        XCTAssertFalse(presenter.offer(tooFast(), now: 0, isLuminanceReduced: true, unit: .miles))
        XCTAssertNil(presenter.visible)
        XCTAssertEqual(presenter.droppedWhileDimmedCount, 1)

        // Coming out of the dimmed state must not reveal the dropped warning.
        presenter.tick(now: 1, isLuminanceReduced: false)
        XCTAssertNil(presenter.visible, "a dropped warning was queued after all")
    }

    /// The wrist drops while a warning is already up: it goes away rather than waiting.
    func testAVisibleWarningIsDismissedWhenTheDisplayDims() {
        var presenter = AlertPresenter()
        presenter.offer(tooFast(), now: 0, isLuminanceReduced: false, unit: .miles)

        presenter.tick(now: 1, isLuminanceReduced: true)
        XCTAssertNil(presenter.visible)
    }

    // MARK: - AC-FR-B-2-6

    func testAStepTransitionReplacesAVisiblePaceWarning() {
        var presenter = AlertPresenter()
        presenter.offer(tooFast(), now: 0, isLuminanceReduced: false, unit: .miles)

        XCTAssertTrue(presenter.offer(transition(), now: 1, isLuminanceReduced: false, unit: .miles))
        guard case .stepTransition? = presenter.visible else {
            return XCTFail("the transition did not take priority")
        }
    }

    func testAPaceWarningCannotObscureAVisibleStepTransition() {
        var presenter = AlertPresenter()
        presenter.offer(transition(), now: 0, isLuminanceReduced: false, unit: .miles)

        XCTAssertFalse(presenter.offer(tooFast(), now: 1, isLuminanceReduced: false, unit: .miles))
        guard case .stepTransition? = presenter.visible else {
            return XCTFail("a pace warning displaced the transition screen")
        }
    }

    // MARK: - The transition screen (design.md §12.4)

    func testTheTransitionScreenCarriesTheCompletedStepsTimeAndAveragePace() {
        var presenter = AlertPresenter()
        presenter.offer(transition(), now: 0, isLuminanceReduced: false, unit: .miles)

        guard case let .stepTransition(screen)? = presenter.visible else {
            return XCTFail("expected a transition screen")
        }
        XCTAssertEqual(screen.from.kind, .work)
        XCTAssertEqual(screen.to?.kind, .recovery)
        XCTAssertEqual(screen.completedDistanceMetres, 1_000, accuracy: 1e-9)
        XCTAssertEqual(screen.completedActiveSeconds, 240, accuracy: 1e-9)
        // 1000 m in 240 s.
        XCTAssertEqual(screen.completedAveragePace?.secondsPerMetre ?? 0, 0.24, accuracy: 1e-9)
    }

    func testTheTransitionScreenDismissesAtThreeSeconds() {
        var presenter = AlertPresenter()
        presenter.offer(transition(), now: 0, isLuminanceReduced: false, unit: .miles)

        presenter.tick(now: 2.9, isLuminanceReduced: false)
        XCTAssertNotNil(presenter.visible)
        presenter.tick(now: 3, isLuminanceReduced: false)
        XCTAssertNil(presenter.visible)
    }

    /// Workout completion is a destination, not a three-second interruption over the
    /// metrics page — so it presents nothing here.
    func testWorkoutCompletePresentsNoInterruption() {
        var presenter = AlertPresenter()
        XCTAssertFalse(
            presenter.offer(.workoutComplete, now: 0, isLuminanceReduced: false, unit: .miles)
        )
        XCTAssertNil(presenter.visible)
    }
}
