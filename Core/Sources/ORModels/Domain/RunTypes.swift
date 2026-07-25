import Foundation

// MARK: - Run type

/// The five run types offered on the watch start screen (AC-FR-A-7-1).
///
/// `vo2max` is a distinct case rather than a flag on `interval` because the product
/// difference is categorical: a VO2 max session is a *test of capability*, so
/// prescribing a pace would contaminate the measurement (FR-C-4). Making it a case
/// means the compiler forces every switch to decide what it does.
public enum RunType: String, Codable, Sendable, Hashable, CaseIterable {
    case tempo
    case easy
    case long
    case interval
    case vo2max

    /// Whether this run type ever applies zone colouring.
    ///
    /// VO2 max never does, at any pace, in any step (AC-FR-C-4-2). Interval defers to
    /// the individual step's target (AC-FR-C-5-2/3); the other three always colour.
    public var appliesZoneColouring: Bool {
        switch self {
        case .tempo, .easy, .long, .interval: return true
        case .vo2max: return false
        }
    }

    /// Whether this run type ever fires pace haptics (AC-FR-B-1-4, AC-FR-C-4-4).
    /// Step-transition haptics are separate and fire for every run type.
    public var firesPaceHaptics: Bool { appliesZoneColouring }

    /// Whether the run is built from a step list rather than a single continuous effort.
    public var isStructured: Bool {
        switch self {
        case .interval, .vo2max: return true
        case .tempo, .easy, .long: return false
        }
    }
}

// MARK: - Steps

/// One phase of a structured workout (AC-FR-C-1-1).
public enum StepKind: String, Codable, Sendable, Hashable, CaseIterable {
    case warmup
    case work
    case recovery
    case cooldown
}

/// How a step ends (AC-FR-C-1-2).
public enum StepGoal: Codable, Sendable, Hashable {
    /// Ends only on an explicit user action — the warmup and cooldown case.
    case open
    /// Ends automatically when the step's own distance reaches this many metres.
    case distance(metres: Double)
    /// Ends automatically when the step's own active time reaches this many seconds.
    case time(seconds: Double)

    /// A closed goal advances on its own; an open goal requires the runner to act.
    ///
    /// This distinction is the guard that makes full-screen tap-to-advance safe: a tap
    /// during a closed-goal step is ignored, so a mis-tap cannot truncate a rep
    /// (AC-FR-C-3-4).
    public var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    public var distanceMetres: Double? {
        if case .distance(let m) = self { return m }
        return nil
    }

    public var timeSeconds: Double? {
        if case .time(let s) = self { return s }
        return nil
    }
}

// MARK: - Zones

/// Which part of the pace band the runner is currently in (AC-FR-A-3-1).
///
/// Raw values are stable: they are persisted in packed sample columns and in the
/// zone timeline, so reordering these cases would silently reinterpret stored runs.
public enum PaceZone: Int, Codable, Sendable, Hashable, CaseIterable {
    case tooFast = 0
    case slightlyFast = 1
    case onTarget = 2
    case slightlySlow = 3
    case tooSlow = 4
    /// No judgement is being rendered: settling, paused, stationary, VO2 max,
    /// or no target pace available.
    case neutral = 5

    /// The two zones that can trigger a haptic (AC-FR-B-1-1).
    public var isFarOff: Bool { self == .tooFast || self == .tooSlow }

    /// Whether the runner is on the fast side of target. `neutral` is neither.
    public var isFastSide: Bool { self == .tooFast || self == .slightlyFast }
    public var isSlowSide: Bool { self == .tooSlow || self == .slightlySlow }
}

// MARK: - Palette selection

/// Which zone palette the runner has chosen (FR-J-2).
///
/// Offered during onboarding rather than buried in settings (AC-FR-J-2-3), because a
/// runner who cannot read the default palette needs the alternative before their first
/// run, not after they have concluded the product does not work.
public enum PaletteChoice: String, Codable, Sendable, Hashable, CaseIterable {
    case standard
    case colorVisionDeficiency
}

// MARK: - Device tier

/// Which watch codebase produced a run (ADR-002).
public enum DeviceTier: String, Codable, Sendable, Hashable, CaseIterable {
    case modern
    case legacy
}

// MARK: - Degradation

/// A condition that reduced the fidelity of a run (requirements.md §8).
///
/// Recorded on the run so post-run analysis can say *why* a chart is missing data
/// rather than rendering a blank panel.
public enum DegradationFlag: String, Codable, Sendable, Hashable, CaseIterable {
    /// DEG-1 — GPS unavailable or poor; pace fell back to the pedometer.
    case gpsDegraded
    /// DEG-2 — altimeter unavailable; grade adjustment was pinned to 1.0.
    case altimeterUnavailable
    /// DEG-3 — heart rate dropped out for part of the run.
    case heartRateDropout
    /// DEG-4 — the workout session was pre-empted by another app (CON-5).
    case sessionInterrupted
    /// DEG-5 — low-power mode was active; sample rate was reduced.
    case lowPowerMode
    /// DEG-8 — HealthKit authorization was denied; the run is local only.
    case healthKitUnauthorized
    /// DEG-9 — no target pace was set; the run was recorded without judgement.
    case noTargetPace
    /// DEG-10 — indoor run; pedometer distance, no route, no grade.
    case indoorRun
    /// The sidecar payload was lost and this record was rebuilt from HealthKit
    /// alone (AC-FR-E-1-6).
    case reconstructedFromHealthKit
}

// MARK: - Sensor capabilities

/// What the hardware running the app can actually do (design.md §8).
///
/// Reported by the tier adapter, consumed by `Core` so the engine can disable grade
/// adjustment on a device with no altimeter without knowing which watch it is on.
public struct SensorCapabilities: Codable, Sendable, Hashable {
    public let hasAltimeter: Bool
    public let hasGPS: Bool
    public let hasAlwaysOnDisplay: Bool
    public let supportsNativeActivitySegmentation: Bool
    public let supportsDoubleTap: Bool

    public init(
        hasAltimeter: Bool,
        hasGPS: Bool,
        hasAlwaysOnDisplay: Bool,
        supportsNativeActivitySegmentation: Bool,
        supportsDoubleTap: Bool
    ) {
        self.hasAltimeter = hasAltimeter
        self.hasGPS = hasGPS
        self.hasAlwaysOnDisplay = hasAlwaysOnDisplay
        self.supportsNativeActivitySegmentation = supportsNativeActivitySegmentation
        self.supportsDoubleTap = supportsDoubleTap
    }
}
