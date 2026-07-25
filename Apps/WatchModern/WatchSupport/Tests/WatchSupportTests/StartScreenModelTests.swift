import XCTest
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-046 — run selection, target preview, and the per-run adjustment that must not
/// rewrite the profile.
@MainActor
final class StartScreenModelTests: XCTestCase {

    private func model(plannedWorkout: WorkoutPlan? = nil) -> StartScreenModel {
        StartScreenModel(
            profile: RunnerProfile(
                tempoPace: Pace(minutesPerMile: 8),
                easyPace: Pace(minutesPerMile: 9.5),
                longPace: Pace(minutesPerMile: 9),
                units: .miles
            ),
            plannedWorkout: plannedWorkout
        )
    }

    // MARK: - Reachability

    /// FR-A-7 — every run type is offered, and each one produces a startable plan.
    func testEveryRunTypeIsReachableAndProducesAPlan() {
        let model = self.model()
        XCTAssertEqual(model.options.count, RunType.allCases.count)

        for runType in RunType.allCases {
            let option = model.option(for: runType)
            XCTAssertEqual(option.runType, runType)
            XCTAssertFalse(option.title.isEmpty)
            XCTAssertFalse(option.detail.isEmpty)

            let plan = model.plan(for: runType)
            XCTAssertEqual(plan.runType, runType)
            XCTAssertFalse(plan.resolvedSteps().isEmpty, "\(runType) resolved to no steps")
        }
    }

    // MARK: - Target and band preview

    func testContinuousTypesPreviewTheirTargetAndBand() {
        let option = model().option(for: .tempo)
        XCTAssertEqual(option.targetText, "8:00 /mi")
        // The tempo band is ±2% near, so roughly 7:50–8:10.
        XCTAssertEqual(option.bandText, "7:50 – 8:10")
        XCTAssertFalse(option.isStructured)
    }

    /// Structured types carry targets per step, so there is no single run target to
    /// preview — and inventing one would misrepresent what the run will judge.
    func testStructuredTypesPreviewNoRunLevelTarget() {
        for runType in [RunType.interval, .vo2max] {
            let option = model().option(for: runType)
            XCTAssertNil(option.targetText, "\(runType) previewed a run-level target")
            XCTAssertNil(option.bandText)
            XCTAssertTrue(option.isStructured)
        }
    }

    func testATypeWithNoStoredPaceHasNothingToPreview() {
        let model = StartScreenModel(profile: RunnerProfile())
        XCTAssertNil(model.option(for: .tempo).targetText)
    }

    func testPreviewFollowsTheRunnersUnits() {
        let model = StartScreenModel(
            profile: RunnerProfile(tempoPace: Pace(minutesPerKilometre: 5), units: .kilometres)
        )
        XCTAssertEqual(model.option(for: .tempo).targetText, "5:00 /km")
    }

    // MARK: - Per-run adjustment (the part that must not leak)

    /// The headline guarantee: today's adjustment changes what this run judges, and
    /// nothing else. A runner easing off on a tired day has not changed their tempo pace,
    /// and silently retraining the profile would drift every future target downward.
    func testAdjustingATargetDoesNotMutateTheStoredProfile() {
        let model = self.model()
        let storedBefore = model.profile

        model.adjustTarget(for: .tempo, bySeconds: 15)

        XCTAssertEqual(model.profile, storedBefore, "the stored profile was rewritten")
        XCTAssertEqual(
            model.profile.basePace(for: .tempo)?.minutesPerMile ?? 0, 8, accuracy: 1e-9
        )
        XCTAssertEqual(
            model.effectiveTarget(for: .tempo)?.secondsPerMile ?? 0, 495, accuracy: 1e-6
        )
    }

    /// …and the adjusted target is what the engine actually receives.
    func testTheRunProfileCarriesTheAdjustmentWhileTheStoredOneDoesNot() {
        let model = self.model()
        model.adjustTarget(for: .tempo, bySeconds: -20)

        let runProfile = model.runProfile(for: .tempo)
        XCTAssertEqual(runProfile.tempoPace?.secondsPerMile ?? 0, 460, accuracy: 1e-6)
        XCTAssertEqual(model.profile.tempoPace?.secondsPerMile ?? 0, 480, accuracy: 1e-6)
    }

    func testAdjustmentsAreIndependentPerRunType() {
        let model = self.model()
        model.adjustTarget(for: .tempo, bySeconds: 10)

        XCTAssertTrue(model.hasAdjustment(for: .tempo))
        XCTAssertFalse(model.hasAdjustment(for: .easy))
        XCTAssertEqual(
            model.effectiveTarget(for: .easy)?.minutesPerMile ?? 0, 9.5, accuracy: 1e-9
        )
    }

    func testAdjustmentsAccumulateAndCanBeReset() {
        let model = self.model()
        model.adjustTarget(for: .tempo, bySeconds: 10)
        model.adjustTarget(for: .tempo, bySeconds: 5)
        XCTAssertEqual(
            model.effectiveTarget(for: .tempo)?.secondsPerMile ?? 0, 495, accuracy: 1e-6
        )

        model.resetAdjustment(for: .tempo)
        XCTAssertEqual(
            model.effectiveTarget(for: .tempo)?.secondsPerMile ?? 0, 480, accuracy: 1e-6
        )
        XCTAssertFalse(model.hasAdjustment(for: .tempo))
    }

    func testAdjustingATypeWithNoTargetDoesNothing() {
        let model = StartScreenModel(profile: RunnerProfile())
        model.adjustTarget(for: .tempo, bySeconds: 10)
        XCTAssertFalse(model.hasAdjustment(for: .tempo))
    }

    /// An adjustment cannot drive the target to zero or negative, which would produce an
    /// invalid `Pace` and a nonsensical zone for the whole run.
    func testAnAbsurdAdjustmentIsRefusedRatherThanProducingAnInvalidPace() {
        let model = self.model()
        model.adjustTarget(for: .tempo, bySeconds: -10_000)

        XCTAssertFalse(model.hasAdjustment(for: .tempo))
        XCTAssertTrue(model.effectiveTarget(for: .tempo)?.isValid ?? false)
    }

    // MARK: - Today's planned workout

    func testAPlannedWorkoutIsUsedInPlaceOfThePresetForItsType() {
        let planned = WorkoutPresets.intervals(reps: 6, workMetres: 200, recoveryMetres: 200)
        let model = self.model(plannedWorkout: planned)

        XCTAssertEqual(model.plan(for: .interval), planned)
        // Other types are unaffected.
        XCTAssertEqual(model.plan(for: .vo2max).runType, .vo2max)
        XCTAssertNotEqual(model.plan(for: .vo2max), planned)
    }

    func testWithNoPlannedWorkoutTheStructuredPresetsAreUsed() {
        let model = self.model()
        XCTAssertEqual(model.plan(for: .vo2max).resolvedSteps().count, 10)
    }
}
