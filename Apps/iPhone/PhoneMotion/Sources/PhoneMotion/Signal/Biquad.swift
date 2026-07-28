import Foundation

/// A second-order IIR section, direct form II transposed.
///
/// **Causal only — never zero-phase.** Offline gait analysis normally runs a
/// forward-backward pass to avoid phase distortion, and that option is not available
/// here: live estimation and fixture replay must produce bit-identical output
/// (NFR-S-14), and a backward pass is not causal. The cost is a known group delay,
/// accounted for once at the detector rather than pretended away.
///
/// Coefficients follow the standard RBJ audio-EQ cookbook forms with `Q = 1/√2`, which
/// is the second-order Butterworth case: maximally flat passband, −3.01 dB exactly at
/// the cutoff.
public struct Biquad: Sendable, Hashable {
    // Normalized numerator and denominator (a0 divided out).
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var s1: Double = 0
    private var s2: Double = 0

    private static let butterworthQ = 1 / 2.0.squareRoot()

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Second-order Butterworth low-pass at `cutoffHz`, sampled at `sampleRateHz`.
    public static func lowPass(cutoffHz: Double, sampleRateHz: Double) -> Biquad {
        let w = 2 * Double.pi * cutoffHz / sampleRateHz
        let cosw = cos(w)
        let alpha = sin(w) / (2 * butterworthQ)
        return Biquad(
            b0: (1 - cosw) / 2, b1: 1 - cosw, b2: (1 - cosw) / 2,
            a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    /// Second-order Butterworth high-pass at `cutoffHz`.
    public static func highPass(cutoffHz: Double, sampleRateHz: Double) -> Biquad {
        let w = 2 * Double.pi * cutoffHz / sampleRateHz
        let cosw = cos(w)
        let alpha = sin(w) / (2 * butterworthQ)
        return Biquad(
            b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
            a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() {
        s1 = 0
        s2 = 0
    }
}

/// A band-pass built as a high-pass followed by a low-pass.
///
/// Two independent second-order edges rather than a single second-order band-pass
/// section, because the bands here are wide — 0.7–7 Hz spans more than three octaves —
/// and a single section's `Q` would have to be so low that the passband would sag in
/// the middle, right where the step fundamental lives.
public struct BandPassFilter: Sendable, Hashable {
    private var highPass: Biquad
    private var lowPass: Biquad

    public init(lowCutoffHz: Double, highCutoffHz: Double, sampleRateHz: Double) {
        highPass = .highPass(cutoffHz: lowCutoffHz, sampleRateHz: sampleRateHz)
        lowPass = .lowPass(cutoffHz: highCutoffHz, sampleRateHz: sampleRateHz)
    }

    public mutating func process(_ x: Double) -> Double {
        lowPass.process(highPass.process(x))
    }

    public mutating func reset() {
        highPass.reset()
        lowPass.reset()
    }
}

/// Rectify-and-smooth, turning a band-passed impact signal into an envelope.
public struct EnvelopeFollower: Sendable, Hashable {
    private var smoother: Biquad

    public init(cutoffHz: Double, sampleRateHz: Double) {
        smoother = .lowPass(cutoffHz: cutoffHz, sampleRateHz: sampleRateHz)
    }

    public mutating func process(_ x: Double) -> Double {
        smoother.process(abs(x))
    }

    public mutating func reset() { smoother.reset() }
}

// MARK: - Resampling

/// Places irregularly-timed samples onto a uniform grid by linear interpolation.
///
/// Every filter and every autocorrelation in this package assumes a constant sample
/// interval, and real device motion does not quite deliver one — samples are dropped,
/// and delivery jitters. AC-FR-S-B-1-3 requires all timing to come from sample
/// timestamps rather than from an assumed rate, and this is where that requirement is
/// discharged: timestamps decide *where on the grid* a sample lands, and everything
/// downstream then gets the uniform stream it needs.
///
/// A long gap is interpolated across rather than flagged here — that judgement belongs
/// to the starvation detector, which can see the delivery rate over a window rather
/// than one interval at a time (AC-FR-S-B-1-4).
public struct UniformResampler: Sendable {
    public let interval: TimeInterval
    private var lastTime: TimeInterval?
    private var lastValue: Double = 0
    private var nextGridTime: TimeInterval?

    public init(sampleRateHz: Double) {
        interval = 1 / sampleRateHz
    }

    /// Feeds one timed sample; returns the grid values it completes.
    ///
    /// Returns an array because a single late sample can complete several grid points.
    public mutating func ingest(timestamp: TimeInterval, value: Double) -> [(TimeInterval, Double)] {
        guard timestamp.isFinite, value.isFinite else { return [] }
        guard let previousTime = lastTime else {
            lastTime = timestamp
            lastValue = value
            nextGridTime = timestamp
            return []
        }
        // Out-of-order delivery is dropped rather than folded in: interpolating
        // backwards would rewrite grid points already emitted downstream, and a filter
        // cannot un-process a sample.
        guard timestamp > previousTime else { return [] }

        var out: [(TimeInterval, Double)] = []
        var grid = nextGridTime ?? timestamp
        let span = timestamp - previousTime
        while grid <= timestamp {
            let fraction = span > 0 ? (grid - previousTime) / span : 1
            out.append((grid, lastValue + (value - lastValue) * fraction))
            grid += interval
        }
        nextGridTime = grid
        lastTime = timestamp
        lastValue = value
        return out
    }

    public mutating func reset() {
        lastTime = nil
        lastValue = 0
        nextGridTime = nil
    }
}
