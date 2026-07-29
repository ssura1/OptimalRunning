import Foundation
import ORModels

// MARK: - Errors

/// A configuration value outside its permitted range.
///
/// Named per-field rather than a single `invalid` case so a validation failure says
/// *which* knob was turned too far, which is the whole point of validating.
public struct MotionConfigurationError: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let reason: String
    public var description: String { "\(field): \(reason)" }
}

// MARK: - Sampling

/// How motion samples arrive, and when their absence becomes a degradation.
public struct MotionSamplingConfiguration: Codable, Sendable, Hashable {
    /// Nominal device-motion rate, Hz. Default 100 — enough to resolve footfall impact
    /// peaks, which is the published working point for gait accelerometry
    /// (standalone/requirements.md §13).
    public var nominalHz: Double
    /// Fraction of the nominal rate below which delivery counts as starvation
    /// (AC-FR-S-B-1-4).
    public var minimumDeliveryFraction: Double
    /// Window over which delivery is judged, seconds.
    public var starvationWindowSeconds: Double

    public init(
        nominalHz: Double = 100,
        minimumDeliveryFraction: Double = 0.6,
        starvationWindowSeconds: Double = 10
    ) {
        self.nominalHz = nominalHz
        self.minimumDeliveryFraction = minimumDeliveryFraction
        self.starvationWindowSeconds = starvationWindowSeconds
    }

    func validate() throws {
        guard (25...200).contains(nominalHz) else {
            throw MotionConfigurationError(field: "sampling.nominalHz", reason: "must be in 25...200")
        }
        guard (0.1...1.0).contains(minimumDeliveryFraction) else {
            throw MotionConfigurationError(
                field: "sampling.minimumDeliveryFraction", reason: "must be in 0.1...1.0")
        }
        guard (1.0...60.0).contains(starvationWindowSeconds) else {
            throw MotionConfigurationError(
                field: "sampling.starvationWindowSeconds", reason: "must be in 1...60")
        }
    }
}

// MARK: - Filters

/// The two bands of standalone/design.md §3.3.
public struct MotionFilterConfiguration: Codable, Sendable, Hashable {
    /// Gait band low cutoff, Hz.
    public var gaitLowHz: Double
    /// Gait band high cutoff, Hz.
    ///
    /// **Deliberately not the 3 Hz low-pass the handheld walking literature uses.** At
    /// running cadences the step fundamental is 2.5–3.2 Hz, sitting on and above that
    /// cutoff, so a transplanted 3 Hz filter would attenuate the one component this
    /// tier needs most — the classic way to build something that passes a walk test and
    /// fails on a run.
    public var gaitHighHz: Double
    /// Impact band low cutoff, Hz. Above the gait fundamentals, so the arm swing is
    /// gone and footfall transients are what remains.
    public var impactLowHz: Double
    /// Impact band high cutoff, Hz.
    public var impactHighHz: Double
    /// Cutoff of the low-pass that turns the rectified impact band into an envelope, Hz.
    public var impactEnvelopeHz: Double

    public init(
        gaitLowHz: Double = 0.7,
        gaitHighHz: Double = 7.0,
        impactLowHz: Double = 5.0,
        impactHighHz: Double = 25.0,
        impactEnvelopeHz: Double = 5.0
    ) {
        self.gaitLowHz = gaitLowHz
        self.gaitHighHz = gaitHighHz
        self.impactLowHz = impactLowHz
        self.impactHighHz = impactHighHz
        self.impactEnvelopeHz = impactEnvelopeHz
    }

    func validate(nominalHz: Double) throws {
        guard gaitLowHz > 0, gaitLowHz < gaitHighHz else {
            throw MotionConfigurationError(
                field: "filters.gaitLowHz", reason: "must be positive and below gaitHighHz")
        }
        guard impactLowHz < impactHighHz else {
            throw MotionConfigurationError(
                field: "filters.impactLowHz", reason: "must be below impactHighHz")
        }
        // Nyquist. A cutoff above half the sample rate is not a filter, it is a
        // misunderstanding, and it produces a plausible-looking useless signal.
        let nyquist = nominalHz / 2
        guard impactHighHz < nyquist else {
            throw MotionConfigurationError(
                field: "filters.impactHighHz",
                reason: "must be below Nyquist (\(nyquist) Hz at \(nominalHz) Hz sampling)")
        }
        guard impactEnvelopeHz > 0, impactEnvelopeHz < nyquist else {
            throw MotionConfigurationError(
                field: "filters.impactEnvelopeHz", reason: "must be positive and below Nyquist")
        }
    }
}

// MARK: - Cadence

/// Cadence estimation (standalone/design.md §4).
public struct CadenceConfiguration: Codable, Sendable, Hashable {
    /// Autocorrelation window, seconds. 5.12 s is 512 samples at 100 Hz.
    public var windowSeconds: Double
    /// Physiological cadence floor, steps per minute (AC-FR-S-B-2-3).
    public var minStepsPerMinute: Double
    /// Physiological cadence ceiling, steps per minute.
    ///
    /// Together with the floor this is what *resolves* the stride-versus-step ambiguity
    /// rather than merely constraining it: the two readings of a dominant lag map to
    /// disjoint lag intervals, so no frequency threshold is needed and none can be
    /// straddled (design.md §4.3).
    public var maxStepsPerMinute: Double
    /// Minimum normalized autocorrelation at the chosen lag for an estimate to be
    /// emitted at all.
    public var minimumPeakCorrelation: Double
    /// Cadence change, spm, beyond which a new estimate is treated as unstable relative
    /// to the previous window and loses confidence.
    public var stabilityToleranceSpm: Double
    /// How strong the half-lag peak must be, relative to the chosen peak, to count as
    /// harmonic confirmation of a stride reading (design.md §4.3).
    public var harmonicConfirmationRatio: Double
    /// Half-width of the low-confidence guard band around the lag where the two
    /// readings meet, in seconds.
    public var ambiguityGuardSeconds: Double
    /// Cadence floor, steps per minute, for a lag the harmonic structure refuses to call a
    /// stride ([S-062](../../../../../../docs/standalone/implementation.md#s-062)).
    ///
    /// The disjoint-interval rule assumes the true cadence is inside
    /// `[minStepsPerMinute, maxStepsPerMinute]`. When it is not, the rule does not degrade —
    /// it silently *reinterprets*. A walk at 104 spm has a step period of 0.579 s, which is
    /// outside the step interval `[0.25, 0.5]` and therefore lands in the stride interval,
    /// and 120/0.579 = 207.3 spm is reported. Measured on the two walk traces: 207.8 against
    /// a true 103.7, and 211.2 against 106.1 — ratios of 2.005 and 1.991.
    ///
    /// So a stride reading is now required to *earn* it, from the periodicity at half the
    /// lag that a stride must have and a walking step does not. A contradicted stride is
    /// re-read as a step down to this floor rather than doubled.
    ///
    /// 60 spm is not arbitrary: the correlator already searches to `120/minStepsPerMinute`
    /// = 1.0 s, and a step reading at that longest admissible lag is exactly 60 spm. This
    /// widens the *interpretation*, not the search, which is why it costs nothing and
    /// cannot destabilise the running path.
    public var slowGaitFloorStepsPerMinute: Double
    /// Gait-band RMS, m/s², at or above which a stride reading is credible on amplitude
    /// alone and is never re-read as a slow step ([S-062](../../../../../../docs/standalone/implementation.md#s-062)).
    ///
    /// The harmonic check cannot carry this decision by itself. A running stride whose arm
    /// swing dominates its impacts has a weak half-lag correlation for the same reason a
    /// walking step does, so periodicity alone cannot separate a 160 spm runner from a 104
    /// spm walker — the property suite proved it by halving the former.
    ///
    /// Amplitude can, and it is the physical question: the two readings of such a lag are a
    /// walking cadence and a running one. Measured over 5.12 s windows of the same
    /// gait-band signal this threshold is compared against — so these are the numbers the
    /// code actually sees, not a proxy:
    ///
    /// | Trace | p5 | median | p95 |
    /// |---|---|---|---|
    /// | walk `…-1959` | 2.63 | 3.02 | 3.64 |
    /// | walk `…-2023` | 2.14 | 2.68 | 3.49 |
    /// | slow mile | 7.09 | 7.96 | 9.14 |
    /// | tempo | 9.58 | 10.91 | 12.64 |
    ///
    /// The gap runs from 3.64 to 7.09 with nothing in it. 5.0 sits inside it at 1.37x the
    /// loudest walking window and 0.71x the quietest running one.
    ///
    /// **Two gaits from one runner set this**, so it is a floor with real evidence behind it
    /// and no claim to generality. It is deliberately placed so that *running is never
    /// re-read*: being wrong here costs a walk shown at double, not a run shown at half.
    public var strideReadingRMSFloor: Double
    /// Confidence in `[0, 1]` below which a cadence estimate is not trusted by downstream
    /// consumers — the calibrator, and the phase-locked step fallback.
    ///
    /// Deliberately **not** `minimumPeakCorrelation`. That is a floor on the raw
    /// autocorrelation peak and it gates whether an estimate is emitted at all;
    /// confidence is a *product* of three factors (§4.4) and therefore lives on a
    /// different scale entirely. Reusing one for the other was the first implementation
    /// and it silently made the calibration gate far laxer than it reads.
    public var minimumTrustedConfidence: Double

    public init(
        windowSeconds: Double = 5.12,
        minStepsPerMinute: Double = 120,
        maxStepsPerMinute: Double = 240,
        minimumPeakCorrelation: Double = 0.30,
        stabilityToleranceSpm: Double = 12,
        harmonicConfirmationRatio: Double = 0.5,
        ambiguityGuardSeconds: Double = 0.03,
        slowGaitFloorStepsPerMinute: Double = 60,
        strideReadingRMSFloor: Double = 5.0,
        minimumTrustedConfidence: Double = 0.4
    ) {
        self.slowGaitFloorStepsPerMinute = slowGaitFloorStepsPerMinute
        self.strideReadingRMSFloor = strideReadingRMSFloor
        self.windowSeconds = windowSeconds
        self.minStepsPerMinute = minStepsPerMinute
        self.maxStepsPerMinute = maxStepsPerMinute
        self.minimumPeakCorrelation = minimumPeakCorrelation
        self.stabilityToleranceSpm = stabilityToleranceSpm
        self.harmonicConfirmationRatio = harmonicConfirmationRatio
        self.ambiguityGuardSeconds = ambiguityGuardSeconds
        self.minimumTrustedConfidence = minimumTrustedConfidence
    }

    /// Shortest step period admitted, seconds. Derived, never stored.
    public var minimumStepPeriod: Double { 60 / maxStepsPerMinute }
    /// Longest step period admitted, seconds.
    public var maximumStepPeriod: Double { 60 / minStepsPerMinute }

    func validate() throws {
        guard (2.0...8.0).contains(windowSeconds) else {
            throw MotionConfigurationError(
                field: "cadence.windowSeconds", reason: "must be in 2...8")
        }
        guard minStepsPerMinute > 0, minStepsPerMinute < maxStepsPerMinute else {
            throw MotionConfigurationError(
                field: "cadence.minStepsPerMinute",
                reason: "must be positive and below maxStepsPerMinute")
        }
        // The disjoint-interval rule of design.md §4.3 requires exactly this: the step
        // reading is valid for lag in [60/max, 60/min] and the stride reading for
        // [120/max, 120/min]. Those touch at 60/min == 120/max only when the range spans
        // exactly a factor of two. A wider range makes them overlap and the rule stops
        // being exact — so the invariant is enforced here rather than assumed there.
        guard maxStepsPerMinute <= 2 * minStepsPerMinute else {
            throw MotionConfigurationError(
                field: "cadence.maxStepsPerMinute",
                reason: "must be at most twice minStepsPerMinute, or the stride/step "
                    + "lag intervals overlap and the ambiguity is no longer resolvable")
        }
        // The re-read of a contradicted stride is bounded by what the correlator actually
        // searched. Its longest admissible lag is `120/minStepsPerMinute`, and a *step*
        // reading there is `minStepsPerMinute/2` — so a floor below that would promise a
        // cadence no window could ever produce.
        guard slowGaitFloorStepsPerMinute >= minStepsPerMinute / 2,
            slowGaitFloorStepsPerMinute <= minStepsPerMinute
        else {
            throw MotionConfigurationError(
                field: "cadence.slowGaitFloorStepsPerMinute",
                reason: "must be in [minStepsPerMinute/2, minStepsPerMinute] — below that "
                    + "the correlator never searched the lag, above it the floor is dead")
        }
        guard strideReadingRMSFloor > 0 else {
            throw MotionConfigurationError(
                field: "cadence.strideReadingRMSFloor", reason: "must be positive")
        }
        guard (0.0...1.0).contains(minimumPeakCorrelation) else {
            throw MotionConfigurationError(
                field: "cadence.minimumPeakCorrelation", reason: "must be in 0...1")
        }
        guard stabilityToleranceSpm > 0 else {
            throw MotionConfigurationError(
                field: "cadence.stabilityToleranceSpm", reason: "must be positive")
        }
        guard (0.0...1.0).contains(harmonicConfirmationRatio) else {
            throw MotionConfigurationError(
                field: "cadence.harmonicConfirmationRatio", reason: "must be in 0...1")
        }
        guard ambiguityGuardSeconds >= 0 else {
            throw MotionConfigurationError(
                field: "cadence.ambiguityGuardSeconds", reason: "must be non-negative")
        }
        guard (0.0...1.0).contains(minimumTrustedConfidence) else {
            throw MotionConfigurationError(
                field: "cadence.minimumTrustedConfidence", reason: "must be in 0...1")
        }
    }
}

// MARK: - Step detection

/// Step-event detection (standalone/design.md §4.2).
public struct StepDetectionConfiguration: Codable, Sendable, Hashable {
    /// Refractory interval as a fraction of the current step period. This is what makes
    /// double-counting structurally impossible rather than merely unlikely.
    public var refractoryFraction: Double
    /// Adaptive threshold is `mean + factor × σ` over the trailing window.
    public var thresholdSigmaFactor: Double
    /// Trailing window over which mean and σ are computed, seconds.
    public var thresholdWindowSeconds: Double
    /// RMS of the gait-band signal, m/s², below which the runner is treated as stationary
    /// and **no** step event is emitted — neither detected nor phase-locked
    /// (AC-FR-S-B-3-5, DEG-S-8).
    ///
    /// Needed because the adaptive threshold is *relative*: mean + kσ over a trailing
    /// window follows the signal down, so a runner standing at a traffic light still
    /// produces "peaks" in sensor noise. An absolute floor is the only thing that
    /// distinguishes quiet from stopped. Running gait-band RMS is several m/s²; standing
    /// still is a small fraction of one.
    public var stationaryRMSThreshold: Double

    public init(
        refractoryFraction: Double = 0.6,
        thresholdSigmaFactor: Double = 0.6,
        thresholdWindowSeconds: Double = 2.0,
        stationaryRMSThreshold: Double = 1.0
    ) {
        self.refractoryFraction = refractoryFraction
        self.thresholdSigmaFactor = thresholdSigmaFactor
        self.thresholdWindowSeconds = thresholdWindowSeconds
        self.stationaryRMSThreshold = stationaryRMSThreshold
    }

    func validate() throws {
        guard (0.1...0.95).contains(refractoryFraction) else {
            throw MotionConfigurationError(
                field: "steps.refractoryFraction", reason: "must be in 0.1...0.95")
        }
        guard thresholdSigmaFactor >= 0 else {
            throw MotionConfigurationError(
                field: "steps.thresholdSigmaFactor", reason: "must be non-negative")
        }
        guard (0.25...10.0).contains(thresholdWindowSeconds) else {
            throw MotionConfigurationError(
                field: "steps.thresholdWindowSeconds", reason: "must be in 0.25...10")
        }
        guard stationaryRMSThreshold > 0 else {
            throw MotionConfigurationError(
                field: "steps.stationaryRMSThreshold",
                reason: "must be positive — a threshold of zero means never stationary")
        }
    }
}

// MARK: - Step length

/// The step-length model (standalone/design.md §5).
public struct StepLengthConfiguration: Codable, Sendable, Hashable {
    /// Exponent `p` on the dimensionless amplitude group `A / (h·f²)`.
    ///
    /// Default 0.25 is **Weinberg's fourth root, used as a literature prior and not as
    /// an answer**. It was fitted for walking at the hip; design.md §5.3 shows it is
    /// likely too compressive for running from the hand, and S-023 fits it from
    /// recorded traces. Whatever value ends up here must name the trace it came from.
    public var amplitudeExponent: Double
    /// Lower clamp on estimated step length, metres.
    public var minimumMetres: Double
    /// Upper clamp, metres.
    public var maximumMetres: Double
    /// Height the van Oeveren no-GNSS prior is normalized against, metres.
    ///
    /// A declared normalization anchor, **not** a fitted value: the published relation
    /// is a group-level fit that does not state a cohort height, so `h / hRef` assumes
    /// the group mean was near this. Stated here because it is exactly the kind of
    /// assumption that otherwise becomes invisible.
    public var referenceHeightMetres: Double
    /// Height assumed when the runner has not told us theirs (AC-FR-S-B-4-6).
    public var defaultHeightMetres: Double

    public init(
        amplitudeExponent: Double = 0.25,
        minimumMetres: Double = 0.5,
        maximumMetres: Double = 2.5,
        referenceHeightMetres: Double = 1.75,
        defaultHeightMetres: Double = 1.75
    ) {
        self.amplitudeExponent = amplitudeExponent
        self.minimumMetres = minimumMetres
        self.maximumMetres = maximumMetres
        self.referenceHeightMetres = referenceHeightMetres
        self.defaultHeightMetres = defaultHeightMetres
    }

    func validate() throws {
        guard amplitudeExponent > 0, amplitudeExponent <= 2 else {
            throw MotionConfigurationError(
                field: "stepLength.amplitudeExponent", reason: "must be in (0, 2]")
        }
        guard minimumMetres > 0, minimumMetres < maximumMetres else {
            throw MotionConfigurationError(
                field: "stepLength.minimumMetres",
                reason: "must be positive and below maximumMetres")
        }
        guard (1.0...2.5).contains(referenceHeightMetres) else {
            throw MotionConfigurationError(
                field: "stepLength.referenceHeightMetres", reason: "must be in 1.0...2.5")
        }
        guard (1.0...2.5).contains(defaultHeightMetres) else {
            throw MotionConfigurationError(
                field: "stepLength.defaultHeightMetres", reason: "must be in 1.0...2.5")
        }
    }
}

// MARK: - Calibration

/// Online calibration against GNSS (standalone/design.md §6.2).
public struct CalibrationConfiguration: Codable, Sendable, Hashable {
    /// Shortest window that may produce an observation, metres. Below this, GNSS noise
    /// dominates the comparison and the "observation" is measuring the reference.
    public var minimumWindowMetres: Double
    /// Fraction of the way from the current gain to an observation that a single
    /// qualifying window moves it.
    public var learningRate: Double
    /// Hard cap on how far one window may move the gain, as a fraction of the current
    /// gain. This is the difference between a calibrator and an amplifier of GPS noise.
    public var maximumWindowDeltaFraction: Double
    /// Lower bound on the gain. A fit outside the bounds is evidence of a bad window,
    /// not of an unusual runner (AC-FR-S-C-2-3).
    public var minimumGain: Double
    /// Upper bound on the gain.
    public var maximumGain: Double
    /// Width of a cadence band, spm.
    public var cadenceBandWidthSpm: Double
    /// Observations a band needs before its own gain is used instead of the global one.
    public var minimumObservationsPerBand: Int
    /// Observations after which the calibration counts as converged
    /// (AC-FR-S-C-2-6).
    public var convergenceObservations: Int
    /// Fraction of a window's steps that must have carried a confident cadence for the
    /// window to teach the calibrator anything.
    ///
    /// Not 1.0. AC-FR-S-C-2-7 forbids learning from a window "where cadence confidence
    /// was low", and a window that is 95% confident is not that window — but an
    /// all-or-nothing reading made it one, because every run begins with a few seconds of
    /// no cadence estimate at all while the correlation window fills. That disqualified
    /// the *first* window of every run, which is exactly the window a first-ever
    /// calibration depends on.
    public var minimumConfidentStepFraction: Double

    public init(
        minimumWindowMetres: Double = 100,
        learningRate: Double = 0.25,
        maximumWindowDeltaFraction: Double = 0.15,
        minimumGain: Double = 0.6,
        maximumGain: Double = 1.6,
        cadenceBandWidthSpm: Double = 10,
        minimumObservationsPerBand: Int = 3,
        convergenceObservations: Int = 4,
        minimumConfidentStepFraction: Double = 0.8
    ) {
        self.minimumConfidentStepFraction = minimumConfidentStepFraction
        self.minimumWindowMetres = minimumWindowMetres
        self.learningRate = learningRate
        self.maximumWindowDeltaFraction = maximumWindowDeltaFraction
        self.minimumGain = minimumGain
        self.maximumGain = maximumGain
        self.cadenceBandWidthSpm = cadenceBandWidthSpm
        self.minimumObservationsPerBand = minimumObservationsPerBand
        self.convergenceObservations = convergenceObservations
    }

    func validate() throws {
        guard minimumWindowMetres >= 20 else {
            throw MotionConfigurationError(
                field: "calibration.minimumWindowMetres", reason: "must be at least 20")
        }
        guard learningRate > 0, learningRate <= 1 else {
            throw MotionConfigurationError(
                field: "calibration.learningRate", reason: "must be in (0, 1]")
        }
        guard maximumWindowDeltaFraction > 0, maximumWindowDeltaFraction <= 1 else {
            throw MotionConfigurationError(
                field: "calibration.maximumWindowDeltaFraction", reason: "must be in (0, 1]")
        }
        guard minimumGain > 0, minimumGain < 1, maximumGain > 1 else {
            throw MotionConfigurationError(
                field: "calibration.minimumGain",
                reason: "bounds must straddle 1.0 — a gain of exactly 1 must always be legal")
        }
        guard cadenceBandWidthSpm > 0 else {
            throw MotionConfigurationError(
                field: "calibration.cadenceBandWidthSpm", reason: "must be positive")
        }
        guard minimumObservationsPerBand >= 1 else {
            throw MotionConfigurationError(
                field: "calibration.minimumObservationsPerBand", reason: "must be at least 1")
        }
        guard convergenceObservations >= 1 else {
            throw MotionConfigurationError(
                field: "calibration.convergenceObservations", reason: "must be at least 1")
        }
        guard (0.0...1.0).contains(minimumConfidentStepFraction) else {
            throw MotionConfigurationError(
                field: "calibration.minimumConfidentStepFraction", reason: "must be in 0...1")
        }
    }
}

// MARK: - Fusion

/// Distance fusion (standalone/design.md §6.1, §6.3).
public struct MotionFusionConfiguration: Codable, Sendable, Hashable {
    /// Seconds without a usable fix before the motion leg takes over (DEG-S-1).
    public var gnssDropoutSeconds: Double
    /// Maximum horizontal accuracy, metres, for a fix to be usable.
    ///
    /// **Must agree with `PaceEngineConfiguration.rollingPace.maxHorizontalAccuracyMetres`**
    /// (AC-FR-A-1-2). It is duplicated rather than read across because `PhoneMotion`
    /// deliberately does not depend on the pace engine's configuration — and a test
    /// asserts the two defaults are equal, so the duplication cannot drift silently.
    public var maxHorizontalAccuracyMetres: Double
    /// Window over which the two legs are compared, metres (AC-FR-S-C-1-6).
    public var disagreementWindowMetres: Double
    /// Relative disagreement above which the window is flagged and calibration is
    /// suspended.
    public var disagreementFraction: Double
    /// Windows for which calibration stays suspended after a disagreement.
    public var disagreementSuspensionWindows: Int

    public init(
        gnssDropoutSeconds: Double = 10,
        maxHorizontalAccuracyMetres: Double = 20,
        disagreementWindowMetres: Double = 200,
        disagreementFraction: Double = 0.15,
        disagreementSuspensionWindows: Int = 2
    ) {
        self.gnssDropoutSeconds = gnssDropoutSeconds
        self.maxHorizontalAccuracyMetres = maxHorizontalAccuracyMetres
        self.disagreementWindowMetres = disagreementWindowMetres
        self.disagreementFraction = disagreementFraction
        self.disagreementSuspensionWindows = disagreementSuspensionWindows
    }

    func validate() throws {
        guard gnssDropoutSeconds > 0 else {
            throw MotionConfigurationError(
                field: "fusion.gnssDropoutSeconds", reason: "must be positive")
        }
        guard maxHorizontalAccuracyMetres > 0 else {
            throw MotionConfigurationError(
                field: "fusion.maxHorizontalAccuracyMetres", reason: "must be positive")
        }
        guard disagreementWindowMetres >= 50 else {
            throw MotionConfigurationError(
                field: "fusion.disagreementWindowMetres", reason: "must be at least 50")
        }
        guard disagreementFraction > 0, disagreementFraction < 1 else {
            throw MotionConfigurationError(
                field: "fusion.disagreementFraction", reason: "must be in (0, 1)")
        }
        guard disagreementSuspensionWindows >= 0 else {
            throw MotionConfigurationError(
                field: "fusion.disagreementSuspensionWindows", reason: "must be non-negative")
        }
    }
}

// MARK: - The whole thing

/// Every tunable this track declares, in one place (NFR-S-19).
///
/// The standalone analogue of `PaceEngineConfiguration`, and it follows the same rule:
/// **nothing in the estimator reads a literal**. What is deliberately *not* here is
/// `DistanceFusion.maxSwitchJumpMetres` — the 5 m handover bound is a correctness
/// constraint the specification fixes (NFR-S-12), not a value a deployment might
/// legitimately vary, and exposing it as configuration would imply a supported 50 m
/// jump setting. It is declared once, in the type that enforces it, exactly as the
/// watch tiers' equivalent is (design.md §4).
public struct MotionEstimationConfiguration: Codable, Sendable, Hashable {
    public var sampling: MotionSamplingConfiguration
    public var filters: MotionFilterConfiguration
    public var cadence: CadenceConfiguration
    public var steps: StepDetectionConfiguration
    public var stepLength: StepLengthConfiguration
    public var calibration: CalibrationConfiguration
    public var fusion: MotionFusionConfiguration

    public init(
        sampling: MotionSamplingConfiguration = .init(),
        filters: MotionFilterConfiguration = .init(),
        cadence: CadenceConfiguration = .init(),
        steps: StepDetectionConfiguration = .init(),
        stepLength: StepLengthConfiguration = .init(),
        calibration: CalibrationConfiguration = .init(),
        fusion: MotionFusionConfiguration = .init()
    ) {
        self.sampling = sampling
        self.filters = filters
        self.cadence = cadence
        self.steps = steps
        self.stepLength = stepLength
        self.calibration = calibration
        self.fusion = fusion
    }

    public static let `default` = MotionEstimationConfiguration()

    /// Rejects out-of-range values with a message naming the field.
    public func validate() throws {
        try sampling.validate()
        try filters.validate(nominalHz: sampling.nominalHz)
        try cadence.validate()
        try steps.validate()
        try stepLength.validate()
        try calibration.validate()
        try fusion.validate()
    }
}

// MARK: - Plausibility

/// The pace band outside which an implied speed is treated as a sensor artefact.
///
/// Reuses the *same* bounds the core rolling-pace estimator applies (design.md §5.1) so
/// an implausible pace is rejected at one consistent boundary rather than at two that
/// can drift apart. Expressed through `ORModels.Pace` rather than as bare numbers,
/// which is the point of depending on `ORModels` at all.
public enum PlausibleRunningPace {
    public static let fastest = Pace(minutesPerMile: 2)
    public static let slowest = Pace(minutesPerMile: 30)

    /// Whether a speed in metres per second is inside the band.
    public static func admits(metresPerSecond: Double) -> Bool {
        guard metresPerSecond.isFinite, metresPerSecond > 0 else { return false }
        let secondsPerMetre = 1 / metresPerSecond
        return secondsPerMetre >= fastest.secondsPerMetre
            && secondsPerMetre <= slowest.secondsPerMetre
    }
}
