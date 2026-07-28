import Foundation

/// Detects individual foot strikes (standalone/design.md §4.2).
///
/// Runs on a **different channel** from the cadence estimator, on purpose. The arm swing
/// dominates the gait band and is the best signal for measuring the *rate*; the impact
/// band has the swing filtered out and is the best signal for locating individual
/// *events*. Doing both from one channel is how a detector ends up counting arm swings.
///
/// Two mechanisms make double-counting structurally impossible rather than merely
/// unlikely: an adaptive threshold with peak-hold, so a single foot strike emits once no
/// matter how many local wiggles ride on it, and a refractory interval derived from the
/// live cadence estimate, so no two events can be closer than is physiologically
/// possible at that cadence.
public struct StepDetector: Sendable {
    private let config: StepDetectionConfiguration
    private let sampleRateHz: Double
    private let thresholdWindowSamples: Int
    /// The shortest step period any cadence in the configured range can have.
    ///
    /// The refractory floor used **before any cadence estimate exists**. Without it the
    /// first few seconds of every run have no refractory at all — `(cadence?.period ?? 0)`
    /// is zero, so the gate is open — and the detector can fire arbitrarily fast on the
    /// start-up transient. `testStepEventsNeverViolateTheRefractoryInterval` caught this
    /// with gaps as short as 0.08 s against a 0.15 s bound.
    private let minimumStepPeriod: Double

    // Running statistics over the trailing window, kept as sums so the update is O(1).
    private var window: [Double]
    private var writeIndex = 0
    private var filled = 0
    private var sum = 0.0
    private var sumOfSquares = 0.0

    // Gait-band energy over the same trailing window, for the stationarity gate.
    private var gaitWindow: [Double]
    private var gaitWriteIndex = 0
    private var gaitFilled = 0
    private var gaitSumOfSquares = 0.0

    // Peak-hold state while the envelope is above threshold.
    private var above = false
    private var candidateValue = 0.0
    private var candidateTime: TimeInterval = 0

    // Amplitude accumulation over the current step interval.
    private var intervalMin = Double.infinity
    private var intervalMax = -Double.infinity

    private var lastEventTime: TimeInterval?

    /// How late an impact peak may be, in step periods, before the phase-locked fallback
    /// fills in. Above 1 so a slightly late real peak still wins over a synthesised one.
    private static let fallbackLatenessFactor = 1.75

    /// Cadence confidence below which the fallback will not synthesise events — a
    /// synthesised event at a cadence we do not believe is worse than no event.
    ///
    /// Supplied from `CadenceConfiguration.minimumTrustedConfidence` rather than declared
    /// here, so the calibrator and the fallback cannot come to disagree about what
    /// "trusted" means.
    private let minimumTrustedConfidence: Double

    public init(
        configuration: StepDetectionConfiguration,
        sampleRateHz: Double,
        minimumStepPeriod: Double,
        minimumTrustedConfidence: Double
    ) {
        config = configuration
        self.sampleRateHz = sampleRateHz
        self.minimumStepPeriod = minimumStepPeriod
        self.minimumTrustedConfidence = minimumTrustedConfidence
        thresholdWindowSamples = max(
            4, Int((configuration.thresholdWindowSeconds * sampleRateHz).rounded()))
        window = [Double](repeating: 0, count: thresholdWindowSamples)
        gaitWindow = [Double](repeating: 0, count: thresholdWindowSamples)
    }

    /// Feeds one grid-aligned sample.
    ///
    /// - Parameters:
    ///   - timestamp: grid time, seconds.
    ///   - envelope: impact-band envelope value.
    ///   - gaitVertical: gait-band vertical acceleration, for the amplitude term.
    ///   - cadence: the live cadence estimate, or `nil`.
    /// - Returns: the step events this sample completed. Usually empty.
    public mutating func append(
        timestamp: TimeInterval,
        envelope: Double,
        gaitVertical: Double,
        cadence: CadenceEstimate?
    ) -> [StepEvent] {
        guard timestamp.isFinite, envelope.isFinite else { return [] }

        intervalMin = min(intervalMin, gaitVertical)
        intervalMax = max(intervalMax, gaitVertical)

        let threshold = updateThreshold(with: envelope)
        let stationary = updateGaitEnergy(with: gaitVertical)
        var events: [StepEvent] = []

        // AC-FR-S-B-3-5 / DEG-S-8. Checked before anything else because it must suppress
        // the phase-locked fallback too: the cadence estimate survives its own window
        // length after the runner stops, so without this the detector keeps synthesising
        // steps at a traffic light. The adaptive threshold cannot catch it on its own —
        // being *relative*, it follows the signal down and finds "peaks" in noise.
        if stationary {
            above = false
            return []
        }

        if envelope > threshold {
            if !above || envelope > candidateValue {
                candidateValue = envelope
                candidateTime = timestamp
            }
            above = true
        } else if above {
            // The envelope has fallen back below threshold, so the peak it was holding
            // is complete. Emitting here rather than at the crossing is what collapses a
            // ragged multi-lobed impact into one event.
            above = false
            if let event = emit(at: candidateTime, cadence: cadence, origin: .impactPeak) {
                events.append(event)
            }
        }

        events.append(contentsOf: fallbackEvents(now: timestamp, cadence: cadence))
        return events
    }

    private mutating func updateThreshold(with value: Double) -> Double {
        let outgoing = window[writeIndex]
        if filled == thresholdWindowSamples {
            sum -= outgoing
            sumOfSquares -= outgoing * outgoing
        } else {
            filled += 1
        }
        window[writeIndex] = value
        sum += value
        sumOfSquares += value * value
        writeIndex = (writeIndex + 1) % thresholdWindowSamples

        let n = Double(filled)
        let mean = sum / n
        let variance = max(0, sumOfSquares / n - mean * mean)
        return mean + config.thresholdSigmaFactor * variance.squareRoot()
    }

    /// Trailing RMS of the gait-band signal, and whether it says the runner has stopped.
    ///
    /// Keeps its own ring index rather than borrowing the threshold window's, which was
    /// the first attempt and was wrong in a way that would have been invisible: sharing
    /// an index that another method advances leaves the two windows a sample out of step,
    /// and the running sum then subtracts a value it never added.
    private mutating func updateGaitEnergy(with value: Double) -> Bool {
        guard value.isFinite else { return false }
        if gaitFilled == thresholdWindowSamples {
            let outgoing = gaitWindow[gaitWriteIndex]
            gaitSumOfSquares -= outgoing * outgoing
        } else {
            gaitFilled += 1
        }
        gaitWindow[gaitWriteIndex] = value
        gaitSumOfSquares += value * value
        gaitWriteIndex = (gaitWriteIndex + 1) % thresholdWindowSamples

        guard gaitFilled == thresholdWindowSamples else { return false }
        let rms = (max(0, gaitSumOfSquares) / Double(thresholdWindowSamples)).squareRoot()
        return rms < config.stationaryRMSThreshold
    }

    private mutating func emit(
        at time: TimeInterval, cadence: CadenceEstimate?, origin: StepEventOrigin
    ) -> StepEvent? {
        if let last = lastEventTime {
            guard time > last else { return nil }
            // Falls back to the fastest physiologically admissible step period rather
            // than to zero. Zero would leave the gate wide open for the first few seconds
            // of every run, before any cadence estimate exists.
            let period = cadence?.stepPeriodSeconds ?? minimumStepPeriod
            let refractory = period * config.refractoryFraction
            guard time - last >= refractory else { return nil }
        }
        let amplitude = intervalMax > intervalMin ? intervalMax - intervalMin : 0
        intervalMin = .infinity
        intervalMax = -.infinity
        lastEventTime = time
        return StepEvent(
            timestamp: time,
            amplitude: amplitude,
            stepFrequency: cadence?.stepFrequencyHz ?? 0,
            origin: origin)
    }

    /// Synthesises events at the estimated cadence when the impact channel goes quiet.
    ///
    /// Not a fudge. Motion-derived distance is `Σ stepLength(i)`, and step length is a
    /// function of cadence and amplitude, not of the precise instant of foot strike.
    /// Getting the *rate* right and the individual timing approximate leaves distance
    /// essentially unaffected; losing the rate would halve it. The fallback protects
    /// what matters and concedes what does not — and it labels every event it produces
    /// so a trace can be read for how often it was needed.
    private mutating func fallbackEvents(
        now: TimeInterval, cadence: CadenceEstimate?
    ) -> [StepEvent] {
        guard
            let cadence,
            cadence.confidence >= minimumTrustedConfidence
        else { return [] }
        let period = cadence.stepPeriodSeconds
        guard period > 0 else { return [] }

        guard var last = lastEventTime else {
            // Nothing has ever been detected. Anchor the phase here rather than
            // back-dating events that were never observed.
            lastEventTime = now
            return []
        }

        var events: [StepEvent] = []
        while now - last >= Self.fallbackLatenessFactor * period {
            let synthetic = last + period
            guard let event = emit(at: synthetic, cadence: cadence, origin: .phaseLocked) else {
                break
            }
            events.append(event)
            last = synthetic
        }
        return events
    }

    public mutating func reset() {
        for i in window.indices { window[i] = 0 }
        for i in gaitWindow.indices { gaitWindow[i] = 0 }
        writeIndex = 0
        filled = 0
        sum = 0
        sumOfSquares = 0
        gaitWriteIndex = 0
        gaitFilled = 0
        gaitSumOfSquares = 0
        above = false
        candidateValue = 0
        candidateTime = 0
        intervalMin = .infinity
        intervalMax = -.infinity
        lastEventTime = nil
    }
}
