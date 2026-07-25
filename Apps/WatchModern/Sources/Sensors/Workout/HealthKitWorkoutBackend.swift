import Foundation
import HealthKit
import WatchSupport

/// The real `WorkoutBackend`: `HKWorkoutSession` + `HKLiveWorkoutBuilder` (T-033).
///
/// Everything *decided* about a workout's lifecycle — what a denial means, how active
/// time accrues across pauses, whether a second `end()` is an error — lives in
/// `WorkoutSessionController` and is unit-tested against a fake. What lives here is only
/// the part that cannot be tested without a device: the actual framework calls. The
/// split is deliberate, and the reason this file has no branching logic worth reading.
///
/// Verification is therefore manual for this file specifically — see the manual protocol
/// in `Apps/WatchModern/README.md`.
final class HealthKitWorkoutBackend: WorkoutBackend {

    private let store = HKHealthStore()
    /// `nonisolated(unsafe)` rather than an actor: these are only ever touched from
    /// `WorkoutSessionController`, which is `@MainActor`, so the serialization already
    /// exists one level up. Introducing a second isolation domain here would mean two
    /// actors hopping per call for no added safety.
    private nonisolated(unsafe) var session: HKWorkoutSession?
    private nonisolated(unsafe) var builder: HKLiveWorkoutBuilder?

    private static let typesToShare: Set<HKSampleType> = [
        HKQuantityType.workoutType(),
        HKSeriesType.workoutRoute(),
    ]

    private static let typesToRead: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKObjectType.activitySummaryType(),
    ]

    func requestAuthorization() async -> AuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        do {
            try await store.requestAuthorization(
                toShare: Self.typesToShare, read: Self.typesToRead
            )
        } catch {
            return .denied
        }

        // Read authorization is deliberately not checked. HealthKit refuses to disclose
        // read permission by design — `authorizationStatus(for:)` returns
        // `.sharingAuthorized` only for *write* types — so a run gated on knowing
        // whether heart rate is readable would either be blocked forever or have to
        // guess. Write authorization is knowable, and it is the one that determines
        // whether the run can be saved at all (AC-FR-D-1-7).
        let canWrite = store.authorizationStatus(for: HKQuantityType.workoutType())
        return canWrite == .sharingAuthorized ? .authorized : .denied
    }

    func startSession(locationType: WorkoutLocationType) async throws {
        guard session == nil else { throw WorkoutBackendError.alreadyRunning }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = switch locationType {
        case .outdoor: .outdoor
        case .indoor: .indoor
        case .unknown: .unknown
        }

        let session: HKWorkoutSession
        do {
            session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        } catch {
            throw WorkoutBackendError.sessionUnavailable
        }

        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: store, workoutConfiguration: configuration
        )

        self.session = session
        self.builder = builder

        let start = Date()
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)
    }

    func pauseSession() async {
        session?.pause()
    }

    func resumeSession() async {
        session?.resume()
    }

    func endAndSave() async throws -> UUID? {
        guard let session, let builder else { throw WorkoutBackendError.notRunning }

        // `defer`, not a clear at the end: a retained ended session keeps the workout's
        // background assertion alive, so a save that throws must still release it. That
        // is precisely the NFR-8 leak the run controller is asserted against, and the
        // failure path is the one where it would actually happen.
        defer {
            self.session = nil
            self.builder = nil
        }

        let end = Date()
        session.end()
        try await builder.endCollection(at: end)
        return try await builder.finishWorkout()?.uuid
    }
}
