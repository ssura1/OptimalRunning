import XCTest
import ORAlerts
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// A haptic at every step boundary, on both the automatic and the manual path (T-105).
///
/// Reported from the first real interval session: transitions were not reliably felt. The
/// engine's own golden fixtures already count transition *alerts*, so the question this
/// suite answers is narrower and different — does the alert reach the haptic player, at
/// every boundary, whichever way the boundary was crossed.
///
/// **The two paths are not interchangeable, and which boundary uses which is fixed by the
/// plan rather than by preference:**
///
/// - Warm-up carries an **open** goal, so it never ends on its own. The only way out is a
///   manual advance — tap, crown, or Double Tap.
/// - Work and recovery carry **distance** goals, so they are closed. AC-FR-C-3-4 requires a
///   tap on a closed step to be ignored, precisely so a stray glove-tap cannot truncate a
///   400 m rep — so these boundaries are *only* ever automatic.
///
/// That means "manual work→recovery" is not a gap to be filled; it is a rule. What has to
/// hold is that each boundary fires on the one path that can reach it.
@MainActor
final class TransitionHapticTests: XCTestCase {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransitionHapticTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Harness {
        let model: RunSessionModel
        let feed: FakeSensorFeed
        let haptics: RecordingHaptics
    }

    private func makeHarness() -> Harness {
        let feed = FakeSensorFeed()
        let haptics = RecordingHaptics()
        let model = RunSessionModel(
            plan: WorkoutPresets.intervals(reps: 4, workMetres: 400, recoveryMetres: 200),
            profile: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
            feed: feed,
            store: SampleStore(directory: scratch()),
            session: WorkoutSessionController(backend: FakeWorkoutBackend()),
            haptics: haptics
        )
        return Harness(model: model, feed: feed, haptics: haptics)
    }

    /// One observed boundary: what it was, and whether a haptic landed on the same tick.
    private struct Observed {
        let from: StepKind
        let to: StepKind?
        let wasAutomatic: Bool
        let firedHaptic: Bool
    }

    /// Drives a full interval session, ending the open-goal warm-up by manual advance, and
    /// records every boundary the engine reports alongside whether the haptic player was
    /// called on that same tick.
    private func observeBoundaries(
        _ harness: Harness, seconds: Int = 900, advanceWarmupAt: Int? = 30
    ) -> [Observed] {
        var observed: [Observed] = []
        var distance = 0.0

        for second in 0..<seconds {
            let before = harness.haptics.played.count
            distance += 3.35
            harness.feed.emit(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: distance,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5, longitude: -0.12,
                    altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0, heartRate: 155, distanceSource: .healthKit
            ))

            if let transition = harness.model.output?.stepTransition {
                let fired = harness.haptics.played[before...].contains(.stepTransition)
                    || harness.haptics.played[before...].contains(.workoutComplete)
                observed.append(Observed(
                    from: transition.from.kind,
                    to: transition.to?.kind,
                    wasAutomatic: transition.wasAutomatic,
                    firedHaptic: fired
                ))
            }

            if second == advanceWarmupAt { harness.model.requestManualAdvance() }
        }
        return observed
    }

    /// **The property**: no boundary is ever crossed silently.
    ///
    /// Asserted over every transition the session produces rather than over a sampled one,
    /// so a regression that silenced only recovery→work — or only the manual path — cannot
    /// hide behind the boundaries that still work.
    func testEveryStepBoundaryFiresAHaptic() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        let observed = observeBoundaries(harness)

        XCTAssertFalse(observed.isEmpty, "the session produced no step boundaries at all")
        for boundary in observed {
            XCTAssertTrue(
                boundary.firedHaptic,
                "silent boundary \(boundary.from) → \(String(describing: boundary.to)) "
                    + "(automatic: \(boundary.wasAutomatic))")
        }
    }

    /// The warm-up boundary, which only the manual path can reach.
    func testWarmupEndsOnTheManualPathAndIsFelt() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        let observed = observeBoundaries(harness)
        let warmup = observed.filter { $0.from == .warmup }

        XCTAssertEqual(warmup.count, 1, "expected exactly one warm-up boundary")
        XCTAssertFalse(
            warmup[0].wasAutomatic,
            "warm-up carries an open goal; it cannot end automatically")
        XCTAssertTrue(warmup[0].firedHaptic, "the warm-up boundary was silent")
        XCTAssertEqual(warmup[0].to, .work)
    }

    /// Both directions of the work/recovery alternation, which only the automatic path can
    /// reach, and both must be felt — a runner who only feels one of the two learns to
    /// distrust the haptic entirely.
    func testWorkAndRecoveryAlternateInBothDirectionsAndBothAreFelt() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        let observed = observeBoundaries(harness)
        let workToRecovery = observed.filter { $0.from == .work && $0.to == .recovery }
        let recoveryToWork = observed.filter { $0.from == .recovery && $0.to == .work }

        XCTAssertFalse(workToRecovery.isEmpty, "no work → recovery boundary occurred")
        XCTAssertFalse(recoveryToWork.isEmpty, "no recovery → work boundary occurred")

        for boundary in workToRecovery + recoveryToWork {
            XCTAssertTrue(boundary.wasAutomatic, "closed goals must end automatically")
            XCTAssertTrue(
                boundary.firedHaptic,
                "silent \(boundary.from) → \(String(describing: boundary.to))")
        }
    }

    /// A closed step ignores a manual advance, and — the part worth asserting — does so
    /// *silently*. A haptic on a refused tap would teach the runner that the tap worked.
    func testATapOnAClosedStepNeitherAdvancesNorBuzzes() async throws {
        let harness = makeHarness()
        try await harness.model.start(activity: .outdoorRun)

        // End the warm-up, settle into the first 400 m rep, then tap during it.
        _ = observeBoundaries(harness, seconds: 60, advanceWarmupAt: 5)
        let stepBefore = harness.model.output?.step.step?.index
        let hapticsBefore = harness.haptics.played.count

        harness.model.requestManualAdvance()
        _ = observeBoundaries(harness, seconds: 3, advanceWarmupAt: nil)

        XCTAssertEqual(
            harness.model.output?.step.step?.index, stepBefore,
            "a tap truncated a closed 400 m rep")
        XCTAssertEqual(
            harness.haptics.played.count, hapticsBefore,
            "a refused tap fired a haptic, which tells the runner it worked")
    }
}
