import XCTest
import ORIntervals
import ORModels
@testable import WatchSupport

/// T-050, watch side — applying the phone's context, and surviving without it.
@MainActor
final class DownlinkApplierTests: XCTestCase {

    private func profile(tempo: Double, units: UnitPreference = .kilometres) -> RunnerProfile {
        RunnerProfile(
            tempoPace: Pace(minutesPerMile: tempo),
            easyPace: Pace(minutesPerMile: tempo + 1.5),
            longPace: Pace(minutesPerMile: tempo + 1),
            units: units,
            palette: .colorVisionDeficiency,
            paceHapticsEnabled: false,
            crownAdvanceEnabled: true
        )
    }

    private func context(
        sequence: Int,
        profile: RunnerProfile? = nil,
        planned: [PlannedWorkoutDescriptor] = []
    ) -> PhoneContext {
        PhoneContext(
            sequence: sequence,
            acknowledgement: .empty,
            profile: profile,
            plannedWorkouts: planned
        )
    }

    // MARK: - A profile edit arrives

    func testASyncedProfileIsAdoptedInFull() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        let applier = DownlinkApplier(settings: store)

        XCTAssertTrue(applier.apply(context(sequence: 1, profile: profile(tempo: 7.25))))

        let active = applier.activeProfile
        XCTAssertEqual(active.tempoPace?.minutesPerMile ?? 0, 7.25, accuracy: 1e-9)
        XCTAssertEqual(active.units, .kilometres)
        XCTAssertEqual(active.palette, .colorVisionDeficiency)
        XCTAssertFalse(active.paceHapticsEnabled)
        XCTAssertTrue(active.crownAdvanceEnabled)
    }

    /// AC-FR-I-1-6 — the guarantee that actually matters.
    ///
    /// The watch reboots with the phone at home. A synced profile held only in memory would be
    /// gone, and the runner would be judged against a default target they never set. So the
    /// profile has to be written through on arrival, and this proves it by building a *fresh*
    /// `SettingsStore` over the same backing — which is what a relaunch is.
    func testTheWatchKeepsOperatingOnTheLastSyncedProfileWithThePhoneOff() {
        let backing = InMemoryKeyValueStore()

        do {
            let store = SettingsStore(backing: backing)
            DownlinkApplier(settings: store).apply(
                context(sequence: 4, profile: profile(tempo: 6.75, units: .miles))
            )
        }

        // Relaunch: no phone, no context, nothing in memory.
        let relaunched = SettingsStore(backing: backing)
        XCTAssertEqual(
            relaunched.profile.tempoPace?.minutesPerMile ?? 0, 6.75, accuracy: 1e-9,
            "the synced profile did not survive a relaunch, so the watch fell back to defaults"
        )
        XCTAssertEqual(relaunched.profile.units, .miles)
        XCTAssertEqual(relaunched.profile.palette, .colorVisionDeficiency)
    }

    /// A context with no profile must leave the stored one alone. `nil` means "the phone has not
    /// finished onboarding", not "this runner has no settings", and clearing a working profile
    /// because the phone had nothing to say would be the worst available reading.
    func testAContextWithNoProfileDoesNotClearTheStoredOne() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        let applier = DownlinkApplier(settings: store)

        applier.apply(context(sequence: 1, profile: profile(tempo: 7.0)))
        applier.apply(context(sequence: 2, profile: nil))

        XCTAssertEqual(
            applier.activeProfile.tempoPace?.minutesPerMile ?? 0, 7.0, accuracy: 1e-9,
            "an empty context wiped the synced profile"
        )
    }

    /// `updateApplicationContext` is latest-value-wins but not ordered on receipt, so a late
    /// older context must not roll the profile back.
    func testAStaleContextIsDiscarded() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        let applier = DownlinkApplier(settings: store)

        XCTAssertTrue(applier.apply(context(sequence: 9, profile: profile(tempo: 7.0))))
        XCTAssertFalse(
            applier.apply(context(sequence: 8, profile: profile(tempo: 9.0))),
            "an out-of-order context was applied"
        )
        XCTAssertEqual(applier.activeProfile.tempoPace?.minutesPerMile ?? 0, 7.0, accuracy: 1e-9)
        XCTAssertEqual(applier.lastAppliedSequence, 9)
    }

    func testTheSameSequenceIsNotAppliedTwice() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        let applier = DownlinkApplier(settings: store)

        XCTAssertTrue(applier.apply(context(sequence: 3, profile: profile(tempo: 7.0))))
        XCTAssertFalse(applier.apply(context(sequence: 3, profile: profile(tempo: 8.0))))
        XCTAssertEqual(applier.activeProfile.tempoPace?.minutesPerMile ?? 0, 7.0, accuracy: 1e-9)
    }

    /// A locally-set preference is overwritten by the phone, which is the documented direction:
    /// the phone is authoritative for the profile (AC-FR-I-1-6).
    func testThePhoneIsAuthoritativeOverALocalPreference() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        store.setUnits(.miles)
        store.setPalette(.standard)

        DownlinkApplier(settings: store).apply(
            context(sequence: 1, profile: profile(tempo: 7.0, units: .kilometres))
        )

        XCTAssertEqual(store.profile.units, .kilometres)
        XCTAssertEqual(store.profile.palette, .colorVisionDeficiency)
    }

    // MARK: - Planned workouts

    /// The channel carries a planned workout end to end, so Wave 5 needs no transport change.
    func testTodaysPlannedWorkoutIsSurfacedForTheStartScreen() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        let applier = DownlinkApplier(settings: store)

        let today = Date()
        let descriptor = PlannedWorkoutDescriptor(
            id: UUID(),
            scheduledFor: today,
            plan: WorkoutPresets.intervals(reps: 6, workMetres: 400, recoveryMetres: 200),
            notes: "6 × 400"
        )
        let tomorrow = PlannedWorkoutDescriptor(
            id: UUID(),
            scheduledFor: today.addingTimeInterval(86_400),
            plan: WorkoutPresets.vo2Max4x1000()
        )

        applier.apply(context(sequence: 1, planned: [descriptor, tomorrow]))

        XCTAssertEqual(applier.plannedWorkouts.count, 2)
        XCTAssertEqual(applier.plannedWorkout(on: today)?.id, descriptor.id)
        XCTAssertEqual(applier.plannedWorkout(on: today)?.notes, "6 × 400")
        XCTAssertEqual(
            applier.plannedWorkout(on: today.addingTimeInterval(86_400))?.id, tomorrow.id
        )
    }

    func testWithNoPlannedWorkoutsNothingIsOfferedForToday() {
        let applier = DownlinkApplier(settings: SettingsStore(backing: InMemoryKeyValueStore()))
        applier.apply(context(sequence: 1, profile: profile(tempo: 7.0)))

        XCTAssertTrue(applier.plannedWorkouts.isEmpty)
        XCTAssertNil(applier.plannedWorkout())
    }

    /// Plans are replaced wholesale by each context rather than accumulated — the channel is
    /// latest-value-wins, so the newest list *is* the plan.
    func testPlannedWorkoutsAreReplacedNotAccumulated() {
        let applier = DownlinkApplier(settings: SettingsStore(backing: InMemoryKeyValueStore()))
        let today = Date()

        applier.apply(context(sequence: 1, planned: [
            PlannedWorkoutDescriptor(
                id: UUID(), scheduledFor: today, plan: WorkoutPresets.vo2Max4x1000()
            ),
        ]))
        applier.apply(context(sequence: 2, planned: []))

        XCTAssertTrue(
            applier.plannedWorkouts.isEmpty,
            "a cancelled plan is still being offered to the runner"
        )
    }
}
