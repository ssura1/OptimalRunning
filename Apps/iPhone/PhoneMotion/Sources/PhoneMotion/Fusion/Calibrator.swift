import Foundation
import ORModels

/// The persistable result of calibrating the step-length model against GNSS.
///
/// Persisted between runs so a runner's second run starts calibrated
/// (AC-FR-S-C-2-2).
public struct CalibrationState: Codable, Sendable, Hashable {
    /// The global scale `C`. `nil` until the first qualifying window has ever been
    /// seen — and `nil` genuinely means "no motion distance can be reported", not
    /// "use 1.0" (ADR-S-06).
    public var scale: Double?
    /// Qualifying windows applied to the global scale.
    public var observationCount: Int
    /// Per-cadence-band gains relative to the global scale, keyed by band index.
    public var bands: [Int: BandGain]
    /// GNSS metres divided by counted steps, averaged over the qualifying windows.
    ///
    /// **A measurement, not a model output**, and that is the whole reason it is kept.
    /// AC-FR-S-C-2-8 requires the calibration reset to state what it does, and "your phone
    /// has learned that you cover about 1.01 m per step" is a sentence a runner can check
    /// against their own experience — where "scale 1.284" is not. Deriving it from the
    /// model instead would need a representative amplitude, which is exactly the kind of
    /// fabricated constant ADR-S-06 forbids; this needs none, because both terms were
    /// observed over the same window.
    ///
    /// `nil` until the first qualifying window, and optional in the encoding so a
    /// calibration persisted before this existed still decodes.
    public var measuredMetresPerStep: Double?

    public init(
        scale: Double? = nil,
        observationCount: Int = 0,
        bands: [Int: BandGain] = [:],
        measuredMetresPerStep: Double? = nil
    ) {
        self.scale = scale
        self.observationCount = observationCount
        self.bands = bands
        self.measuredMetresPerStep = measuredMetresPerStep
    }

    /// What the rest of the app is told (AC-FR-S-C-2-6, AC-FR-S-G-1-3).
    ///
    /// The conversion to `ORModels.CalibrationSummary` happens here, in the type that owns
    /// the numbers, rather than at the adapter — so there is one definition of "converged"
    /// and of "a band with evidence", and a caller cannot arrive at a different one.
    public func summary(configuration: CalibrationConfiguration) -> CalibrationSummary {
        CalibrationSummary(
            isCalibrated: scale != nil,
            isConverged: scale != nil && observationCount >= configuration.convergenceObservations,
            observationCount: observationCount,
            bandsWithEvidence: bands.values.count {
                $0.observationCount >= configuration.minimumObservationsPerBand
            },
            metresPerStepAtTypicalCadence: measuredMetresPerStep
        )
    }

    public struct BandGain: Codable, Sendable, Hashable {
        public var gain: Double
        public var observationCount: Int

        public init(gain: Double, observationCount: Int) {
            self.gain = gain
            self.observationCount = observationCount
        }
    }
}

/// One closed window's worth of evidence.
public struct CalibrationObservation: Sendable, Hashable {
    /// GNSS-measured distance over the window, metres. The reference.
    public let referenceMetres: Double
    /// Sum of the model's *unscaled* lengths over the same window — the quantity that,
    /// multiplied by the scale, is supposed to equal the reference.
    public let unscaledSum: Double
    /// Mean cadence over the window, spm, which decides the band.
    public let meanStepsPerMinute: Double
    /// Steps detected over the window. Feeds `measuredMetresPerStep` and nothing else —
    /// the scale is fitted against `unscaledSum`, not against a step count.
    public let stepCount: Int

    public init(
        referenceMetres: Double,
        unscaledSum: Double,
        meanStepsPerMinute: Double,
        stepCount: Int = 0
    ) {
        self.referenceMetres = referenceMetres
        self.unscaledSum = unscaledSum
        self.meanStepsPerMinute = meanStepsPerMinute
        self.stepCount = stepCount
    }
}

/// Learns the step-length model's scale from GNSS (standalone/design.md §6.2).
///
/// Follows the approach Apple documents for the Watch — learn stride length at different
/// speeds by comparing against GPS during outdoor runs, then use the learned model when
/// GPS is unavailable — with the bounds and caps that make it a calibrator rather than
/// an amplifier of GPS noise.
public struct Calibrator: Sendable {
    private let config: CalibrationConfiguration
    public private(set) var state: CalibrationState

    public init(configuration: CalibrationConfiguration, state: CalibrationState = .init()) {
        config = configuration
        self.state = state
    }

    public var isCalibrated: Bool { state.scale != nil }

    public var isConverged: Bool {
        state.scale != nil && state.observationCount >= config.convergenceObservations
    }

    public func band(forStepsPerMinute spm: Double) -> Int {
        guard spm.isFinite, spm > 0 else { return 0 }
        return Int((spm / config.cadenceBandWidthSpm).rounded(.down))
    }

    /// The multiplier to apply at this cadence.
    ///
    /// Falls back to the global scale — gain 1.0 — until a band has enough evidence of
    /// its own. A band gain fitted from one window would be a worse estimate than the
    /// global one it replaced.
    public func gain(forStepsPerMinute spm: Double) -> Double {
        guard let entry = state.bands[band(forStepsPerMinute: spm)] else { return 1 }
        return entry.observationCount >= config.minimumObservationsPerBand ? entry.gain : 1
    }

    /// Applies a qualifying window.
    ///
    /// The caller is responsible for qualification — window length, GNSS quality, cadence
    /// confidence, and the absence of a disagreement flag (AC-FR-S-C-2-7). This type
    /// deliberately does not re-derive those conditions: they depend on state the fusion
    /// layer owns, and a second, subtly different set of them here is how two components
    /// come to disagree about what a good window is.
    @discardableResult
    public mutating func apply(_ observation: CalibrationObservation) -> Bool {
        guard
            observation.referenceMetres.isFinite, observation.referenceMetres > 0,
            observation.unscaledSum.isFinite, observation.unscaledSum > 0
        else { return false }
        let observed = observation.referenceMetres / observation.unscaledSum
        guard observed.isFinite, observed > 0 else { return false }

        recordMeasuredStepLength(observation)

        guard let current = state.scale else {
            // Bootstrap. Taken whole rather than through the bounded update: averaging
            // toward a nonexistent prior is meaningless, and the alternative — a
            // fabricated starting value — is what ADR-S-06 exists to forbid.
            state.scale = observed
            state.observationCount = 1
            applyBand(observed: observed, scale: observed, spm: observation.meanStepsPerMinute)
            return true
        }

        let raw = config.learningRate * (observed - current)
        let cap = config.maximumWindowDeltaFraction * current
        let updated = current + min(max(raw, -cap), cap)
        state.scale = updated
        state.observationCount += 1
        applyBand(observed: observed, scale: updated, spm: observation.meanStepsPerMinute)
        return true
    }

    /// Folds this window's directly-measured metres-per-step into the running figure.
    ///
    /// Averaged with the same learning rate as the scale, so one window with a long red
    /// light in it does not redefine the runner's stride — but deliberately *not* bounded
    /// or clamped like the gain, because this value feeds no calculation. It is shown to a
    /// runner, and a display value that has been quietly limited is a display value that
    /// lies about what was measured.
    private mutating func recordMeasuredStepLength(_ observation: CalibrationObservation) {
        guard observation.stepCount > 0 else { return }
        let metresPerStep = observation.referenceMetres / Double(observation.stepCount)
        guard metresPerStep.isFinite, metresPerStep > 0 else { return }
        guard let existing = state.measuredMetresPerStep else {
            state.measuredMetresPerStep = metresPerStep
            return
        }
        state.measuredMetresPerStep = existing + config.learningRate * (metresPerStep - existing)
    }

    private mutating func applyBand(observed: Double, scale: Double, spm: Double) {
        guard scale > 0, spm.isFinite, spm > 0 else { return }
        let target = min(max(observed / scale, config.minimumGain), config.maximumGain)
        let index = band(forStepsPerMinute: spm)
        if var entry = state.bands[index] {
            let raw = config.learningRate * (target - entry.gain)
            let cap = config.maximumWindowDeltaFraction * entry.gain
            entry.gain = min(
                max(entry.gain + min(max(raw, -cap), cap), config.minimumGain),
                config.maximumGain)
            entry.observationCount += 1
            state.bands[index] = entry
        } else {
            state.bands[index] = CalibrationState.BandGain(gain: target, observationCount: 1)
        }
    }

    public mutating func reset() {
        state = CalibrationState()
    }
}
