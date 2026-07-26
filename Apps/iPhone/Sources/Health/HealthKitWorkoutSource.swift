import Foundation
import HealthKit
import ORModels
import PhoneSupport

/// The real `HealthWorkoutSource`: `HKWorkout` queries (T-051).
///
/// As with the watch's HealthKit backend, every *decision* about backfilling — what counts as
/// degraded, when a placeholder is superseded, what must never be overwritten — lives in
/// `PhoneSupport.BackfillService` and is tested against a fake. This file only asks HealthKit
/// questions, so it holds nothing worth unit-testing and everything that needs a device.
public struct HealthKitWorkoutSource: HealthWorkoutSource {

    private let store = HKHealthStore()

    public init() {}

    public func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(
                toShare: [],
                read: [
                    HKObjectType.workoutType(),
                    HKQuantityType(.heartRate),
                    HKQuantityType(.distanceWalkingRunning),
                    HKSeriesType.workoutRoute(),
                ]
            )
            return true
        } catch {
            return false
        }
    }

    public func runningWorkouts(from: Date, to: Date) async throws -> [HealthWorkout] {
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let datePredicate = HKQuery.predicateForSamples(withStart: from, end: to)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .workout(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, datePredicate])),
            ],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let workouts = try await descriptor.result(for: store)
        var results: [HealthWorkout] = []

        for workout in workouts {
            results.append(HealthWorkout(
                workoutUUID: workout.uuid,
                startedAt: workout.startDate,
                endedAt: workout.endDate,
                distanceMetres: workout
                    .statistics(for: HKQuantityType(.distanceWalkingRunning))?
                    .sumQuantity()?.doubleValue(for: .meter()) ?? 0,
                // HealthKit's own duration already excludes paused time, so it is used directly
                // rather than differencing the start and end dates — which would count pauses as
                // running and inflate every backfilled run's active time.
                activeSeconds: workout.duration,
                averageHeartRate: workout
                    .statistics(for: HKQuantityType(.heartRate))?
                    .averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())),
                maxHeartRate: workout
                    .statistics(for: HKQuantityType(.heartRate))?
                    .maximumQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())),
                // Routes are fetched separately and are not needed to decide whether a backfill is
                // warranted, so they are left out of this query rather than making every scan pay
                // for a per-workout route request.
                route: nil
            ))
        }
        return results
    }
}
