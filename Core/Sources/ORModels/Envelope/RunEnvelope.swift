import Foundation

// MARK: - Route

/// One recorded position on the run's route.
public struct RoutePoint: Codable, Sendable, Hashable {
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let altitudeMetres: Double

    public init(timestamp: TimeInterval, latitude: Double, longitude: Double, altitudeMetres: Double) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMetres = altitudeMetres
    }
}

// MARK: - Run summary

/// Whole-run totals, denormalized so the run list and aggregates never touch the
/// sample blob (design.md §9.3).
public struct RunSummary: Codable, Sendable, Hashable {
    public let distanceMetres: Double
    public let activeSeconds: Double
    public let averagePace: Pace?
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let elevationGainMetres: Double
    /// Seconds per zone, indexed by `PaceZone.rawValue`.
    public let timeInZoneSeconds: [TimeInterval]

    public init(
        distanceMetres: Double,
        activeSeconds: Double,
        averagePace: Pace?,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        elevationGainMetres: Double,
        timeInZoneSeconds: [TimeInterval]
    ) {
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.averagePace = averagePace
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.elevationGainMetres = elevationGainMetres
        self.timeInZoneSeconds = timeInZoneSeconds
    }
}

// MARK: - Envelope

/// The versioned payload the watch sends to the phone (ADR-008, ADR-009).
///
/// The profile and configuration are **snapshotted** rather than referenced. A run
/// analysed six months later must be interpretable against the targets and thresholds
/// that were actually in force at the time, not today's — otherwise the pace chart
/// would silently redraw its band every time the runner tunes a setting.
public struct RunEnvelope: Codable, Sendable, Hashable {

    /// Bumped only for breaking changes. A reader that does not recognise the major
    /// version refuses the payload with a typed error rather than crashing
    /// (AC-FR-E-1-4).
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Idempotency key. Re-delivery of the same run must not create a second record
    /// (AC-FR-E-1-3).
    public let runID: UUID
    public let deviceTier: DeviceTier
    public let appVersion: String

    public let startedAt: Date
    public let endedAt: Date
    public let runType: RunType
    public let plan: WorkoutPlan?
    public let profileSnapshot: RunnerProfile
    public let configSnapshot: PaceEngineConfiguration

    public let healthKitWorkoutUUID: UUID?
    public let summary: RunSummary
    public let steps: [StepSummary]
    public let zoneTimeline: [ZoneSpan]
    public let samples: PackedSamples
    public let route: [RoutePoint]?
    public let degradations: [DegradationFlag]
    /// Present only for `deviceTier == .phoneStandalone` (AC-FR-S-A-4-5).
    ///
    /// Optional rather than a version bump: a synthesised `Codable` omits an absent
    /// optional's key entirely, so every payload written before this field existed —
    /// including `Fixtures/legacy-tier-envelope.payload` — still decodes, and the bytes of
    /// a watch envelope are unchanged. `RunEnvelopeCodingTests` asserts both halves rather
    /// than trusting the reasoning.
    public let standalone: StandaloneRunFacts?

    public init(
        schemaVersion: Int = RunEnvelope.currentSchemaVersion,
        runID: UUID,
        deviceTier: DeviceTier,
        appVersion: String,
        startedAt: Date,
        endedAt: Date,
        runType: RunType,
        plan: WorkoutPlan?,
        profileSnapshot: RunnerProfile,
        configSnapshot: PaceEngineConfiguration,
        healthKitWorkoutUUID: UUID?,
        summary: RunSummary,
        steps: [StepSummary],
        zoneTimeline: [ZoneSpan],
        samples: PackedSamples,
        route: [RoutePoint]?,
        degradations: [DegradationFlag],
        standalone: StandaloneRunFacts? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.deviceTier = deviceTier
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.runType = runType
        self.plan = plan
        self.profileSnapshot = profileSnapshot
        self.configSnapshot = configSnapshot
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.summary = summary
        self.steps = steps
        self.zoneTimeline = zoneTimeline
        self.samples = samples
        self.route = route
        self.degradations = degradations
        self.standalone = standalone
    }
}

// MARK: - Coding

/// Why an envelope could not be accepted.
public enum EnvelopeError: Error, Equatable, Sendable {
    /// The payload declares a schema this build does not understand. The receiver
    /// surfaces a message and keeps the payload; it never crashes and never silently
    /// drops the run (AC-FR-E-1-4).
    case unsupportedSchema(found: Int, supported: Int)
    case malformed(reason: String)
    case invalidConfiguration(ConfigurationError)
}

public enum RunEnvelopeCoder {

    /// Deterministic encoding. Sorted keys and a fixed date strategy mean the same
    /// envelope always produces the same bytes, which makes payload equality testable.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ envelope: RunEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    /// Decodes and validates. Version is checked *before* full decoding so a
    /// future-schema payload produces `unsupportedSchema` rather than an opaque
    /// key-not-found error from some nested type.
    public static func decode(_ data: Data) throws -> RunEnvelope {
        struct VersionProbe: Decodable { let schemaVersion: Int }

        let decoder = makeDecoder()

        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw EnvelopeError.malformed(reason: "missing or unreadable schemaVersion")
        }

        guard probe.schemaVersion == RunEnvelope.currentSchemaVersion else {
            throw EnvelopeError.unsupportedSchema(
                found: probe.schemaVersion,
                supported: RunEnvelope.currentSchemaVersion
            )
        }

        let envelope: RunEnvelope
        do {
            envelope = try decoder.decode(RunEnvelope.self, from: data)
        } catch {
            throw EnvelopeError.malformed(reason: String(describing: error))
        }

        do {
            try envelope.configSnapshot.validate()
        } catch let error as ConfigurationError {
            throw EnvelopeError.invalidConfiguration(error)
        }

        return envelope
    }
}
