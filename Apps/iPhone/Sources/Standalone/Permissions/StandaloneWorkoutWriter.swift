import CoreLocation
import Foundation
import HealthKit
import ORModels
import PhoneSupport

/// Writes a finished standalone run to HealthKit (S-033, ADR-S-07).
///
/// **`HKWorkoutBuilder`, not `HKWorkoutSession`.** The local session initializer is
/// `ios(26.0)` and this app's floor is iOS 17 (CON-S-2), so there is no live session to
/// start, pause or resume — the whole interaction is "here is a finished run, save it".
/// That is why `SensorCapabilities.workoutSession` reports `.builderOnly` rather than
/// reporting no workout support: the builder writes the same `HKWorkout`, with the same
/// route, that a live builder would. When the floor rises, adding the session backend is a
/// second conformer behind this same protocol rather than a re-specification.
///
/// Background execution during the run is therefore earned by the `location` and `audio`
/// background modes rather than by a workout session (CON-S-4) — which is a real
/// difference from the watch and is recorded in the tier divergence matrix.
final class StandaloneWorkoutWriter: StandaloneWorkoutWriting, @unchecked Sendable {

    private let store = HKHealthStore()

    /// What this tier writes. **No heart-rate type appears here, and none can**: the
    /// protocol has no parameter that could carry one and this set has no type that would
    /// accept one (AC-FR-S-A-4-3, DEG-S-4).
    private var typesToShare: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        types.insert(HKQuantityType(.distanceWalkingRunning))
        types.insert(HKQuantityType(.activeEnergyBurned))
        types.insert(HKSeriesType.workoutRoute())
        return types
    }

    /// Reading height, so the step-length model can be offered the runner's own rather than
    /// asking for it twice (AC-FR-S-G-1-1).
    private var typesToRead: Set<HKObjectType> {
        [HKQuantityType(.height)]
    }

    func requestAuthorization() async -> AuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        do {
            try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
        } catch {
            return .denied
        }
        // `authorizationStatus(for:)` is the only thing that can be asked afterwards, and
        // it deliberately does not report *read* permission — Apple treats that as private.
        // Share status is what this call needs, and it is what decides whether the run
        // says "Health is not being written" (AC-FR-S-A-4-4).
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
            ? .authorized : .denied
    }

    func save(
        startedAt: Date,
        endedAt: Date,
        distanceMetres: Double,
        activeSeconds: TimeInterval,
        route: [RoutePoint],
        events: [WorkoutEventMark]
    ) async throws -> UUID? {
        guard HKHealthStore.isHealthDataAvailable(),
            store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        else { return nil }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = route.isEmpty ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store, configuration: configuration, device: .local())

        try await builder.beginCollection(at: startedAt)

        if distanceMetres > 0 {
            let quantity = HKQuantity(unit: .meter(), doubleValue: distanceMetres)
            try await builder.addSamples([
                HKQuantitySample(
                    type: HKQuantityType(.distanceWalkingRunning),
                    quantity: quantity,
                    start: startedAt,
                    end: endedAt)
            ])
        }

        // AC-FR-S-A-4-2 — step boundaries as workout events, so an interval session done
        // standalone is as legible in Health as one done on the watch. `.segment` rather
        // than `.marker`: a segment carries a duration, which is what a rep is.
        if !events.isEmpty {
            let markers = segments(from: events, startedAt: startedAt, endedAt: endedAt)
            if !markers.isEmpty { try await builder.addWorkoutEvents(markers) }
        }

        try await builder.endCollection(at: endedAt)
        // `finishWorkout()`'s async form is `ios(17.0)`-and-later on the *concurrency*
        // overload only in some SDKs; the completion form is available on every SDK this
        // app builds against, so it is bridged here rather than depending on which
        // overload the toolchain resolves.
        let workout: HKWorkout? = try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: workout)
                }
            }
        }
        guard let workout else { return nil }

        if !route.isEmpty {
            // A failed route write must not lose the workout, which has already been
            // saved. A run with no map is a lesser record; a run that vanished because its
            // map failed is a lost one.
            try? await saveRoute(route, for: workout)
        }

        return workout.uuid
    }

    // MARK: - Private

    /// Turns the step marks into `HKWorkoutEvent` segments spanning each step.
    ///
    /// The marks record where each step *began*; a segment needs an end, which is the next
    /// mark's start or the run's end. Deriving it here rather than recording both means the
    /// run controller cannot emit a pair that disagrees with itself.
    private func segments(
        from events: [WorkoutEventMark], startedAt: Date, endedAt: Date
    ) -> [HKWorkoutEvent] {
        let sorted = events.sorted { $0.atSeconds < $1.atSeconds }
        return sorted.enumerated().compactMap { index, mark in
            let start = startedAt.addingTimeInterval(mark.atSeconds)
            let end = index + 1 < sorted.count
                ? startedAt.addingTimeInterval(sorted[index + 1].atSeconds)
                : endedAt
            guard end > start else { return nil }
            return HKWorkoutEvent(
                type: .segment,
                dateInterval: DateInterval(start: start, end: end),
                metadata: [
                    // Non-standard keys, deliberately prefixed. HealthKit has no vocabulary
                    // for "this was the recovery leg of rep 3", and inventing one under a
                    // bare name would collide with whatever Apple adds later.
                    "ORStepKind": mark.kind.rawValue,
                    "ORRepIndex": mark.repIndex,
                    "ORRepCount": mark.repCount,
                ])
        }
    }

    private func saveRoute(_ route: [RoutePoint], for workout: HKWorkout) async throws {
        let builder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let locations = route.map { point in
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude, longitude: point.longitude),
                altitude: point.altitudeMetres,
                // The route's own accuracy is not carried on `RoutePoint` — the engine
                // discarded it once the fix was accepted — so a nominal value is declared
                // rather than a fabricated precise one. HealthKit requires non-negative
                // accuracies for a route point to be accepted at all.
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                timestamp: Date(timeIntervalSince1970: point.timestamp))
        }
        guard !locations.isEmpty else { return }
        try await builder.insertRouteData(locations)
        _ = try await builder.finishRoute(with: workout, metadata: nil)
    }
}

// MARK: - Height

/// Reads the runner's height from Health, so the step-length model does not have to ask for
/// something the phone already knows (AC-FR-S-G-1-1).
///
/// Separate from the writer because it is a *read* and the two have different authorization
/// consequences: a runner may decline to share workouts and still be happy to have their
/// height read, and vice versa. Bundling them would make one refusal look like both.
enum HealthKitHeightReader {

    /// The stored height in metres, or `nil` when unavailable or not permitted.
    ///
    /// `nil` covers "declined" and "never entered" identically, and that is correct: both
    /// mean the app has not been told, and AC-FR-S-B-4-6 has one documented behaviour for
    /// that case rather than two.
    static func height(store: HKHealthStore = HKHealthStore()) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let type = HKQuantityType(.height)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                ]
            ) { _, samples, _ in
                let metres = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: .meter())
                continuation.resume(returning: metres)
            }
            store.execute(query)
        }
    }
}
