import Foundation

/// Every tunable constant in the engine, in exactly one place (NFR-21).
///
/// Nothing in the engine reads a numeric literal. A literal in engine logic is a
/// review rejection, because a constant that lives at its use site cannot be tuned,
/// cannot be snapshotted into a run record, and cannot be validated.
///
/// The whole configuration is snapshotted into every `RunEnvelope` (design.md §9.1):
/// a run analysed six months later must be interpretable against the thresholds that
/// were actually in force, not today's.
public struct PaceEngineConfiguration: Codable, Sendable, Hashable {

    public var rollingPace: RollingPaceConfiguration
    public var zones: ZoneConfiguration
    public var grade: GradeConfiguration
    public var settling: SettlingConfiguration
    public var alerts: AlertConfiguration
    public var intervals: IntervalConfiguration
    public var capture: CaptureConfiguration
    public var sync: SyncConfiguration
    public var presentation: PresentationConfiguration
    public var degradation: DegradationConfiguration
    public var bands: [RunType: PaceBand]
    public var curves: [RunType: TargetPaceCurve]

    public init(
        rollingPace: RollingPaceConfiguration = .init(),
        zones: ZoneConfiguration = .init(),
        grade: GradeConfiguration = .init(),
        settling: SettlingConfiguration = .init(),
        alerts: AlertConfiguration = .init(),
        intervals: IntervalConfiguration = .init(),
        capture: CaptureConfiguration = .init(),
        sync: SyncConfiguration = .init(),
        presentation: PresentationConfiguration = .init(),
        degradation: DegradationConfiguration = .init(),
        bands: [RunType: PaceBand] = PaceEngineConfiguration.defaultBands,
        curves: [RunType: TargetPaceCurve] = PaceEngineConfiguration.defaultCurves
    ) {
        self.rollingPace = rollingPace
        self.zones = zones
        self.grade = grade
        self.settling = settling
        self.alerts = alerts
        self.intervals = intervals
        self.capture = capture
        self.sync = sync
        self.presentation = presentation
        self.degradation = degradation
        self.bands = bands
        self.curves = curves
    }

    public static let `default` = PaceEngineConfiguration()

    public static let defaultBands: [RunType: PaceBand] = Dictionary(
        uniqueKeysWithValues: RunType.allCases.map { ($0, PaceBand.standard(for: $0)) }
    )

    public static let defaultCurves: [RunType: TargetPaceCurve] = Dictionary(
        uniqueKeysWithValues: RunType.allCases.map { ($0, TargetPaceCurve.standard(for: $0)) }
    )

    /// Restores the shipped defaults for one run type in a single action (AC-FR-A-2-8).
    public mutating func restoreDefaults(for runType: RunType) {
        bands[runType] = PaceBand.standard(for: runType)
        curves[runType] = TargetPaceCurve.standard(for: runType)
    }

    public func band(for runType: RunType) -> PaceBand {
        bands[runType] ?? PaceBand.standard(for: runType)
    }

    public func curve(for runType: RunType) -> TargetPaceCurve {
        curves[runType] ?? TargetPaceCurve.standard(for: runType)
    }

    // MARK: Validation

    /// Rejects out-of-range values with a specific error naming the field.
    ///
    /// A configuration arriving from a synced payload is untrusted input: it was
    /// produced by a different app version and may carry values this build cannot
    /// interpret. Validating on ingest is what keeps a bad value from silently
    /// mis-colouring a run instead of failing loudly.
    public func validate() throws {
        try rollingPace.validate()
        try zones.validate()
        try grade.validate()
        try settling.validate()
        try alerts.validate()
        try intervals.validate()
        try capture.validate()
        try sync.validate()
        try presentation.validate()
        try degradation.validate()

        for (runType, band) in bands where !band.isWellFormed {
            throw ConfigurationError.malformedBand(runType: runType)
        }
        for (runType, curve) in curves where !curve.isWellFormed {
            throw ConfigurationError.malformedCurve(runType: runType)
        }
    }
}

// MARK: - Errors

public enum ConfigurationError: Error, Equatable, Sendable {
    case outOfRange(field: String, value: Double, permitted: ClosedRange<Double>)
    case malformedBand(runType: RunType)
    case malformedCurve(runType: RunType)
    case inconsistent(field: String, reason: String)
}

/// Throws unless `value` lies in `range`.
@inline(__always)
func requireInRange(_ value: Double, _ range: ClosedRange<Double>, _ field: String) throws {
    guard value.isFinite, range.contains(value) else {
        throw ConfigurationError.outOfRange(field: field, value: value, permitted: range)
    }
}

// MARK: - Rolling pace

/// Tunables for the distance-windowed rolling pace estimator (FR-A-1, ADR-004).
public struct RollingPaceConfiguration: Codable, Sendable, Hashable {
    /// Trailing distance the window spans. Distance-windowed rather than
    /// time-windowed so the sample count stays roughly constant across paces.
    public var windowMetres: Double = 200
    /// Lower time bound — stops the window becoming twitchy when running fast.
    public var minWindowSeconds: Double = 20
    /// Upper time bound — stops the window becoming useless when nearly stopped.
    public var maxWindowSeconds: Double = 60
    /// Fixes worse than this (or with negative accuracy) never define a window
    /// endpoint (AC-FR-A-1-2).
    public var maxHorizontalAccuracyMetres: Double = 20
    /// EWMA weight on the newest raw pace. 0.30 gives ~15 s effective response.
    public var smoothingAlpha: Double = 0.30
    /// Below this distance over `stationarySeconds`, pace is reported undefined
    /// rather than as an unbounded number (AC-FR-A-1-5).
    public var stationaryDistanceMetres: Double = 5
    public var stationarySeconds: Double = 5
    /// Plausibility clamp — anything outside this is a sensor artefact, not a runner.
    public var fastestPlausibleSecondsPerMile: Double = 120
    public var slowestPlausibleSecondsPerMile: Double = 1800
    /// Time without a usable fix before the run is flagged GPS-degraded (AC-FR-A-1-3).
    public var gpsDegradedAfterSeconds: Double = 10

    public init() {}

    public func validate() throws {
        try requireInRange(windowMetres, 100...400, "rollingPace.windowMetres")
        try requireInRange(minWindowSeconds, 5...60, "rollingPace.minWindowSeconds")
        try requireInRange(maxWindowSeconds, 10...300, "rollingPace.maxWindowSeconds")
        try requireInRange(maxHorizontalAccuracyMetres, 1...100, "rollingPace.maxHorizontalAccuracyMetres")
        try requireInRange(smoothingAlpha, 0.01...1.0, "rollingPace.smoothingAlpha")
        try requireInRange(stationaryDistanceMetres, 0...50, "rollingPace.stationaryDistanceMetres")
        try requireInRange(stationarySeconds, 1...60, "rollingPace.stationarySeconds")
        try requireInRange(fastestPlausibleSecondsPerMile, 60...600, "rollingPace.fastestPlausibleSecondsPerMile")
        try requireInRange(slowestPlausibleSecondsPerMile, 600...5400, "rollingPace.slowestPlausibleSecondsPerMile")
        try requireInRange(gpsDegradedAfterSeconds, 1...120, "rollingPace.gpsDegradedAfterSeconds")
        guard minWindowSeconds < maxWindowSeconds else {
            throw ConfigurationError.inconsistent(
                field: "rollingPace", reason: "minWindowSeconds must be below maxWindowSeconds"
            )
        }
        guard fastestPlausibleSecondsPerMile < slowestPlausibleSecondsPerMile else {
            throw ConfigurationError.inconsistent(
                field: "rollingPace", reason: "fastest plausible pace must be faster than slowest"
            )
        }
    }
}

// MARK: - Zones

/// Tunables for zone classification (FR-A-3).
public struct ZoneConfiguration: Codable, Sendable, Hashable {
    /// Boundary hysteresis, as an absolute offset on the pace ratio. Since the ratio
    /// sits near 1.0, 0.005 is 0.5% of pace (AC-FR-A-3-6).
    ///
    /// Without this the colour flickers whenever the runner holds a pace that happens
    /// to sit on a boundary — which is exactly what a runner trying to hit a target
    /// does — and a flickering full-screen colour is worse than no colour at all.
    public var hysteresis: Double = 0.005

    public init() {}

    public func validate() throws {
        try requireInRange(hysteresis, 0...0.10, "zones.hysteresis")
    }
}

// MARK: - Grade

/// Tunables for grade estimation and the attenuated Minetti adjustment
/// (FR-A-4, ADR-006).
public struct GradeConfiguration: Codable, Sendable, Hashable {
    /// Horizontal distance over which the altitude delta is measured.
    public var windowMetres: Double = 100
    public var smoothingAlpha: Double = 0.20
    /// How long a changed grade must persist before the target moves. This is what
    /// makes the app respond to a hill rather than to a kerb (AC-FR-A-4-2).
    public var persistenceSeconds: Double = 15
    /// Minimum change, in grade fraction, that counts as a new grade worth adopting.
    public var persistenceDeltaThreshold: Double = 0.005
    /// Attenuation applied to the raw Minetti deviation on climbs.
    public var lambdaUp: Double = 0.90
    /// Heavier attenuation on descents: a runner can spend the full metabolic cost
    /// of a climb but cannot recover the full saving of a descent.
    public var lambdaDown: Double = 0.50
    public var minGrade: Double = -0.15
    public var maxGrade: Double = 0.15
    public var minFactor: Double = 0.90
    public var maxFactor: Double = 1.30
    /// Deviation from 1.0 above which the hill indicator appears (AC-FR-A-4-7).
    public var hillIndicatorThreshold: Double = 0.01

    public init() {}

    public var gradeClamp: ClosedRange<Double> { minGrade...maxGrade }
    public var factorClamp: ClosedRange<Double> { minFactor...maxFactor }

    public func validate() throws {
        try requireInRange(windowMetres, 20...500, "grade.windowMetres")
        try requireInRange(smoothingAlpha, 0.01...1.0, "grade.smoothingAlpha")
        try requireInRange(persistenceSeconds, 0...120, "grade.persistenceSeconds")
        try requireInRange(persistenceDeltaThreshold, 0...0.10, "grade.persistenceDeltaThreshold")
        try requireInRange(lambdaUp, 0...1, "grade.lambdaUp")
        try requireInRange(lambdaDown, 0...1, "grade.lambdaDown")
        try requireInRange(minGrade, -0.5...0, "grade.minGrade")
        try requireInRange(maxGrade, 0...0.5, "grade.maxGrade")
        try requireInRange(minFactor, 0.5...1.0, "grade.minFactor")
        try requireInRange(maxFactor, 1.0...2.0, "grade.maxFactor")
        try requireInRange(hillIndicatorThreshold, 0...0.5, "grade.hillIndicatorThreshold")
    }
}

// MARK: - Settling

/// Tunables for the opening window where no judgement is rendered (FR-A-5).
///
/// Without this, every run opens with a solid red screen — the runner is accelerating
/// from a standstill and GPS has not converged — which teaches users to ignore the
/// colour and destroys the product's core mechanic.
public struct SettlingConfiguration: Codable, Sendable, Hashable {
    public var runDistanceMetres: Double = 400
    public var runSeconds: Double = 90
    /// Shorter window at each interval step start (AC-FR-C-5-4).
    public var stepDistanceMetres: Double = 100

    public init() {}

    public func validate() throws {
        try requireInRange(runDistanceMetres, 0...2000, "settling.runDistanceMetres")
        try requireInRange(runSeconds, 0...600, "settling.runSeconds")
        try requireInRange(stepDistanceMetres, 0...1000, "settling.stepDistanceMetres")
    }
}

// MARK: - Alerts

/// Tunables for the dwell/cooldown haptic policy (FR-B-1, FR-B-2).
public struct AlertConfiguration: Codable, Sendable, Hashable {
    /// Continuous time in a far-off zone before a haptic fires.
    public var dwellSeconds: Double = 20
    /// Minimum gap between haptics of the same direction. Bounds the nag rate.
    public var cooldownSeconds: Double = 60
    public var warningAutoDismissSeconds: Double = 4

    public init() {}

    public func validate() throws {
        try requireInRange(dwellSeconds, 1...300, "alerts.dwellSeconds")
        try requireInRange(cooldownSeconds, 1...900, "alerts.cooldownSeconds")
        try requireInRange(warningAutoDismissSeconds, 1...30, "alerts.warningAutoDismissSeconds")
    }
}

// MARK: - Intervals

/// Tunables and bounds for structured workouts (FR-C-1, FR-C-2, FR-C-6).
public struct IntervalConfiguration: Codable, Sendable, Hashable {
    public var minRepeatCount: Int = 1
    public var maxRepeatCount: Int = 40
    public var minStepDistanceMetres: Double = 100
    public var maxStepDistanceMetres: Double = 42195
    /// Distance before a work step's end at which the countdown appears.
    public var countdownDistanceMetres: Double = 100
    public var transitionScreenSeconds: Double = 3
    /// How long undo remains available after a manual advance.
    public var undoWindowSeconds: Double = 5

    public init() {}

    public var repeatCountRange: ClosedRange<Int> { minRepeatCount...maxRepeatCount }
    public var stepDistanceRange: ClosedRange<Double> { minStepDistanceMetres...maxStepDistanceMetres }

    public func validate() throws {
        guard minRepeatCount >= 1, maxRepeatCount >= minRepeatCount else {
            throw ConfigurationError.inconsistent(
                field: "intervals", reason: "repeat count range must be positive and ordered"
            )
        }
        try requireInRange(minStepDistanceMetres, 1...10000, "intervals.minStepDistanceMetres")
        try requireInRange(maxStepDistanceMetres, 100...100_000, "intervals.maxStepDistanceMetres")
        try requireInRange(countdownDistanceMetres, 0...1000, "intervals.countdownDistanceMetres")
        try requireInRange(transitionScreenSeconds, 0...30, "intervals.transitionScreenSeconds")
        try requireInRange(undoWindowSeconds, 0...60, "intervals.undoWindowSeconds")
        guard minStepDistanceMetres < maxStepDistanceMetres else {
            throw ConfigurationError.inconsistent(
                field: "intervals", reason: "step distance range must be ordered"
            )
        }
    }
}

// MARK: - Capture

/// Tunables for sample capture and durability (FR-D-2, FR-D-6).
public struct CaptureConfiguration: Codable, Sendable, Hashable {
    /// Nominal tick interval. Zone is evaluated once per tick (AC-FR-A-3-8).
    public var sampleIntervalSeconds: Double = 1.0
    /// Maximum data loss window on unexpected termination (AC-FR-D-6-4).
    public var flushIntervalSeconds: Double = 30
    public var heartRateStaleSeconds: Double = 10

    public init() {}

    public func validate() throws {
        try requireInRange(sampleIntervalSeconds, 0.1...10, "capture.sampleIntervalSeconds")
        try requireInRange(flushIntervalSeconds, 1...300, "capture.flushIntervalSeconds")
        try requireInRange(heartRateStaleSeconds, 1...120, "capture.heartRateStaleSeconds")
    }
}

// MARK: - Sync

/// Tunables for the watch-side pending payload queue (FR-E-1).
public struct SyncConfiguration: Codable, Sendable, Hashable {
    public var maxPendingBytes: Int = 50 * 1024 * 1024
    public var maxPendingRuns: Int = 50

    public init() {}

    public func validate() throws {
        guard maxPendingBytes > 0, maxPendingRuns > 0 else {
            throw ConfigurationError.inconsistent(
                field: "sync", reason: "pending limits must be positive"
            )
        }
    }
}

// MARK: - Presentation

/// Tunables the UI reads. Held here rather than in the app so that both watch tiers
/// cannot drift apart on timing.
public struct PresentationConfiguration: Codable, Sendable, Hashable {
    public var colourTransitionSeconds: Double = 0.4
    /// Dimmed-variant opacity for secondary metrics under always-on (AC-FR-A-6-6).
    public var alwaysOnSecondaryOpacity: Double = 0.4

    public init() {}

    public func validate() throws {
        try requireInRange(colourTransitionSeconds, 0...5, "presentation.colourTransitionSeconds")
        try requireInRange(alwaysOnSecondaryOpacity, 0...1, "presentation.alwaysOnSecondaryOpacity")
    }
}

// MARK: - Degradation

/// Tunables for degraded-mode behaviour (requirements.md §8).
public struct DegradationConfiguration: Codable, Sendable, Hashable {
    /// Band widening applied when GPS has degraded (DEG-1).
    public var degradedBandWideningFactor: Double = 1.5
    /// Battery fraction below which low-power mode is offered (DEG-5).
    public var lowPowerBatteryThreshold: Double = 0.10
    /// Reduced sample interval in low-power mode — 0.2 Hz.
    public var lowPowerSampleIntervalSeconds: Double = 5

    public init() {}

    public func validate() throws {
        try requireInRange(degradedBandWideningFactor, 1...5, "degradation.degradedBandWideningFactor")
        try requireInRange(lowPowerBatteryThreshold, 0...1, "degradation.lowPowerBatteryThreshold")
        try requireInRange(lowPowerSampleIntervalSeconds, 0.1...60, "degradation.lowPowerSampleIntervalSeconds")
    }
}
