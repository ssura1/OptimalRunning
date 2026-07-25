import Foundation
import ORModels
import ORStats
import SwiftData

/// A workout as HealthKit knows it, reduced to primitives.
///
/// Deliberately free of `HKWorkout` so the reconstruction logic is testable without a device
/// or an authorized store — the same split as `WorkoutBackend` on the watch. The real adapter
/// lives in the app target and holds no decisions.
public struct HealthWorkout: Sendable, Hashable {
    public let workoutUUID: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let distanceMetres: Double
    /// HealthKit's own active duration, which already excludes pauses.
    public let activeSeconds: TimeInterval
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let route: [RoutePoint]?

    public init(
        workoutUUID: UUID,
        startedAt: Date,
        endedAt: Date,
        distanceMetres: Double,
        activeSeconds: TimeInterval,
        averageHeartRate: Double? = nil,
        maxHeartRate: Double? = nil,
        route: [RoutePoint]? = nil
    ) {
        self.workoutUUID = workoutUUID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.route = route
    }
}

/// Where workouts come from. Implemented over `HKHealthStore` in the app target.
public protocol HealthWorkoutSource: Sendable {
    /// Running workouts that started within the window, oldest first.
    func runningWorkouts(from: Date, to: Date) async throws -> [HealthWorkout]
}

/// What a backfill pass did.
public struct BackfillReport: Sendable, Hashable {
    /// Runs created as degraded records because no payload ever arrived.
    public var created: [UUID] = []
    /// Workouts skipped because a complete record already existed.
    public var skippedComplete: [UUID] = []
    /// Workouts skipped because a degraded record already existed for them.
    public var skippedExistingDegraded: [UUID] = []

    public var isEmpty: Bool {
        created.isEmpty && skippedComplete.isEmpty && skippedExistingDegraded.isEmpty
    }
}

/// Reconstructs runs from HealthKit when no sidecar arrived (T-051, AC-FR-E-1-6, DEG-4).
///
/// **The invariant this type exists to protect: a backfill must never overwrite better data.**
/// A degraded record has distance, duration, heart rate and a route, and is missing everything
/// the engine decided — no zone timeline, no grade, no targets, no per-rep table. Letting one
/// replace a complete record would destroy data that cannot be recovered from HealthKit,
/// silently, and the user would only notice when a run's charts had gone blank.
///
/// Two orderings matter, and the second is the one a naive implementation gets wrong:
///
/// 1. **Backfill first, sidecar never arrives.** The degraded record stands. This is the case
///    the requirement is written for.
/// 2. **Backfill first, sidecar arrives later.** The complete payload must *replace* the
///    degraded placeholder — same `runID`, so the upsert path handles it and clears
///    `isDegraded`. The trap is matching: a backfilled record is keyed by a `runID` this app
///    invented, while the sidecar carries the watch's own `runID`. Without reconciling them by
///    `healthKitWorkoutUUID` the store ends up with *two* records for one run — a degraded one
///    and a complete one — which is worse than either failure alone, because lifetime totals
///    then count the run twice.
public struct BackfillService {

    private let context: ModelContext
    private let runs: RunRepository
    private let aggregates: AggregateRepository

    public init(context: ModelContext) {
        self.context = context
        self.runs = RunRepository(context: context)
        self.aggregates = AggregateRepository(context: context)
    }

    // MARK: - Backfilling

    /// Creates degraded records for workouts that have no run.
    ///
    /// Runs oldest-first so the aggregate cache accumulates in chronological order, matching
    /// what a rebuild would produce.
    @discardableResult
    public func backfill(
        from source: HealthWorkoutSource,
        window: (from: Date, to: Date),
        now: Date = Date()
    ) async throws -> BackfillReport {
        var report = BackfillReport()
        let workouts = try await source.runningWorkouts(from: window.from, to: window.to)

        for workout in workouts.sorted(by: { $0.startedAt < $1.startedAt }) {
            switch try classify(workout) {
            case .alreadyComplete:
                report.skippedComplete.append(workout.workoutUUID)
            case .alreadyDegraded:
                report.skippedExistingDegraded.append(workout.workoutUUID)
            case .needsBackfill:
                let record = try create(from: workout, now: now)
                try aggregates.apply(
                    summary: record.summary,
                    startedAt: record.startedAt,
                    // No samples exist, so no in-run best effort can be claimed. A backfilled
                    // run must not set a personal best: HealthKit gives whole-run totals only,
                    // and awarding a 5 k PB from an average pace over 10 km would be fiction.
                    samples: nil
                )
                report.created.append(workout.workoutUUID)
            }
        }
        return report
    }

    private enum Classification {
        case alreadyComplete
        case alreadyDegraded
        case needsBackfill
    }

    private func classify(_ workout: HealthWorkout) throws -> Classification {
        guard let existing = try record(forWorkout: workout.workoutUUID) else {
            return .needsBackfill
        }
        return existing.isDegraded ? .alreadyDegraded : .alreadyComplete
    }

    /// Finds any record — degraded or complete — already representing this workout.
    ///
    /// Matched on `healthKitWorkoutUUID`, which is the only identifier the two sources share:
    /// the watch stamps it into the envelope, and HealthKit owns it. Matching on start time
    /// instead would be a guess that breaks on a re-imported workout or a clock adjustment.
    func record(forWorkout workoutUUID: UUID) throws -> RunRecord? {
        var descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == workoutUUID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func create(from workout: HealthWorkout, now: Date) throws -> RunRecord {
        let encoder = RunEnvelopeCoder.makeEncoder()
        let pace = Pace(distanceMetres: workout.distanceMetres, seconds: workout.activeSeconds)

        let record = RunRecord(
            // A fresh identifier, because the watch's `runID` for this run is unknowable —
            // the payload that carried it is gone. `healthKitWorkoutUUID` is what links this
            // record back to reality, and what a later sidecar is reconciled against.
            runID: UUID(),
            startedAt: workout.startedAt,
            endedAt: workout.endedAt,
            // The run type is genuinely unknown: HealthKit records "running", not "tempo".
            // Defaulting to `.easy` would assert something false about the user's training, so
            // this is flagged degraded and the detail view says the type is unknown.
            runTypeRaw: RunType.easy.rawValue,
            deviceTierRaw: DeviceTier.modern.rawValue,
            distanceMetres: workout.distanceMetres,
            activeSeconds: workout.activeSeconds,
            averagePaceSecondsPerMetre: pace?.secondsPerMetre ?? 0,
            averageHeartRate: workout.averageHeartRate,
            maxHeartRate: workout.maxHeartRate,
            // HealthKit's workout totals carry no elevation series here, and inventing 0 would
            // read as "flat" rather than "unknown". It is reported as 0 with the
            // `altimeterUnavailable` flag set, which is what the detail view reads to hide the
            // elevation chart rather than draw a flat line (T-057).
            elevationGainMetres: 0,
            // No zone timeline exists. An array of zeroes is correct here rather than empty:
            // the zone chart reads it, and every zone genuinely holds zero seconds because
            // nothing was ever judged.
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count),
            packedSamples: nil,
            routeData: try workout.route.flatMap { $0.isEmpty ? nil : try encoder.encode($0) },
            zoneTimelineData: nil,
            configSnapshotData: nil,
            profileSnapshotData: nil,
            planData: nil,
            isDegraded: true,
            degradationFlags: [
                DegradationFlag.altimeterUnavailable.rawValue,
                DegradationFlag.noTargetPace.rawValue,
            ],
            healthKitWorkoutUUID: workout.workoutUUID,
            ingestedAt: now
        )

        context.insert(record)
        try context.save()
        return record
    }

    // MARK: - Reconciliation

    /// Removes a degraded placeholder superseded by a complete payload for the same workout.
    ///
    /// Called by the ingest path *before* it stores a payload. The complete record arrives
    /// under the watch's own `runID`, so without this the store keeps both and every lifetime
    /// total counts the run twice — the failure that is worse than either half alone.
    ///
    /// Returns the summary that was withdrawn, so the caller can back it out of the aggregate
    /// cache. Returning it rather than doing it here keeps the whole replacement inside the
    /// caller's single transaction.
    @discardableResult
    public func removeSupersededPlaceholder(
        for envelope: RunEnvelope
    ) throws -> (summary: RunSummary, startedAt: Date)? {
        guard let workoutUUID = envelope.healthKitWorkoutUUID,
              let placeholder = try record(forWorkout: workoutUUID),
              placeholder.isDegraded,
              // The payload might *be* this record, re-delivered — in which case the upsert
              // path updates it in place and there is nothing to remove.
              placeholder.runID != envelope.runID
        else { return nil }

        let withdrawn = (summary: placeholder.summary, startedAt: placeholder.startedAt)
        context.delete(placeholder)
        try context.save()
        return withdrawn
    }
}
