import Foundation
import ORIntervals
import ORModels
import ORStats
import SwiftData

/// Builds the model container (T-053).
public enum RunStoreContainer {

    /// The on-disk container the app uses.
    public static func make(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map {
            ModelConfiguration(schema: Schema(RunStoreSchema.models), url: $0)
        } ?? ModelConfiguration(schema: Schema(RunStoreSchema.models))

        return try ModelContainer(
            for: Schema(RunStoreSchema.models),
            migrationPlan: RunStoreSchema.MigrationPlan.self,
            configurations: configuration
        )
    }

    /// An in-memory container, for tests and previews.
    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(RunStoreSchema.models),
            configurations: ModelConfiguration(schema: Schema(RunStoreSchema.models), isStoredInMemoryOnly: true)
        )
    }
}

// MARK: - Errors

public enum RunStoreError: Error, Equatable, Sendable {
    case decodingFailed(field: String)
}

// MARK: - Run repository

/// Reads and writes runs (T-053).
///
/// **The fetch methods are deliberately split by what they load.** `listItems()` reads only
/// the denormalized scalar columns; `detail(for:)` is the only path that touches the sample
/// blob. That split is the whole reason `.externalStorage` buys anything: a repository with
/// one "fetch runs" method returning fully-hydrated models would page every blob in on the
/// list screen and the attribute would be decoration.
public struct RunRepository {

    // Deliberately not `Sendable`: it holds a `ModelContext`, which is bound to the actor
    // that created it. Claiming `Sendable` would let a repository be passed across
    // isolation domains, and SwiftData contexts are exactly the thing that must not be —
    // the compiler is right to refuse.


    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: Upsert

    /// Inserts or updates by `runID` — the idempotency key (AC-FR-E-1-3, NFR-13).
    ///
    /// Mutating the existing record rather than delete-and-insert. A delete would cascade
    /// to `steps` and, more importantly, would briefly leave no record at all: a reader
    /// mid-transaction would see the run vanish, and a crash between the two halves would
    /// lose it permanently. Re-delivery is routine, so this path has to be safe when it
    /// happens twice.
    @discardableResult
    public func upsert(_ envelope: RunEnvelope, now: Date = Date()) throws -> RunRecord {
        let existing = try record(for: envelope.runID)

        let encoder = RunEnvelopeCoder.makeEncoder()
        let record = existing ?? RunRecord(
            runID: envelope.runID,
            startedAt: envelope.startedAt,
            endedAt: envelope.endedAt,
            runTypeRaw: envelope.runType.rawValue,
            deviceTierRaw: envelope.deviceTier.rawValue,
            distanceMetres: 0,
            activeSeconds: 0,
            averagePaceSecondsPerMetre: 0,
            averageHeartRate: nil,
            maxHeartRate: nil,
            elevationGainMetres: 0,
            timeInZoneSeconds: []
        )

        record.startedAt = envelope.startedAt
        record.endedAt = envelope.endedAt
        record.runTypeRaw = envelope.runType.rawValue
        record.deviceTierRaw = envelope.deviceTier.rawValue

        record.distanceMetres = envelope.summary.distanceMetres
        record.activeSeconds = envelope.summary.activeSeconds
        record.averagePaceSecondsPerMetre = envelope.summary.averagePace?.secondsPerMetre ?? 0
        record.averageHeartRate = envelope.summary.averageHeartRate
        record.maxHeartRate = envelope.summary.maxHeartRate
        record.elevationGainMetres = envelope.summary.elevationGainMetres
        record.timeInZoneSeconds = envelope.summary.timeInZoneSeconds

        record.packedSamples = try encoder.encode(envelope.samples)
        record.routeData = try envelope.route.map { try encoder.encode($0) }
        record.zoneTimelineData = try encoder.encode(envelope.zoneTimeline)
        record.configSnapshotData = try encoder.encode(envelope.configSnapshot)
        record.profileSnapshotData = try encoder.encode(envelope.profileSnapshot)
        record.planData = try envelope.plan.map { try encoder.encode($0) }

        // A complete payload clears the degraded flag: this is the sidecar arriving after a
        // backfill created a placeholder, and the whole point is that the real data wins
        // (T-051).
        record.isDegraded = false
        record.degradationFlags = envelope.degradations.map(\.rawValue)
        record.healthKitWorkoutUUID = envelope.healthKitWorkoutUUID
        record.sourceSchemaVersion = envelope.schemaVersion
        record.ingestedAt = now

        // Steps are replaced wholesale. They are derived entirely from the payload, so
        // merging them would mean reconciling two lists that should be identical, and any
        // mismatch would be a bug in the merge rather than data worth preserving.
        for step in record.steps { context.delete(step) }
        record.steps = envelope.steps.map { summary in
            StepRecord(
                index: summary.index,
                kindRaw: summary.kind.rawValue,
                repIndex: summary.repIndex,
                repCount: summary.repCount,
                distanceMetres: summary.distanceMetres,
                activeSeconds: summary.activeSeconds,
                averagePaceSecondsPerMetre: summary.averagePace?.secondsPerMetre ?? 0,
                averageHeartRate: summary.averageHeartRate,
                maxHeartRate: summary.maxHeartRate,
                elevationChangeMetres: summary.elevationChangeMetres
            )
        }

        if existing == nil { context.insert(record) }
        try context.save()
        return record
    }

    // MARK: Fetching

    public func record(for runID: UUID) throws -> RunRecord? {
        var descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.runID == runID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func count() throws -> Int {
        try context.fetchCount(FetchDescriptor<RunRecord>())
    }

    /// The run list's fetch (FR-F-1).
    ///
    /// `propertiesToFetch` names only the scalar columns. Note what this does and does not
    /// buy, because the obvious claim for it is wrong: external blobs are lazy *anyway* —
    /// a fetch that never touches `packedSamples` never reads it, verified by deleting every
    /// external file and watching this method still return complete rows. What
    /// `propertiesToFetch` actually contributes is a measured ~2× on the fetch itself
    /// (0.09 s versus 0.19 s over 1 000 rows), by not materialising columns nothing projects.
    ///
    /// The blob-avoidance guarantee therefore comes from `.externalStorage` plus never
    /// touching the property, and `RunListItem` being a value type is what enforces the
    /// second half — a caller handed a projection cannot accidentally fault a blob in.
    public func listItems(
        filter: RunListFilter = .init(),
        limit: Int? = nil
    ) throws -> [RunListItem] {
        var descriptor = FetchDescriptor<RunRecord>(
            predicate: filter.predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \.runID, \.startedAt, \.endedAt, \.runTypeRaw,
            \.distanceMetres, \.activeSeconds, \.averagePaceSecondsPerMetre,
            \.averageHeartRate, \.maxHeartRate, \.isDegraded,
        ]
        if let limit { descriptor.fetchLimit = limit }

        return try context.fetch(descriptor).map(RunListItem.init(record:))
    }

    /// Every run's summary, oldest first — what a full aggregate rebuild consumes.
    public func allSummaries() throws -> [(runID: UUID, startedAt: Date, summary: RunSummary)] {
        var descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [
            \.runID, \.startedAt, \.distanceMetres, \.activeSeconds,
            \.averagePaceSecondsPerMetre, \.averageHeartRate, \.maxHeartRate,
            \.elevationGainMetres, \.timeInZoneSeconds,
        ]
        return try context.fetch(descriptor).map { ($0.runID, $0.startedAt, $0.summary) }
    }

    public func delete(runID: UUID) throws {
        guard let record = try record(for: runID) else { return }
        context.delete(record)
        try context.save()
    }
}

// MARK: - List projections

/// One row of the run list. A value type, so a list of 1 000 of these carries no managed
/// objects and no blobs.
public struct RunListItem: Sendable, Hashable, Identifiable {
    public let runID: UUID
    public var id: UUID { runID }
    public let startedAt: Date
    public let endedAt: Date
    public let runType: RunType
    public let distanceMetres: Double
    public let activeSeconds: Double
    public let averagePace: Pace?
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let isDegraded: Bool

    init(record: RunRecord) {
        runID = record.runID
        startedAt = record.startedAt
        endedAt = record.endedAt
        runType = RunType(rawValue: record.runTypeRaw) ?? .easy
        distanceMetres = record.distanceMetres
        activeSeconds = record.activeSeconds
        averagePace = record.averagePaceSecondsPerMetre > 0
            ? Pace(secondsPerMetre: record.averagePaceSecondsPerMetre) : nil
        averageHeartRate = record.averageHeartRate
        maxHeartRate = record.maxHeartRate
        isDegraded = record.isDegraded
    }
}

/// Run-list filters (AC-FR-F-1-4/5). Combined with `AND`, so a type filter and a date range
/// narrow together rather than either winning.
public struct RunListFilter: Sendable, Hashable {
    public var runTypes: Set<RunType>
    public var from: Date?
    public var to: Date?

    public init(runTypes: Set<RunType> = [], from: Date? = nil, to: Date? = nil) {
        self.runTypes = runTypes
        self.from = from
        self.to = to
    }

    public var isEmpty: Bool { runTypes.isEmpty && from == nil && to == nil }

    /// Built as a `#Predicate` so filtering happens in the store rather than in memory.
    /// Filtering after fetching would defeat `propertiesToFetch` — every row would be
    /// materialised to be discarded.
    var predicate: Predicate<RunRecord>? {
        guard !isEmpty else { return nil }
        let raws = Set(runTypes.map(\.rawValue))
        let hasTypes = !raws.isEmpty
        let from = from
        let to = to

        return #Predicate<RunRecord> { record in
            (!hasTypes || raws.contains(record.runTypeRaw))
                && (from == nil || record.startedAt >= from!)
                && (to == nil || record.startedAt <= to!)
        }
    }
}

// MARK: - Decoding stored blobs

extension RunRecord {

    public var runType: RunType { RunType(rawValue: runTypeRaw) ?? .easy }
    public var deviceTier: DeviceTier { DeviceTier(rawValue: deviceTierRaw) ?? .modern }

    /// The denormalized totals, rebuilt as a `RunSummary` for `Core`'s aggregate types.
    public var summary: RunSummary {
        RunSummary(
            distanceMetres: distanceMetres,
            activeSeconds: activeSeconds,
            averagePace: averagePaceSecondsPerMetre > 0
                ? Pace(secondsPerMetre: averagePaceSecondsPerMetre) : nil,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            elevationGainMetres: elevationGainMetres,
            timeInZoneSeconds: timeInZoneSeconds
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?, field: String) throws -> T? {
        guard let data else { return nil }
        do {
            return try RunEnvelopeCoder.makeDecoder().decode(type, from: data)
        } catch {
            throw RunStoreError.decodingFailed(field: field)
        }
    }

    public func samples() throws -> [RunSample]? {
        guard let packed = try decode(PackedSamples.self, from: packedSamples, field: "packedSamples")
        else { return nil }
        return packed.unpack()
    }

    public func route() throws -> [RoutePoint]? {
        try decode([RoutePoint].self, from: routeData, field: "routeData")
    }

    public func zoneTimeline() throws -> [ZoneSpan] {
        try decode([ZoneSpan].self, from: zoneTimelineData, field: "zoneTimelineData") ?? []
    }

    public func configSnapshot() throws -> PaceEngineConfiguration? {
        try decode(PaceEngineConfiguration.self, from: configSnapshotData, field: "configSnapshotData")
    }

    public func profileSnapshot() throws -> RunnerProfile? {
        try decode(RunnerProfile.self, from: profileSnapshotData, field: "profileSnapshotData")
    }

    public func plan() throws -> WorkoutPlan? {
        try decode(WorkoutPlan.self, from: planData, field: "planData")
    }

    public var stepSummaries: [StepSummary] {
        steps
            .sorted { $0.index < $1.index }
            .map { step in
                StepSummary(
                    index: step.index,
                    kind: StepKind(rawValue: step.kindRaw) ?? .work,
                    repIndex: step.repIndex,
                    repCount: step.repCount,
                    distanceMetres: step.distanceMetres,
                    activeSeconds: step.activeSeconds,
                    averagePace: step.averagePaceSecondsPerMetre > 0
                        ? Pace(secondsPerMetre: step.averagePaceSecondsPerMetre) : nil,
                    averageHeartRate: step.averageHeartRate,
                    maxHeartRate: step.maxHeartRate,
                    elevationChangeMetres: step.elevationChangeMetres
                )
            }
    }
}
