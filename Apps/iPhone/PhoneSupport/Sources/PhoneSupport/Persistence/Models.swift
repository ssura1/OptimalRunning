import Foundation
import ORIntervals
import ORModels
import SwiftData

// MARK: - Run

/// A stored run (design.md §9.3).
///
/// **Everything the run list and the aggregates need is denormalized onto this record and
/// never recomputed from samples.** That is the design constraint the whole screen budget
/// rests on: `@Attribute(.externalStorage)` keeps the sample blob in a separate file, so a
/// fetch that touches only these scalar columns never pages ~100 KB per run off disk.
/// Deriving `distanceMetres` from `packedSamples` on demand would look tidier and would
/// turn a 1 000-run list into 100 MB of I/O (AC-FR-F-1-3, NFR-5).
///
/// Enums are stored as their raw values rather than as Swift enums. SwiftData can persist
/// `RawRepresentable` enums, but doing so couples the store's schema to the *case list* —
/// adding a `RunType` case would then be a schema migration rather than a code change.
/// Storing the raw value keeps that decision in one mapping layer.
@Model
public final class RunRecord {

    @Attribute(.unique) public var runID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var runTypeRaw: String
    public var deviceTierRaw: String

    // Denormalized for list and aggregate queries.
    public var distanceMetres: Double
    public var activeSeconds: Double
    public var averagePaceSecondsPerMetre: Double
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    public var elevationGainMetres: Double
    /// Seconds per zone, indexed by `PaceZone.rawValue`.
    public var timeInZoneSeconds: [Double]

    /// The columnar sample blob. External storage is what keeps it out of the list query.
    @Attribute(.externalStorage) public var packedSamples: Data?
    /// The route, JSON-encoded. Also external: a 90-minute run's route is tens of KB and
    /// only the detail map ever reads it.
    @Attribute(.externalStorage) public var routeData: Data?
    /// The run-length-encoded zone timeline, JSON-encoded. Small enough to live inline,
    /// and the detail view always wants it.
    public var zoneTimelineData: Data?
    /// `StandaloneRunFacts`, JSON-encoded. `nil` for every watch-originated run
    /// (AC-FR-S-A-4-5).
    ///
    /// Inline rather than external: it is a few hundred bytes and the detail view always
    /// reads it for a standalone run. Optional rather than a second record type, because
    /// FR-S-E-1-4 forbids a second store and a nullable column is what "the same record,
    /// with more known about it" looks like.
    public var standaloneData: Data?

    /// Snapshots, so a run stays interpretable against the settings that were in force
    /// (design.md §9.1). Not external: the detail view reads them to draw the band.
    public var configSnapshotData: Data?
    public var profileSnapshotData: Data?
    public var planData: Data?

    /// True when the record was reconstructed from HealthKit because no payload arrived
    /// (AC-FR-E-1-6). The detail view says what is missing rather than drawing empty
    /// charts.
    public var isDegraded: Bool
    public var degradationFlags: [String]

    public var healthKitWorkoutUUID: UUID?
    /// Schema version of the envelope this came from, for diagnosing a bad import later.
    public var sourceSchemaVersion: Int
    /// When this record was last written. Used to tell a backfill whether it would be
    /// overwriting fresher data.
    public var ingestedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \StepRecord.run)
    public var steps: [StepRecord]

    public init(
        runID: UUID,
        startedAt: Date,
        endedAt: Date,
        runTypeRaw: String,
        deviceTierRaw: String,
        distanceMetres: Double,
        activeSeconds: Double,
        averagePaceSecondsPerMetre: Double,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        elevationGainMetres: Double,
        timeInZoneSeconds: [Double],
        packedSamples: Data? = nil,
        routeData: Data? = nil,
        zoneTimelineData: Data? = nil,
        standaloneData: Data? = nil,
        configSnapshotData: Data? = nil,
        profileSnapshotData: Data? = nil,
        planData: Data? = nil,
        isDegraded: Bool = false,
        degradationFlags: [String] = [],
        healthKitWorkoutUUID: UUID? = nil,
        sourceSchemaVersion: Int = RunEnvelope.currentSchemaVersion,
        ingestedAt: Date = Date(),
        steps: [StepRecord] = []
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.runTypeRaw = runTypeRaw
        self.deviceTierRaw = deviceTierRaw
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.averagePaceSecondsPerMetre = averagePaceSecondsPerMetre
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.elevationGainMetres = elevationGainMetres
        self.timeInZoneSeconds = timeInZoneSeconds
        self.packedSamples = packedSamples
        self.routeData = routeData
        self.zoneTimelineData = zoneTimelineData
        self.standaloneData = standaloneData
        self.configSnapshotData = configSnapshotData
        self.profileSnapshotData = profileSnapshotData
        self.planData = planData
        self.isDegraded = isDegraded
        self.degradationFlags = degradationFlags
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.ingestedAt = ingestedAt
        self.steps = steps
    }
}

// MARK: - Step

/// One completed step of a structured workout (AC-FR-F-2-6).
@Model
public final class StepRecord {

    public var index: Int
    public var kindRaw: String
    public var repIndex: Int
    public var repCount: Int
    public var distanceMetres: Double
    public var activeSeconds: Double
    public var averagePaceSecondsPerMetre: Double
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    public var elevationChangeMetres: Double

    public var run: RunRecord?

    public init(
        index: Int,
        kindRaw: String,
        repIndex: Int,
        repCount: Int,
        distanceMetres: Double,
        activeSeconds: Double,
        averagePaceSecondsPerMetre: Double,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        elevationChangeMetres: Double
    ) {
        self.index = index
        self.kindRaw = kindRaw
        self.repIndex = repIndex
        self.repCount = repCount
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.averagePaceSecondsPerMetre = averagePaceSecondsPerMetre
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.elevationChangeMetres = elevationChangeMetres
    }
}

// MARK: - Profile

/// The runner's stored profile (FR-I-1).
///
/// A single row, held as one record rather than as loose `UserDefaults` keys so it can be
/// snapshotted, migrated, and read transactionally alongside the runs it applies to.
@Model
public final class RunnerProfileRecord {

    /// There is exactly one of these. A stable ID makes "fetch or create" a lookup rather
    /// than a fetch-all-and-hope.
    @Attribute(.unique) public var id: String
    public var profileData: Data
    /// Fitness estimate, when derived (design.md §14.1). Absent until enough runs exist.
    public var fitnessScore: Double?
    /// Set once the medical disclaimer has been acknowledged (R-6). Plan generation stays
    /// unreachable until it is.
    public var disclaimerAcknowledgedAt: Date?
    public var updatedAt: Date

    public static let singletonID = "runner-profile"

    public init(
        id: String = RunnerProfileRecord.singletonID,
        profileData: Data,
        fitnessScore: Double? = nil,
        disclaimerAcknowledgedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileData = profileData
        self.fitnessScore = fitnessScore
        self.disclaimerAcknowledgedAt = disclaimerAcknowledgedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Aggregates

/// The incrementally-maintained totals behind the statistics screen (NFR-5).
///
/// Stored as one encoded `AggregateCache` rather than as a table of period rows. The cache
/// is a value type in `Core` that already knows how to apply and remove a run, and keeping
/// it whole means the phone cannot drift from `rebuildAll()` through a partially-applied
/// update — either the encoded blob is the result of the full operation sequence or it is
/// not, and a test can assert exactly that.
@Model
public final class AggregateCacheRecord {

    @Attribute(.unique) public var id: String
    @Attribute(.externalStorage) public var cacheData: Data
    public var updatedAt: Date

    public static let singletonID = "aggregate-cache"

    public init(
        id: String = AggregateCacheRecord.singletonID,
        cacheData: Data,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.cacheData = cacheData
        self.updatedAt = updatedAt
    }
}

// MARK: - Planned workout

/// A workout scheduled for a date (T-050's wire format, persisted).
///
/// Nothing generates these yet — plan generation is Wave 5. The model exists so the
/// downlink has somewhere to land and so the schema does not need migrating when it does.
@Model
public final class PlannedWorkoutRecord {

    @Attribute(.unique) public var id: UUID
    public var scheduledFor: Date
    public var planData: Data
    public var notes: String?
    /// Set when a run completes against this plan item.
    public var completedByRunID: UUID?

    public init(
        id: UUID,
        scheduledFor: Date,
        planData: Data,
        notes: String? = nil,
        completedByRunID: UUID? = nil
    ) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.planData = planData
        self.notes = notes
        self.completedByRunID = completedByRunID
    }
}

// MARK: - Schema

/// The store's schema, versioned from the start (T-053).
///
/// A migration plan exists with one version in it deliberately. Adding the plan later,
/// once real user data exists, means the first migration has to reconstruct what v1 looked
/// like from memory; declaring it now means every future change has a named predecessor.
public enum RunStoreSchema {

    public static let models: [any PersistentModel.Type] = [
        RunRecord.self,
        StepRecord.self,
        RunnerProfileRecord.self,
        AggregateCacheRecord.self,
        PlannedWorkoutRecord.self,
    ]

    public enum V1: VersionedSchema {
        public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
        public static var models: [any PersistentModel.Type] { RunStoreSchema.models }
    }

    public enum MigrationPlan: SchemaMigrationPlan {
        public static var schemas: [any VersionedSchema.Type] { [V1.self] }
        public static var stages: [MigrationStage] { [] }
    }
}
