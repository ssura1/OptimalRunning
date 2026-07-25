import Foundation

/// A recorded (or deterministically generated) trace of engine inputs.
///
/// Fixtures are the project's most valuable test asset and also its bug-report format:
/// "the screen went red on my hill" becomes a fixture, then a failing test, then a fix
/// (design.md §16.2).
public struct EngineFixture: Codable, Sendable {
    public let name: String
    public let describes: String
    public let runType: RunType
    public let profile: RunnerProfile
    public let plan: WorkoutPlan
    public let inputs: [EngineInput]

    public init(
        name: String,
        describes: String,
        runType: RunType,
        profile: RunnerProfile,
        plan: WorkoutPlan,
        inputs: [EngineInput]
    ) {
        self.name = name
        self.describes = describes
        self.runType = runType
        self.profile = profile
        self.plan = plan
        self.inputs = inputs
    }
}

/// One entry in a golden alert sequence.
public struct GoldenAlert: Codable, Sendable, Hashable {
    public let atSeconds: TimeInterval
    /// `paceTooFast`, `paceTooSlow`, `stepTransition`, or `workoutComplete`.
    public let kind: String

    public init(atSeconds: TimeInterval, kind: String) {
        self.atSeconds = atSeconds
        self.kind = kind
    }
}

/// One entry in a golden transition sequence.
public struct GoldenTransition: Codable, Sendable, Hashable {
    public let atSeconds: TimeInterval
    public let atCumulativeDistance: Double
    public let fromIndex: Int
    public let toIndex: Int?
    public let wasAutomatic: Bool
    public let completedDistanceMetres: Double

    public init(
        atSeconds: TimeInterval,
        atCumulativeDistance: Double,
        fromIndex: Int,
        toIndex: Int?,
        wasAutomatic: Bool,
        completedDistanceMetres: Double
    ) {
        self.atSeconds = atSeconds
        self.atCumulativeDistance = atCumulativeDistance
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.wasAutomatic = wasAutomatic
        self.completedDistanceMetres = completedDistanceMetres
    }
}

/// The asserted subset of engine output for a fixture.
///
/// Deliberately not the whole `EngineOutput` series: a golden that captures every
/// float would fail on any harmless refactor and would train reviewers to regenerate
/// it without reading the diff. These four things are what the product promises.
public struct EngineGolden: Codable, Sendable, Hashable {
    public let fixture: String
    public let zoneTimeline: [ZoneSpan]
    public let alerts: [GoldenAlert]
    public let transitions: [GoldenTransition]
    public let sampleCount: Int
    public let finalCumulativeDistance: Double
    public let finalActiveElapsed: TimeInterval
    public let degradations: [String]

    public init(
        fixture: String,
        zoneTimeline: [ZoneSpan],
        alerts: [GoldenAlert],
        transitions: [GoldenTransition],
        sampleCount: Int,
        finalCumulativeDistance: Double,
        finalActiveElapsed: TimeInterval,
        degradations: [String]
    ) {
        self.fixture = fixture
        self.zoneTimeline = zoneTimeline
        self.alerts = alerts
        self.transitions = transitions
        self.sampleCount = sampleCount
        self.finalCumulativeDistance = finalCumulativeDistance
        self.finalActiveElapsed = finalActiveElapsed
        self.degradations = degradations
    }
}

public enum FixtureCoder {

    /// Goldens are pretty-printed and key-sorted, because their diffs are read.
    ///
    /// A golden diff is the project's regression signal — a reviewer has to be able to
    /// see that three zone spans became thirty. Readability is worth the bytes.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Fixtures are compact. They are thousands of generated sample rows that nobody
    /// reads line by line, and pretty-printing them roughly doubles the repository
    /// size for no review value.
    public static func makeFixtureEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder { JSONDecoder() }
}

// MARK: - Deterministic noise

/// A tiny linear congruential generator.
///
/// Fixtures must be byte-identical on every machine and every platform, so they cannot
/// use `SystemRandomNumberGenerator` — and `Double.random(in:)`'s exact output is not
/// guaranteed stable across Swift versions either. This is intentionally boring and
/// fully specified.
public struct DeterministicRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x4d595df4d0f33173 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in [-magnitude, +magnitude].
    public mutating func noise(_ magnitude: Double) -> Double {
        (unit() * 2 - 1) * magnitude
    }
}
