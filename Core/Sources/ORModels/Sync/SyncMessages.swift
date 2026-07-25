import Foundation

// MARK: - Uplink metadata

/// The metadata dictionary that rides alongside a transferred payload file.
///
/// `WCSession.transferFile(_:metadata:)` takes a `[String: Any]` restricted to plist
/// types, so this is expressed as a flat string dictionary rather than encoded JSON.
/// It exists so the receiver can read `runID` and `schemaVersion` *without opening the
/// file* — which is what lets a future-schema payload be refused (AC-FR-E-1-4) before
/// anything tries to decode types it has never heard of.
public struct SyncFileMetadata: Sendable, Hashable {

    public static let runIDKey = "runID"
    public static let schemaVersionKey = "schemaVersion"

    public let runID: UUID
    public let schemaVersion: Int

    public init(runID: UUID, schemaVersion: Int = RunEnvelope.currentSchemaVersion) {
        self.runID = runID
        self.schemaVersion = schemaVersion
    }

    public var dictionary: [String: String] {
        [
            Self.runIDKey: runID.uuidString,
            Self.schemaVersionKey: String(schemaVersion),
        ]
    }

    /// Parses transfer metadata. Returns `nil` for anything unreadable — a payload
    /// whose metadata cannot be understood is not a payload this build can route, and
    /// guessing a `runID` would risk overwriting an unrelated record.
    public init?(dictionary: [String: Any]) {
        guard let runIDString = dictionary[Self.runIDKey] as? String,
              let runID = UUID(uuidString: runIDString)
        else { return nil }

        // Accepts a string or a number: `WCSession` metadata round-trips plist types,
        // and an `Int` written on one side can arrive as `NSNumber`.
        let version: Int?
        switch dictionary[Self.schemaVersionKey] {
        case let text as String: version = Int(text)
        case let number as Int: version = number
        case let number as NSNumber: version = number.intValue
        default: version = nil
        }
        guard let version else { return nil }

        self.runID = runID
        self.schemaVersion = version
    }
}

// MARK: - Downlink

/// Why the phone refused a payload.
///
/// A closed enum rather than a free-text string: the watch acts differently on each —
/// an unsupported schema means "stop retrying, this build will never accept it", while
/// a malformed payload means "the bytes were damaged, the run is lost". Prose would
/// have to be parsed to tell those apart.
public enum SyncRejection: String, Codable, Sendable, Hashable {
    /// The phone is older than the watch. Retrying cannot help until the phone updates.
    case unsupportedSchema
    /// Decoding failed — truncated transfer or corrupted file.
    case malformed
    /// Decoded, but the configuration snapshot is out of range.
    case invalidConfiguration
}

/// One refused run.
public struct SyncNack: Codable, Sendable, Hashable {
    public let runID: UUID
    public let reason: SyncRejection

    public init(runID: UUID, reason: SyncRejection) {
        self.runID = runID
        self.reason = reason
    }
}

/// What the phone tells the watch about payloads it has processed.
///
/// **Why this is a rolling window rather than "the run just acknowledged".**
/// `updateApplicationContext` is latest-value-wins: the system delivers only the most
/// recent context and silently discards any the watch missed while asleep. So a context
/// carrying just one `runID` would lose the acknowledgement of every run acknowledged
/// while the watch was unreachable, and those payloads would sit on the watch forever,
/// eventually filling the eviction budget with runs the phone already has. Sending the
/// recently-processed set makes the channel's lossiness harmless.
public struct SyncAcknowledgement: Codable, Sendable, Hashable {

    /// Runs the phone has durably stored. Safe for the watch to delete.
    public let acked: [UUID]
    /// Runs the phone refused, with the reason.
    public let nacked: [SyncNack]

    public init(acked: [UUID] = [], nacked: [SyncNack] = []) {
        self.acked = acked
        self.nacked = nacked
    }

    public static let empty = SyncAcknowledgement()

    public var isEmpty: Bool { acked.isEmpty && nacked.isEmpty }
}

// MARK: - Planned workout wire format

/// A workout the phone has scheduled for a date.
///
/// The wire format exists now so the downlink channel is shaped correctly, but nothing
/// *generates* these yet: plan generation is Wave 5. Carrying the shape early is
/// deliberate — retrofitting a field into a latest-value-wins channel that older builds
/// already parse is far more awkward than reserving it — but no UI presents one and no
/// fixture fabricates one, because a fake planned workout on the start screen would be
/// a feature the product does not have.
public struct PlannedWorkoutDescriptor: Codable, Sendable, Hashable {
    public let id: UUID
    /// The day this is scheduled for. Compared by calendar day, not instant.
    public let scheduledFor: Date
    public let plan: WorkoutPlan
    public let notes: String?

    public init(id: UUID, scheduledFor: Date, plan: WorkoutPlan, notes: String? = nil) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.plan = plan
        self.notes = notes
    }
}

// MARK: - The single application context

/// Everything the phone pushes to the watch, in one payload.
///
/// **Why one type and not two.** design.md §10 describes two uses of
/// `updateApplicationContext` — acknowledgements travelling with the sync protocol, and
/// the profile/plan downlink — as though they were separate channels. `WCSession` has
/// exactly **one** application context per session: a second `updateApplicationContext`
/// call replaces the first wholesale rather than merging with it. Modelled as two
/// independent senders, whichever wrote last would silently erase the other's payload,
/// and the symptom would be a profile edit that intermittently fails to arrive — or,
/// worse, acknowledgements that vanish and leave the watch's queue growing. Merging
/// them into one versioned value makes that impossible to get wrong.
public struct PhoneContext: Codable, Sendable, Hashable {

    /// Monotonically increasing. The watch ignores a context whose sequence is not
    /// greater than the last one applied, so an out-of-order redelivery cannot roll the
    /// profile back to an older value.
    public let sequence: Int
    public let acknowledgement: SyncAcknowledgement
    /// The phone's current profile, or `nil` if onboarding has not produced one yet.
    /// The watch keeps operating on the last one it received (AC-FR-I-1-6).
    public let profile: RunnerProfile?
    public let plannedWorkouts: [PlannedWorkoutDescriptor]

    public init(
        sequence: Int,
        acknowledgement: SyncAcknowledgement = .empty,
        profile: RunnerProfile? = nil,
        plannedWorkouts: [PlannedWorkoutDescriptor] = []
    ) {
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.profile = profile
        self.plannedWorkouts = plannedWorkouts
    }

    /// The workout scheduled for a given day, if any (AC-FR-A-7-4).
    public func plannedWorkout(on date: Date, calendar: Calendar = .current) -> PlannedWorkoutDescriptor? {
        plannedWorkouts.first { calendar.isDate($0.scheduledFor, inSameDayAs: date) }
    }

    // MARK: Transport encoding

    /// `WCSession`'s application context is a plist dictionary, so the whole value
    /// travels as one JSON blob under a single key rather than as a flattened
    /// dictionary. Flattening would mean hand-rolling encode and decode for every
    /// nested type — `WorkoutPlan` alone is recursive — and each of those is a place to
    /// introduce a silent field drop.
    public static let payloadKey = "phoneContext"

    public func encoded() throws -> [String: Any] {
        [Self.payloadKey: try RunEnvelopeCoder.makeEncoder().encode(self)]
    }

    public init?(context: [String: Any]) {
        guard let data = context[Self.payloadKey] as? Data,
              let decoded = try? RunEnvelopeCoder.makeDecoder().decode(PhoneContext.self, from: data)
        else { return nil }
        self = decoded
    }
}
