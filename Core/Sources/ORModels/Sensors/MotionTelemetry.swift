import Foundation

// MARK: - Flags

/// A condition worth recording about a motion-derived estimate.
///
/// **Declared here rather than in `PhoneMotion`, and the reason is storage.** A run
/// recorded on the standalone tier has to say afterwards *why* its distance is
/// lower-confidence ([DEG-S-5], AC-FR-S-E-2-4), which means these values travel in the
/// `RunEnvelope` and land in the store and on the detail screen. A type that must reach
/// the hub cannot live in the estimator, or every screen that renders it would have to
/// import the estimator to name it — which is exactly the coupling
/// `Tools/check-phonemotion-isolation.sh` exists to prevent.
///
/// `PhoneMotion` depends on `ORModels`, so it uses this declaration rather than a parallel
/// one. One definition, two sides, nothing to drift.
public enum MotionFlag: String, Codable, Sendable, Hashable, CaseIterable {
    /// Sample delivery fell below the configured fraction of nominal (AC-FR-S-B-1-4).
    case sampleStarvation
    /// The gravity-projected and magnitude channels disagreed persistently, which is
    /// the signature of a degraded attitude estimate rather than of a bad cadence
    /// (standalone/design.md §4.4).
    case gravityEstimateSuspect
    /// A step-length estimate hit a clamp (AC-FR-S-B-4-4).
    case stepLengthClamped
    /// GNSS and motion distance disagreed over a window (AC-FR-S-C-1-6).
    case sourceDisagreement
    /// Distance for part of this run came from the motion model (DEG-S-1).
    case distanceEstimated
    /// The step-length model has no calibration and is running on the published prior
    /// (DEG-S-2, standalone/design.md §5.4).
    case usingUncalibratedPrior
    /// Swing periodicity vanished while the runner kept moving — the signature of the
    /// phone being pocketed or handed over mid-run (DEG-S-7).
    case carryPositionChanged

    /// A sentence a runner can act on, or at least understand.
    ///
    /// Wording lives here rather than in a view because three surfaces show it — the live
    /// screen, the run detail screen, and the post-run summary — and three copies of a
    /// sentence is three chances to describe the same condition differently.
    public var runnerFacingExplanation: String {
        switch self {
        case .sampleStarvation:
            return "The phone stopped delivering motion data quickly enough, so cadence was "
                + "suppressed for part of this run."
        case .gravityEstimateSuspect:
            return "The phone's orientation estimate was unreliable for part of this run."
        case .stepLengthClamped:
            return "Some step lengths were outside the plausible range and were limited."
        case .sourceDisagreement:
            return "GPS and motion distance disagreed for part of this run. GPS was kept."
        case .distanceEstimated:
            return "Part of this run's distance was estimated from motion because GPS was "
                + "unavailable."
        case .usingUncalibratedPrior:
            return "Distance used a published estimate rather than your own calibration, so "
                + "it is less accurate than usual."
        case .carryPositionChanged:
            return "The phone stopped swinging in your hand part-way through, so motion "
                + "distance was not used for that stretch."
        }
    }
}

// MARK: - Telemetry

/// What a motion-sensing feed reports alongside each `EngineInput`.
///
/// **Why this is a second channel rather than fields on `EngineInput`.** `EngineInput` is
/// the contract every tier satisfies, and `RunEngine` is deliberately blind to how distance
/// was obtained (AC-FR-S-C-1-1). Cadence and the measured/estimated split are not engine
/// inputs — the engine must not judge differently because of them — they are *facts about
/// the run* that the screen, the store and the workout writer need. Putting them here keeps
/// the engine's input surface exactly as narrow as it was, which is what makes the watch
/// tiers' goldens still meaningful (AC-FR-S-A-3-4).
public struct MotionTelemetry: Codable, Sendable, Hashable {

    /// Steps per minute, or `nil` when no confident estimate exists (AC-FR-S-B-2-3 requires
    /// *no* cadence rather than an implausible one).
    public let cadenceStepsPerMinute: Double?
    public let cadenceConfidence: Double
    /// Cumulative detected step events.
    public let stepCount: Int
    /// Running totals backing the provenance display (FR-S-E-2).
    public let measuredMetres: Double
    public let estimatedMetres: Double
    public let calibration: CalibrationSummary
    public let flags: Set<MotionFlag>

    public init(
        cadenceStepsPerMinute: Double?,
        cadenceConfidence: Double,
        stepCount: Int,
        measuredMetres: Double,
        estimatedMetres: Double,
        calibration: CalibrationSummary,
        flags: Set<MotionFlag>
    ) {
        self.cadenceStepsPerMinute = cadenceStepsPerMinute
        self.cadenceConfidence = cadenceConfidence
        self.stepCount = stepCount
        self.measuredMetres = measuredMetres
        self.estimatedMetres = estimatedMetres
        self.calibration = calibration
        self.flags = flags
    }

    public static let empty = MotionTelemetry(
        cadenceStepsPerMinute: nil,
        cadenceConfidence: 0,
        stepCount: 0,
        measuredMetres: 0,
        estimatedMetres: 0,
        calibration: .uncalibrated,
        flags: []
    )

    /// Fraction of the distance so far that was observed rather than inferred
    /// (AC-FR-S-E-2-1). `nil` before any distance exists, so the screen shows nothing
    /// rather than "100% measured" over zero metres.
    public var measuredFraction: Double? {
        let total = measuredMetres + estimatedMetres
        guard total > 0 else { return nil }
        return measuredMetres / total
    }
}

/// A feed that reports motion telemetry as well as `EngineInput`.
///
/// A refinement rather than an extension of `RunSensorFeed` because the watch tiers do not
/// have this to report and must not be made to fake it: their distance comes from
/// HealthKit's own fused estimate, so there is no measured/estimated split of *ours* to
/// state. A protocol they do not conform to says that honestly.
public protocol MotionTelemetryReporting: RunSensorFeed {
    /// Invoked on the same tick as `onSample`, and always after it, so a consumer that
    /// rebuilds its screen on telemetry sees the engine output for the same second.
    var onTelemetry: ((MotionTelemetry) -> Void)? { get set }
}

// MARK: - Calibration

/// What the runner and the run record are told about the step-length calibration.
///
/// Deliberately **not** the calibration itself. The learned scale, its per-cadence-band
/// gains and the shape of the update rule are the estimator's business
/// ([ADR-S-06](../../../../docs/standalone/design.md#adr-s-06)); what crosses the boundary
/// is the answer to the two questions anything outside actually asks — "can distance be
/// estimated at all?" and "has it settled?" (AC-FR-S-C-2-6, AC-FR-S-G-1-3).
///
/// `metresPerStepAtTypicalCadence` is here because AC-FR-S-C-2-8 requires the reset to
/// state *what it does*, and "your phone has learned that you cover about 1.01 m per step"
/// is a sentence a runner can evaluate. It is a derived display value, not an input: nothing
/// reads it back.
public struct CalibrationSummary: Codable, Sendable, Hashable {
    public let isCalibrated: Bool
    public let isConverged: Bool
    /// Qualifying GNSS windows folded into the calibration so far.
    public let observationCount: Int
    /// Cadence bands that have enough evidence of their own (AC-FR-S-C-2-5).
    public let bandsWithEvidence: Int
    /// A legible restatement of the learned scale, metres per step at a typical running
    /// cadence. `nil` until anything has been learned.
    public let metresPerStepAtTypicalCadence: Double?

    public init(
        isCalibrated: Bool,
        isConverged: Bool,
        observationCount: Int,
        bandsWithEvidence: Int,
        metresPerStepAtTypicalCadence: Double?
    ) {
        self.isCalibrated = isCalibrated
        self.isConverged = isConverged
        self.observationCount = observationCount
        self.bandsWithEvidence = bandsWithEvidence
        self.metresPerStepAtTypicalCadence = metresPerStepAtTypicalCadence
    }

    public static let uncalibrated = CalibrationSummary(
        isCalibrated: false,
        isConverged: false,
        observationCount: 0,
        bandsWithEvidence: 0,
        metresPerStepAtTypicalCadence: nil
    )
}

/// Where a calibration is kept between runs (AC-FR-S-C-2-2).
///
/// **The payload is opaque `Data` on purpose.** The calibration's encoded shape belongs to
/// the estimator and will change when [S-064](../../../../docs/standalone/implementation.md#s-064)
/// is resolved — a new band layout, a rotation-rate term
/// ([ADR-S-06 amendment 2](../../../../docs/standalone/design.md#adr-s-06-amendment-2)), or
/// a refitted exponent. A store that knew the field names would have to change with it. A
/// store that moves bytes does not, which is the whole point of putting the seam here.
///
/// Keyed by carry position because a calibration learned from a hand-held phone says nothing
/// about a pocketed one (ADR-S-04) — the day a second position exists, its calibration must
/// start empty rather than inherit a number fitted to a different mechanical system.
public protocol CalibrationStoring: AnyObject, Sendable {
    func loadCalibration(for position: CarryPosition) -> Data?
    func saveCalibration(_ payload: Data?, for position: CarryPosition)
}
