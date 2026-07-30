import Foundation

// MARK: - Location

/// A normalized location fix. The tier adapter converts `CLLocation` into this so
/// `Core` never imports CoreLocation (ADR-001).
public struct LocationSample: Codable, Sendable, Hashable {
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let altitudeMetres: Double
    /// Metres. Negative means the fix is invalid, matching CoreLocation's convention.
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double

    public init(
        timestamp: TimeInterval,
        latitude: Double,
        longitude: Double,
        altitudeMetres: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMetres = altitudeMetres
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }

    /// Whether the fix is good enough to define a rolling-pace window endpoint.
    ///
    /// CoreLocation reports a negative accuracy for an invalid fix, so the sign test
    /// is not redundant with the threshold test (AC-FR-A-1-2).
    public func isAcceptable(maxHorizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= maxHorizontalAccuracy
    }
}

/// Where a distance figure came from. Recorded for post-run diagnostics; the engine
/// itself is deliberately blind to it (design.md §8.2).
public enum DistanceSource: String, Codable, Sendable, Hashable, CaseIterable {
    case healthKit
    case location
    case pedometer
    /// This project's own step-length model, from the standalone phone tier
    /// (standalone/design.md §5).
    ///
    /// **Deliberately not folded into `.pedometer`.** They are different claims:
    /// `.pedometer` means "CMPedometer said so", a model whose internals we do not
    /// know and whose running behaviour we have not characterised, while
    /// `.motionModel` means "our model said so" — a number we can explain, bound and
    /// validate against a recorded trace. Collapsing them would make the
    /// measured-versus-estimated display a lie and the calibration diagnostics
    /// unreadable.
    ///
    /// It also matters to live behaviour: `RunEngine` reads
    /// `.pedometer && location == nil` as an indoor run, and a GPS-denied *outdoor*
    /// underpass is not a treadmill. A separate case leaves that inference exactly as
    /// it was.
    case motionModel

    /// Whether this source *observed* the runner's displacement or *inferred* it.
    ///
    /// `.healthKit` counts as measured because on a watch it is Apple's GNSS-fused
    /// estimate; where no GNSS is present the adapter reports the underlying source
    /// instead.
    public var isEstimated: Bool {
        switch self {
        case .healthKit, .location: return false
        case .pedometer, .motionModel: return true
        }
    }
}

// MARK: - Engine input

/// One tick of sensor state handed to the engine (design.md §5.7).
///
/// Everything the engine decides is a pure function of a sequence of these plus
/// configuration, which is what makes recorded runs replayable and CI simulator-free.
public struct EngineInput: Codable, Sendable, Hashable {
    /// Seconds since session start. Never wall-clock — determinism depends on this
    /// (AC-FR-A-1-6).
    public let timestamp: TimeInterval
    /// Metres since session start, already fused across sources by the adapter.
    public let cumulativeDistance: Double
    public let location: LocationSample?
    /// Metres relative to session start. `nil` when the altimeter is unavailable,
    /// which disables grade adjustment rather than reading as flat ground (DEG-2).
    public let relativeAltitude: Double?
    public let heartRate: Double?
    public let isPaused: Bool
    public let manualAdvanceRequested: Bool
    public let distanceSource: DistanceSource

    public init(
        timestamp: TimeInterval,
        cumulativeDistance: Double,
        location: LocationSample? = nil,
        relativeAltitude: Double? = nil,
        heartRate: Double? = nil,
        isPaused: Bool = false,
        manualAdvanceRequested: Bool = false,
        distanceSource: DistanceSource = .location
    ) {
        self.timestamp = timestamp
        self.cumulativeDistance = cumulativeDistance
        self.location = location
        self.relativeAltitude = relativeAltitude
        self.heartRate = heartRate
        self.isPaused = isPaused
        self.manualAdvanceRequested = manualAdvanceRequested
        self.distanceSource = distanceSource
    }
}

// MARK: - Run sample

/// The 1 Hz record persisted for every tick (AC-FR-D-2-1).
///
/// Both the raw target and the grade-adjusted effective target are stored, so post-run
/// analysis can show what was asked of the runner and why it changed (AC-FR-A-4-8).
public struct RunSample: Codable, Sendable, Hashable {
    public let timestamp: TimeInterval
    public let cumulativeDistance: Double
    public let rollingPace: Pace?
    public let heartRate: Double?
    public let relativeAltitude: Double?
    public let smoothedGrade: Double
    public let gradeFactor: PaceRatio
    /// Target before grade adjustment — the curve value alone.
    public let rawTarget: Pace?
    /// Target after grade adjustment — what the zone was actually judged against.
    public let effectiveTarget: Pace?
    public let zone: PaceZone

    public init(
        timestamp: TimeInterval,
        cumulativeDistance: Double,
        rollingPace: Pace?,
        heartRate: Double?,
        relativeAltitude: Double?,
        smoothedGrade: Double,
        gradeFactor: PaceRatio,
        rawTarget: Pace?,
        effectiveTarget: Pace?,
        zone: PaceZone
    ) {
        self.timestamp = timestamp
        self.cumulativeDistance = cumulativeDistance
        self.rollingPace = rollingPace
        self.heartRate = heartRate
        self.relativeAltitude = relativeAltitude
        self.smoothedGrade = smoothedGrade
        self.gradeFactor = gradeFactor
        self.rawTarget = rawTarget
        self.effectiveTarget = effectiveTarget
        self.zone = zone
    }
}

// MARK: - Runner profile

/// The runner's stored paces and preferences (FR-I-1).
///
/// Target paces are optional throughout: a runner with no profile can still record an
/// untargeted run, which renders neutral rather than refusing to start (DEG-9).
public struct RunnerProfile: Codable, Sendable, Hashable {
    public var tempoPace: Pace?
    public var easyPace: Pace?
    public var longPace: Pace?
    public var units: UnitPreference
    public var palette: PaletteChoice
    /// Pace haptics can be disabled without disabling interval haptics (AC-FR-B-1-7).
    public var paceHapticsEnabled: Bool
    /// Opt-in crown-rotation detent for manual advance (AC-FR-C-3-3).
    public var crownAdvanceEnabled: Bool

    // MARK: Standalone tier (FR-S-G-1)
    //
    // These live on the one profile rather than in a second standalone-only store, because
    // AC-FR-S-G-1-4 requires them to persist through the existing profile and sync to a
    // watch without disturbing it. A watch decodes them and ignores them, which is what
    // "without disturbing" means in practice.

    /// The runner's height, metres. Feeds the step-length model (AC-FR-S-B-4-1) and is
    /// offered from HealthKit rather than asked for twice (AC-FR-S-G-1-1).
    ///
    /// `nil` is a supported state, not a missing value: AC-FR-S-B-4-6 requires a documented
    /// default and a lower-confidence marking, which is a different behaviour from having
    /// been told.
    public var heightMetres: Double?
    /// Spoken cues, the standalone tier's *primary* channel (AC-FR-S-D-1-1). Disabling them
    /// leaves haptics as a complete channel (AC-FR-S-D-1-7).
    public var spokenCuesEnabled: Bool
    /// Split announcements, on their own channel and independently disableable
    /// (AC-FR-S-D-1-5). On by default: a mile split is the thing a runner most wants said.
    public var splitAnnouncementsEnabled: Bool
    /// Periodic elapsed-time announcements, seconds. `nil` is off, and off is the default —
    /// AC-FR-S-D-1-5 says so explicitly, and a clock that speaks every five minutes is the
    /// fastest way to make a runner turn the voice off entirely.
    public var timeAnnouncementIntervalSeconds: TimeInterval?

    public init(
        tempoPace: Pace? = nil,
        easyPace: Pace? = nil,
        longPace: Pace? = nil,
        units: UnitPreference = .miles,
        palette: PaletteChoice = .standard,
        paceHapticsEnabled: Bool = true,
        crownAdvanceEnabled: Bool = false,
        heightMetres: Double? = nil,
        spokenCuesEnabled: Bool = true,
        splitAnnouncementsEnabled: Bool = true,
        timeAnnouncementIntervalSeconds: TimeInterval? = nil
    ) {
        self.tempoPace = tempoPace
        self.easyPace = easyPace
        self.longPace = longPace
        self.units = units
        self.palette = palette
        self.paceHapticsEnabled = paceHapticsEnabled
        self.crownAdvanceEnabled = crownAdvanceEnabled
        self.heightMetres = heightMetres
        self.spokenCuesEnabled = spokenCuesEnabled
        self.splitAnnouncementsEnabled = splitAnnouncementsEnabled
        self.timeAnnouncementIntervalSeconds = timeAnnouncementIntervalSeconds
    }

    /// Hand-written because the standalone fields are **not** optional and a synthesised
    /// decoder would therefore reject every profile snapshot written before they existed.
    ///
    /// This is not hypothetical: `RunEnvelope` snapshots the profile into every stored run
    /// (design.md §9.1), `Fixtures/legacy-tier-envelope.payload` is one such payload
    /// committed to this repository, and a `keyNotFound` here would make every run in a
    /// runner's history unreadable after an app update. The same reasoning, and the same
    /// remedy, as `SensorCapabilities.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tempoPace = try container.decodeIfPresent(Pace.self, forKey: .tempoPace)
        easyPace = try container.decodeIfPresent(Pace.self, forKey: .easyPace)
        longPace = try container.decodeIfPresent(Pace.self, forKey: .longPace)
        units = try container.decode(UnitPreference.self, forKey: .units)
        palette = try container.decode(PaletteChoice.self, forKey: .palette)
        paceHapticsEnabled = try container.decode(Bool.self, forKey: .paceHapticsEnabled)
        crownAdvanceEnabled = try container.decode(Bool.self, forKey: .crownAdvanceEnabled)
        heightMetres = try container.decodeIfPresent(Double.self, forKey: .heightMetres)
        spokenCuesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .spokenCuesEnabled) ?? true
        splitAnnouncementsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .splitAnnouncementsEnabled) ?? true
        timeAnnouncementIntervalSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .timeAnnouncementIntervalSeconds)
    }

    /// The stored base pace for a run type, or `nil` if none is set.
    ///
    /// Interval and VO2 max return `nil`: their targets, where they exist at all, are
    /// carried per step rather than per run (FR-C-5).
    public func basePace(for runType: RunType) -> Pace? {
        switch runType {
        case .tempo: return tempoPace
        case .easy: return easyPace
        case .long: return longPace
        case .interval, .vo2max: return nil
        }
    }
}
