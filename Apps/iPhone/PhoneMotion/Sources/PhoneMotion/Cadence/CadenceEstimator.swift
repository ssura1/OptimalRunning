import Foundation
import ORModels

/// One window's cadence estimate.
public struct CadenceEstimate: Sendable, Hashable {
    public let stepsPerMinute: Double
    /// In [0, 1] (design.md §4.4).
    public let confidence: Double
    /// Which reading of the dominant lag produced this, kept for diagnostics — a trace
    /// where the reading flips repeatedly is saying something about the signal.
    public let reading: LagReading
    /// Whether the harmonic structure supported the reading.
    public let harmonic: HarmonicCheck

    public var stepFrequencyHz: Double { stepsPerMinute / 60 }
    public var stepPeriodSeconds: Double { 60 / stepsPerMinute }
}

/// Which period the dominant autocorrelation lag was taken to be.
public enum LagReading: String, Sendable, Hashable, CaseIterable {
    /// The lag was the step period; cadence is `60 / lag`.
    case step
    /// The lag was the stride period — the arm-swing fundamental, which is what
    /// dominates a hand-held trace; cadence is `120 / lag`.
    case stride
}

/// Whether the signal's harmonic structure supported the chosen reading.
public enum HarmonicCheck: String, Sendable, Hashable, CaseIterable {
    case confirmed
    /// The confirming lag fell outside the analysable range, so nothing was learned.
    case notCheckable
    case contradicted
}

/// Cadence from a hand-held phone (standalone/design.md §4).
///
/// The crux of this whole tier. A hand-held phone's dominant periodicity is the **arm
/// swing**, at *stride* frequency — half the cadence. A frequency estimator that
/// returns "the strongest periodic component" returns the stride rate, and a distance
/// built on it is wrong by a factor of two, in the direction a runner is least likely to
/// notice.
///
/// **The published rule does not work here.** Renaudin et al. resolve the same ambiguity
/// for a swinging hand with a fixed 1.4 Hz threshold — above it the strongest frequency
/// is taken as the step rate, below it as the stride rate — justified by walking step
/// frequencies generally exceeding 1.6 Hz. Running stride frequency crosses 1.4 Hz at
/// **exactly 168 spm**, straight through the middle of the recreational running range,
/// so every runner above it would be reported at half their true cadence.
///
/// **The replacement is exact rather than thresholded.** Let `L` be the refined dominant
/// lag. There are two readings, and each admits a disjoint interval of `L` given a
/// physiological cadence range of `[minSpm, maxSpm]` with `maxSpm ≤ 2·minSpm`:
///
/// | Reading | Cadence | Valid when |
/// |---|---|---|
/// | `L` is the step period | `60 / L` | `L ∈ [60/max, 60/min]` |
/// | `L` is the stride period | `120 / L` | `L ∈ [120/max, 120/min]` |
///
/// With the default 120–240 spm those are `[0.25, 0.5]` and `[0.5, 1.0]` — touching at
/// one point, never overlapping. So the range gate *determines* the interpretation
/// instead of merely constraining it, and there is no threshold to straddle.
///
/// Note that the two readings are also mutually consistent, which is what makes the
/// scheme safe rather than merely decidable: if the true step period is `T`, a peak
/// found at `T` yields `60/T` and a peak found at the stride lag `2T` yields
/// `120/(2T) = 60/T`. Whichever component happens to dominate a given window, the
/// cadence is the same.
public struct CadenceEstimator: Sendable {
    private let config: CadenceConfiguration
    private let sampleRateHz: Double
    private let updateIntervalSamples: Int

    private var vertical: Autocorrelator
    /// The same estimator over the gravity-free magnitude channel. Its disagreement with
    /// the vertical channel is the signature of a degraded attitude estimate rather than
    /// of a bad cadence, so it is reported as a flag and **not** folded into confidence
    /// (design.md §4.4).
    private var magnitude: Autocorrelator

    private var samplesSinceUpdate = 0
    private var previous: CadenceEstimate?
    private var consecutiveChannelDisagreements = 0

    /// Windows of channel disagreement before the gravity estimate is called suspect.
    /// Two, so a single anomalous window cannot raise it.
    private static let channelDisagreementThreshold = 3

    public private(set) var flags: Set<MotionFlag> = []

    /// Absolute gait-band RMS below which no cadence is reported at all (S-058).
    ///
    /// Not a second copy of the step detector's floor — it *is* the step detector's floor,
    /// passed in by `MotionEstimator` from `steps.stationaryRMSThreshold`, because a signal
    /// too quiet to contain a footfall is equally too quiet to contain a cadence, and two
    /// numbers that must agree are one number waiting to disagree.
    private let stationaryRMSThreshold: Double

    public init(
        configuration: CadenceConfiguration,
        sampleRateHz: Double,
        stationaryRMSThreshold: Double
    ) {
        config = configuration
        self.sampleRateHz = sampleRateHz
        self.stationaryRMSThreshold = stationaryRMSThreshold
        // Two updates per second: comfortably satisfies "at least once per second"
        // (AC-FR-S-B-2-1) without recomputing the correlation on every sample.
        updateIntervalSamples = max(1, Int((sampleRateHz / 2).rounded()))
        let minLag = 60 / configuration.maxStepsPerMinute
        let maxLag = 120 / configuration.minStepsPerMinute
        vertical = Autocorrelator(
            sampleRateHz: sampleRateHz,
            windowSeconds: configuration.windowSeconds,
            minLagSeconds: minLag,
            maxLagSeconds: maxLag)
        magnitude = vertical
    }

    /// Current best estimate, or `nil` when none is confident enough to report.
    public private(set) var current: CadenceEstimate?

    /// Feeds one grid-aligned sample of each channel.
    ///
    /// Returns a fresh estimate on the windows where one was recomputed, `nil` otherwise
    /// — so a caller can react to updates without polling.
    @discardableResult
    public mutating func append(vertical v: Double?, magnitude m: Double) -> CadenceEstimate? {
        // A missing vertical channel means gravity was degenerate for this sample. Zero
        // is the right filler: it contributes nothing to the correlation rather than
        // injecting a value the runner never produced.
        vertical.append(v ?? 0)
        magnitude.append(m)
        samplesSinceUpdate += 1
        guard samplesSinceUpdate >= updateIntervalSamples else { return nil }
        samplesSinceUpdate = 0
        return recompute()
    }

    private mutating func recompute() -> CadenceEstimate? {
        // ## The stationarity gate, checked before any correlation is interpreted (S-058)
        //
        // Normalised autocorrelation is amplitude-blind: it divides out the window's
        // energy, so sensor noise from a phone held perfectly still correlates just as
        // strongly as a hard effort. In the first field bench test this produced 175–231
        // spm at confidence up to **0.816** across thirty seconds of the runner standing
        // motionless — comfortably above `minimumTrustedConfidence`, so the calibrator
        // would have treated it as evidence and the runner would have been shown a running
        // cadence while stopped at a crossing.
        //
        // Measured, not guessed: over that trace the gait-band RMS was 0.25 m/s² standing,
        // 2.30 walking and 10.44 running, against a floor of 1.0 — roughly a ninefold
        // margin on either side of the boundary.
        //
        // `previous` is cleared as well as `current`. Keeping it would let the stationary
        // window seed the continuity preference of the first moving window, which is the
        // one place a stale estimate does lasting damage.
        if vertical.isReady, vertical.rootMeanSquare < stationaryRMSThreshold,
            magnitude.rootMeanSquare < stationaryRMSThreshold
        {
            current = nil
            previous = nil
            return nil
        }

        // Hoisted into locals, and the analysis made `static`, so that passing
        // `&vertical` does not overlap with an access to the rest of `self`. Calling any
        // method on `self` while one of its stored properties is exclusively borrowed is
        // an exclusivity violation — a compile error, not a subtlety.
        let cadenceConfig = config
        let previousEstimate = previous
        let verticalEstimate = Self.estimate(
            from: &vertical, config: cadenceConfig, previous: previousEstimate)
        let magnitudeEstimate = Self.estimate(
            from: &magnitude, config: cadenceConfig, previous: previousEstimate)
        trackChannelAgreement(verticalEstimate, magnitudeEstimate)

        // The vertical channel is the one the detector is built around; the magnitude
        // channel is insurance. Falling back to it when vertical has nothing to say is
        // strictly better than reporting nothing, and it is exactly the case a bad
        // gravity estimate produces.
        let chosen = verticalEstimate ?? magnitudeEstimate
        previous = chosen ?? previous
        current = chosen
        return chosen
    }

    private mutating func trackChannelAgreement(
        _ a: CadenceEstimate?, _ b: CadenceEstimate?
    ) {
        guard let a, let b else { return }
        if abs(a.stepsPerMinute - b.stepsPerMinute) > config.stabilityToleranceSpm {
            consecutiveChannelDisagreements += 1
            if consecutiveChannelDisagreements >= Self.channelDisagreementThreshold {
                flags.insert(.gravityEstimateSuspect)
            }
        } else {
            consecutiveChannelDisagreements = 0
        }
    }

    private static func estimate(
        from correlator: inout Autocorrelator,
        config: CadenceConfiguration,
        previous: CadenceEstimate?
    ) -> CadenceEstimate? {
        guard let peak = correlator.dominantPeak() else { return nil }
        guard peak.correlation >= config.minimumPeakCorrelation else { return nil }
        guard var resolved = resolve(lag: peak.lag, config: config) else { return nil }

        var harmonic = harmonicCheck(
            reading: resolved.reading, lag: peak.lag, correlator: &correlator, config: config)

        // ## S-062 — a stride reading must be earned, not assigned
        //
        // The disjoint-interval rule assigns the reading from the lag alone, which is exact
        // *provided the true cadence is inside the configured range*. Outside it the rule
        // does not degrade, it reinterprets: a 104 spm walk has a 0.579 s step period, which
        // is not in the step interval, so it lands in the stride interval and is reported as
        // 207.3 spm. Measured on the walk traces at 2.005x and 1.991x true.
        //
        // The signal already says which it is. A stride is two footfalls, so a genuine
        // stride period must carry periodicity at half its lag; a walking step period
        // carries none there, because half a step is the anti-correlation trough. That is
        // exactly what `harmonicCheck` computes and, until now, only *discounted*: it
        // detected the contradiction and reported the doubled number anyway, at reduced
        // confidence. Confidence is the right response to a weak signal, not to a reading
        // the signal contradicts.
        //
        // **The harmonic check alone is not enough**, and the property suite caught it: a
        // running stride with a dominant arm swing and weak impacts (`armSwingAmplitude: 20,
        // impactAmplitude: 4`) has a genuinely weak half-lag correlation too, because the
        // arm swing's own anti-correlation at half its period swamps the small impact term.
        // Read on periodicity alone, that case is indistinguishable from a walking step —
        // both are "one dominant component at lag L, little at L/2". Acting on the harmonic
        // check by itself therefore halved a true 140-200 spm cadence.
        //
        // What separates them is not periodicity but **amplitude**, which is the physical
        // question anyway: walking or running? The two candidate readings of a lag in this
        // interval are 60/L in [60, 120] spm and 120/L in [120, 240] — a walking cadence and
        // a running one. Gait-band RMS over 5.12 s windows of the committed traces tops out
        // at 3.64 m/s² walking and bottoms out at 7.09 running, a gap with nothing in it,
        // consistent with the 0.25 / 2.30 / 10.44 standing/walking/running figures S-058
        // measured independently on the bench trace.
        //
        // So the re-read requires *both*: the signal must contradict a stride, and it must
        // be too quiet to be running. Running is therefore untouched by construction, at any
        // harmonic ratio — which is what makes this safe rather than merely tested.
        if resolved.reading == .stride, harmonic == .contradicted,
            correlator.rootMeanSquare < config.strideReadingRMSFloor
        {
            let asStep = 60 / peak.lag
            if asStep >= config.slowGaitFloorStepsPerMinute {
                resolved = Resolution(
                    stepsPerMinute: asStep, reading: .step, inGuardBand: resolved.inGuardBand)
                harmonic = harmonicCheck(
                    reading: .step, lag: peak.lag, correlator: &correlator, config: config)
            }
        }

        let sharpness = min(1, max(0, peak.correlation))
        let harmonicFactor: Double
        switch harmonic {
        case .confirmed: harmonicFactor = 1.0
        case .notCheckable: harmonicFactor = 0.85
        case .contradicted: harmonicFactor = 0.5
        }
        let stability: Double
        if let previous {
            let delta = abs(resolved.stepsPerMinute - previous.stepsPerMinute)
            stability = max(0, 1 - delta / config.stabilityToleranceSpm)
        } else {
            // No history is not the same as instability, but it is not evidence of
            // stability either, so the first estimate is discounted rather than trusted.
            stability = 0.85
        }
        let guardFactor = resolved.inGuardBand ? 0.5 : 1.0

        return CadenceEstimate(
            stepsPerMinute: resolved.stepsPerMinute,
            confidence: sharpness * harmonicFactor * stability * guardFactor,
            reading: resolved.reading,
            harmonic: harmonic)
    }

    private struct Resolution {
        let stepsPerMinute: Double
        let reading: LagReading
        let inGuardBand: Bool
    }

    /// The disjoint-interval rule. This is the whole of §4.3.
    private static func resolve(lag: TimeInterval, config: CadenceConfiguration) -> Resolution? {
        guard lag.isFinite, lag > 0 else { return nil }
        let stepLow = 60 / config.maxStepsPerMinute
        let stepHigh = 60 / config.minStepsPerMinute
        let strideLow = 2 * stepLow
        let strideHigh = 2 * stepHigh
        // `stepHigh == strideLow` exactly, by the configuration invariant that the
        // cadence range spans at most a factor of two. The guard band straddles that
        // meeting point, where the two readings would give 120 and 240 spm — both far
        // outside real running, so a boundary case degrades rather than flipping.
        let inGuardBand = abs(lag - stepHigh) <= config.ambiguityGuardSeconds

        if lag >= stepLow, lag <= stepHigh {
            return Resolution(
                stepsPerMinute: 60 / lag, reading: .step, inGuardBand: inGuardBand)
        }
        if lag > strideLow, lag <= strideHigh {
            return Resolution(
                stepsPerMinute: 120 / lag, reading: .stride, inGuardBand: inGuardBand)
        }
        return nil
    }

    /// Confirms a reading against the signal's harmonic structure.
    ///
    /// A stride reading should be accompanied by periodicity at half the lag — running
    /// has two footfalls per stride, so step-rate structure must be there. A step
    /// reading should be accompanied by periodicity at double the lag, since the arm
    /// swing is the larger component in a hand-held trace.
    private static func harmonicCheck(
        reading: LagReading,
        lag: TimeInterval,
        correlator: inout Autocorrelator,
        config: CadenceConfiguration
    ) -> HarmonicCheck {
        let confirmingLag = reading == .stride ? lag / 2 : lag * 2
        guard
            let confirming = correlator.correlation(atLag: confirmingLag),
            let atPeak = correlator.correlation(atLag: lag),
            atPeak > 0
        else { return .notCheckable }
        return confirming >= config.harmonicConfirmationRatio * atPeak
            ? .confirmed : .contradicted
    }

    public mutating func reset() {
        vertical.reset()
        magnitude.reset()
        samplesSinceUpdate = 0
        previous = nil
        current = nil
        consecutiveChannelDisagreements = 0
        flags.removeAll()
    }
}
