import Foundation
import HealthKit
import LegacySupport

/// The real `WorkoutBackend`, over watchOS 8's HealthKit — Legacy tier (T-063, T-065).
///
/// **Not unit-tested, and not testable.** `HKWorkoutSession` needs a real device or an interactively
/// authorized simulator, and for this tier there is no simulator at all — Xcode 26 ships no watchOS 8
/// runtime. So this file is written carefully against the framework and verified on Series 3
/// hardware; everything above it is behind `WorkoutBackend` precisely so that the untestable surface
/// is as thin as this.
///
/// Zero `#available` (CON-3, AC-FR-K-1-5): the deployment target is watchOS 8 and every API used here
/// exists at watchOS 8, so there is nothing to condition on.
///
/// ## The segmentation divergence (AC-FR-D-1-6)
///
/// `HKWorkoutSession.beginNewActivity` is watchOS 9+, so interval boundaries are recorded as
/// `HKWorkoutEvent(type: .segment)` appended to the builder. See `WorkoutSegment` for what is and is
/// not equivalent about that.
final class HealthKitWorkoutBackend: WorkoutBackend, @unchecked Sendable {

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// Wall-clock start, so run-relative segment times can be converted to the `Date` pair
    /// `HKWorkoutEvent` requires.
    private var startDate: Date?

    private let activity: HKWorkoutActivityType = .running

    func requestAuthorization() async -> AuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }

        let share: Set<HKSampleType> = [
            HKQuantityType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKSeriesType.workoutRoute(),
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        ]

        do {
            try await store.requestAuthorization(toShare: share, read: read)
            // Authorization status for *reading* is deliberately opaque in HealthKit, so sharing
            // status is the only honest signal. A denial is a handled state, not an error
            // (AC-FR-D-1-7).
            return store.authorizationStatus(for: HKQuantityType.workoutType()) == .sharingAuthorized
                ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func startSession(locationType: WorkoutLocationType) async throws {
        guard session == nil else { throw WorkoutBackendError.alreadyRunning }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = {
            switch locationType {
            case .outdoor: return .outdoor
            case .indoor: return .indoor
            case .unknown: return .unknown
            }
        }()

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: store, workoutConfiguration: configuration
        )

        let start = Date()
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)

        self.session = session
        self.builder = builder
        self.startDate = start
    }

    func pauseSession() async { session?.pause() }
    func resumeSession() async { session?.resume() }

    /// Appends one segment event.
    ///
    /// A failure here is swallowed rather than propagated, and that is a deliberate choice: losing a
    /// segment marker degrades the *export*, while throwing out of the run loop would end a run the
    /// runner is still in the middle of. The run is worth more than the annotation.
    func recordSegment(_ segment: WorkoutSegment) async {
        guard let builder, let startDate else { return }

        let event = HKWorkoutEvent(
            type: .segment,
            dateInterval: DateInterval(
                start: startDate.addingTimeInterval(segment.start),
                duration: max(segment.end - segment.start, 0)
            ),
            metadata: nil
        )
        try? await builder.addWorkoutEvents([event])
    }

    func endAndSave() async throws -> UUID? {
        guard let session, let builder else { throw WorkoutBackendError.notRunning }

        let end = Date()
        session.end()
        try await builder.endCollection(at: end)
        let workout = try await builder.finishWorkout()

        self.session = nil
        self.builder = nil
        self.startDate = nil

        return workout?.uuid
    }
}
