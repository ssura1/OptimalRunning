import Foundation
import ORModels

/// A recorded motion trace — this track's equivalent of the core track's seven engine
/// fixtures, and the only input from which an accuracy claim may be made (CON-S-7).
///
/// Stored **columnar**, for the same reason `PackedSamples` is (ADR-007): a 60-minute
/// capture at 100 Hz is 360 000 samples, and a JSON array of 360 000 objects with ten
/// keys each is both enormous and absurdly slow to parse.
public struct MotionTrace: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let header: Header
    public let motion: MotionColumns
    public let locations: [RecordedFix]
    /// Apple's own pedometer output over the same session.
    ///
    /// Recorded as a **comparison baseline, never as an input**: `CMPedometer` is a black
    /// box tuned for walking whose running behaviour we have not characterised, and a
    /// black-box leg cannot be debugged from a trace (QS-2). Having it in the file means
    /// "did we beat it?" is answerable without another recording session.
    public let pedometer: [RecordedPedometerReading]
    public let marks: [Mark]

    public init(
        schemaVersion: Int = MotionTrace.currentSchemaVersion,
        header: Header,
        motion: MotionColumns,
        locations: [RecordedFix] = [],
        pedometer: [RecordedPedometerReading] = [],
        marks: [Mark] = []
    ) {
        self.schemaVersion = schemaVersion
        self.header = header
        self.motion = motion
        self.locations = locations
        self.pedometer = pedometer
        self.marks = marks
    }

    // MARK: - Header

    /// What this trace is, and — crucially — what it is *able to validate*.
    public struct Header: Codable, Sendable, Hashable {
        public let name: String
        public let describes: String
        public let recordedAt: Date
        public let deviceModel: String
        public let systemVersion: String
        public let appVersion: String
        public let nominalSampleRateHz: Double
        public let carryPosition: CarryPosition
        public let runnerHeightMetres: Double?
        /// Which references this trace carries. A trace that carries none can still
        /// exercise the pipeline, but it cannot validate an accuracy bound, and stating
        /// that here is what stops it being read as if it could
        /// (AC-FR-S-F-2-4).
        public let references: [Reference]

        public init(
            name: String,
            describes: String,
            recordedAt: Date,
            deviceModel: String,
            systemVersion: String,
            appVersion: String,
            nominalSampleRateHz: Double,
            carryPosition: CarryPosition,
            runnerHeightMetres: Double?,
            references: [Reference]
        ) {
            self.name = name
            self.describes = describes
            self.recordedAt = recordedAt
            self.deviceModel = deviceModel
            self.systemVersion = systemVersion
            self.appVersion = appVersion
            self.nominalSampleRateHz = nominalSampleRateHz
            self.carryPosition = carryPosition
            self.runnerHeightMetres = runnerHeightMetres
            self.references = references
        }
    }

    /// A ground truth the trace carries, with its own accuracy stated so no claim made
    /// against it can be tighter than it is.
    public struct Reference: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
            /// A measured course — a track, a marked kilometre. The best available.
            case surveyedDistance
            /// Distance from a separate GNSS device, typically a watch. ~1–3%.
            case companionGNSSDistance
            /// The capturing phone's own GNSS. ~1–3%, and correlated with the device
            /// under test, which is why it is ranked below a companion.
            case phoneGNSSDistance
            /// Steps counted aloud over a marked segment. Exact, over a short interval —
            /// and the only *exact* reference obtainable in the field.
            case countedSteps
        }

        public let kind: Kind
        public let value: Double
        /// Metres, or steps, per `kind`.
        public let unit: String
        /// Which marks bound the segment this reference applies to, if not the whole
        /// trace.
        public let fromMarkIndex: Int?
        public let toMarkIndex: Int?
        /// The reference's own error, as a fraction. `0` for a counted-step reference.
        public let referenceAccuracyFraction: Double

        public init(
            kind: Kind,
            value: Double,
            unit: String,
            fromMarkIndex: Int? = nil,
            toMarkIndex: Int? = nil,
            referenceAccuracyFraction: Double
        ) {
            self.kind = kind
            self.value = value
            self.unit = unit
            self.fromMarkIndex = fromMarkIndex
            self.toMarkIndex = toMarkIndex
            self.referenceAccuracyFraction = referenceAccuracyFraction
        }
    }

    // MARK: - Columns

    /// Parallel arrays, one entry per sample.
    public struct MotionColumns: Codable, Sendable {
        public let timestamps: [Double]
        public let userAccelerationX: [Double]
        public let userAccelerationY: [Double]
        public let userAccelerationZ: [Double]
        public let gravityX: [Double]
        public let gravityY: [Double]
        public let gravityZ: [Double]
        public let rotationRateX: [Double]
        public let rotationRateY: [Double]
        public let rotationRateZ: [Double]

        public var count: Int { timestamps.count }

        public init(samples: [MotionSample]) {
            timestamps = samples.map(\.timestamp)
            userAccelerationX = samples.map(\.userAcceleration.x)
            userAccelerationY = samples.map(\.userAcceleration.y)
            userAccelerationZ = samples.map(\.userAcceleration.z)
            gravityX = samples.map(\.gravity.x)
            gravityY = samples.map(\.gravity.y)
            gravityZ = samples.map(\.gravity.z)
            rotationRateX = samples.map(\.rotationRate.x)
            rotationRateY = samples.map(\.rotationRate.y)
            rotationRateZ = samples.map(\.rotationRate.z)
        }

        /// Rebuilds the sample stream.
        ///
        /// Returns the shortest consistent prefix rather than trapping when the columns
        /// disagree in length: a capture killed mid-flush can leave one column an entry
        /// short, and losing 10 ms of a 60-minute trace is a far better outcome than
        /// losing the trace.
        public func samples() -> [MotionSample] {
            let n = [
                timestamps.count,
                userAccelerationX.count, userAccelerationY.count, userAccelerationZ.count,
                gravityX.count, gravityY.count, gravityZ.count,
                rotationRateX.count, rotationRateY.count, rotationRateZ.count,
            ].min() ?? 0
            return (0..<n).map { i in
                MotionSample(
                    timestamp: timestamps[i],
                    userAcceleration: Vector3(
                        x: userAccelerationX[i], y: userAccelerationY[i], z: userAccelerationZ[i]),
                    gravity: Vector3(x: gravityX[i], y: gravityY[i], z: gravityZ[i]),
                    rotationRate: Vector3(
                        x: rotationRateX[i], y: rotationRateY[i], z: rotationRateZ[i]))
            }
        }
    }

    // MARK: - Other streams

    /// One position fix.
    ///
    /// ## Absolute position is optional, and committed traces do not carry it (S-059)
    ///
    /// A recording made during a real run is a map of where its runner lives. This
    /// repository is public, so a trace that leaves the device with absolute coordinates
    /// intact publishes a home address alongside its accelerometer data — which is exactly
    /// what happened once, in commit `ab44f40`, before `Tools/scrub-trace.swift` existed.
    ///
    /// Nothing in the estimator ever read `latitude` or `longitude`: distance arrives
    /// through `cumulativeDistanceMetres`, and speed through `speedMetresPerSecond`. The
    /// coordinates were carried purely because the capture tool had them. So they are
    /// optional, a scrubbed trace omits them entirely, and `eastMetres`/`northMetres` carry
    /// the same *relative* geometry — displacement, bearing change, track shape — with the
    /// origin discarded. Validation loses nothing; a reader gains no location.
    ///
    /// Decoding tolerates both shapes, so traces recorded before the split still load.
    public struct RecordedFix: Codable, Sendable, Hashable {
        public let timestamp: Double
        /// Absent on any trace that has been scrubbed for publication.
        public let latitude: Double?
        public let longitude: Double?
        /// Metres east of the trace's first fix. Present on scrubbed traces.
        public let eastMetres: Double?
        /// Metres north of the trace's first fix. Present on scrubbed traces.
        public let northMetres: Double?
        public let altitudeMetres: Double
        public let horizontalAccuracy: Double
        public let verticalAccuracy: Double
        public let speedMetresPerSecond: Double?
        /// Cumulative horizontal distance along the track at this fix, metres, as
        /// accumulated by the capture tool.
        public let cumulativeDistanceMetres: Double

        public init(
            timestamp: Double,
            latitude: Double? = nil,
            longitude: Double? = nil,
            eastMetres: Double? = nil,
            northMetres: Double? = nil,
            altitudeMetres: Double,
            horizontalAccuracy: Double,
            verticalAccuracy: Double,
            speedMetresPerSecond: Double?,
            cumulativeDistanceMetres: Double
        ) {
            self.timestamp = timestamp
            self.latitude = latitude
            self.longitude = longitude
            self.eastMetres = eastMetres
            self.northMetres = northMetres
            self.altitudeMetres = altitudeMetres
            self.horizontalAccuracy = horizontalAccuracy
            self.verticalAccuracy = verticalAccuracy
            self.speedMetresPerSecond = speedMetresPerSecond
            self.cumulativeDistanceMetres = cumulativeDistanceMetres
        }

        /// Hand-written so that a trace recorded before the coordinate split, and a trace
        /// scrubbed after it, both decode — the same reason `SensorCapabilities` decodes
        /// its newer fields with `decodeIfPresent` (core `design.md` ADR-002 territory).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try container.decode(Double.self, forKey: .timestamp)
            latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
            eastMetres = try container.decodeIfPresent(Double.self, forKey: .eastMetres)
            northMetres = try container.decodeIfPresent(Double.self, forKey: .northMetres)
            altitudeMetres = try container.decode(Double.self, forKey: .altitudeMetres)
            horizontalAccuracy = try container.decode(
                Double.self, forKey: .horizontalAccuracy)
            verticalAccuracy = try container.decode(Double.self, forKey: .verticalAccuracy)
            speedMetresPerSecond = try container.decodeIfPresent(
                Double.self, forKey: .speedMetresPerSecond)
            cumulativeDistanceMetres = try container.decode(
                Double.self, forKey: .cumulativeDistanceMetres)
        }

        public var fix: LocationFix {
            LocationFix(
                timestamp: timestamp,
                cumulativeDistanceMetres: cumulativeDistanceMetres,
                horizontalAccuracy: horizontalAccuracy,
                speedMetresPerSecond: speedMetresPerSecond)
        }
    }

    public struct RecordedPedometerReading: Codable, Sendable, Hashable {
        public let timestamp: Double
        public let cumulativeSteps: Int
        public let cumulativeDistanceMetres: Double?
        public let currentCadenceStepsPerSecond: Double?

        public init(
            timestamp: Double,
            cumulativeSteps: Int,
            cumulativeDistanceMetres: Double?,
            currentCadenceStepsPerSecond: Double?
        ) {
            self.timestamp = timestamp
            self.cumulativeSteps = cumulativeSteps
            self.cumulativeDistanceMetres = cumulativeDistanceMetres
            self.currentCadenceStepsPerSecond = currentCadenceStepsPerSecond
        }
    }

    /// A labelled instant, tapped by the runner during capture.
    public struct Mark: Codable, Sendable, Hashable {
        public let timestamp: Double
        public let index: Int
        public let note: String?

        public init(timestamp: Double, index: Int, note: String? = nil) {
            self.timestamp = timestamp
            self.index = index
            self.note = note
        }
    }
}

// MARK: - Coding

extension MotionTrace {
    /// Decodes a trace, rejecting a schema version this build does not understand with a
    /// typed error rather than a decoding failure — the same treatment `RunEnvelope`
    /// gives an unknown major version (AC-FR-E-1-4).
    public static func decode(from data: Data) throws -> MotionTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe = try decoder.decode(VersionProbe.self, from: data)
        guard probe.schemaVersion <= currentSchemaVersion else {
            throw MotionTraceError.unsupportedSchema(
                found: probe.schemaVersion, supported: currentSchemaVersion)
        }
        return try decoder.decode(MotionTrace.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }
}

public enum MotionTraceError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(found: Int, supported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchema(found, supported):
            return "motion trace schema \(found) is newer than this build understands "
                + "(\(supported)) — update the app rather than editing the trace"
        }
    }
}
