import Foundation

/// Normalized autocorrelation over a sliding window, with parabolic peak refinement.
///
/// **Why autocorrelation rather than an FFT** (standalone/design.md §4.1): resolution.
/// A 5.12 s window at 100 Hz gives an FFT bin width of 0.195 Hz, which at a 3 Hz step
/// frequency is 11.7 spm — four times coarser than NFR-S-7's ±3 spm bound, before any
/// noise. The autocorrelation's lag resolution is one sample, and it exposes the whole
/// periodic structure, which is what makes the stride-versus-step ambiguity *resolvable*
/// rather than merely present.
///
/// One sample of lag error is still 5.4 spm at 180 spm, so the parabolic refinement
/// below is not an optimisation — it is what makes the requirement reachable at all.
public struct Autocorrelator: Sendable {

    /// The outcome of one window's analysis.
    public struct Peak: Sendable, Hashable {
        /// Refined lag, seconds.
        public let lag: TimeInterval
        /// Normalized correlation at the peak, in [-1, 1].
        public let correlation: Double
    }

    public let sampleRateHz: Double
    private let windowLength: Int
    private let minLagSamples: Int
    private let maxLagSamples: Int

    private var buffer: [Double]
    private var writeIndex = 0
    private var filled = 0

    public init(
        sampleRateHz: Double,
        windowSeconds: TimeInterval,
        minLagSeconds: TimeInterval,
        maxLagSeconds: TimeInterval
    ) {
        self.sampleRateHz = sampleRateHz
        windowLength = max(8, Int((windowSeconds * sampleRateHz).rounded()))
        minLagSamples = max(1, Int((minLagSeconds * sampleRateHz).rounded(.down)))
        // The window must be comfortably longer than the longest lag or the overlapping
        // region shrinks to nothing and the correlation is computed over a handful of
        // points — which produces large, meaningless values rather than an error.
        maxLagSamples = min(
            windowLength / 2,
            max(minLagSamples + 2, Int((maxLagSeconds * sampleRateHz).rounded(.up))))
        buffer = [Double](repeating: 0, count: windowLength)
    }

    public var isReady: Bool { filled >= windowLength }

    public mutating func append(_ value: Double) {
        buffer[writeIndex] = value.isFinite ? value : 0
        writeIndex = (writeIndex + 1) % windowLength
        if filled < windowLength { filled += 1 }
    }

    public mutating func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        writeIndex = 0
        filled = 0
    }

    /// The window in chronological order, oldest first.
    private func ordered() -> [Double] {
        guard isReady else { return [] }
        var out = [Double](repeating: 0, count: windowLength)
        for i in 0..<windowLength {
            out[i] = buffer[(writeIndex + i) % windowLength]
        }
        return out
    }

    /// Normalized correlation at every admissible integer lag, oldest-first window.
    ///
    /// Normalised over the *overlapping* region on both sides, which keeps the value in
    /// [-1, 1] and stops long lags from being penalised merely for overlapping less.
    public func correlations(_ window: [Double]) -> [Double] {
        guard window.count == windowLength else { return [] }
        var out = [Double](repeating: 0, count: maxLagSamples + 1)
        for lag in minLagSamples...maxLagSamples {
            let n = windowLength - lag
            var dot = 0.0, energyA = 0.0, energyB = 0.0
            for i in 0..<n {
                let a = window[i]
                let b = window[i + lag]
                dot += a * b
                energyA += a * a
                energyB += b * b
            }
            let denominator = (energyA * energyB).squareRoot()
            out[lag] = denominator > 0 ? dot / denominator : 0
        }
        return out
    }

    /// The strongest peak, refined, or `nil` when the window shows no periodicity.
    public mutating func dominantPeak() -> Peak? {
        guard isReady else { return nil }
        let window = ordered()
        let r = correlations(window)
        guard let index = strongestLocalMaximum(in: r) else { return nil }
        let refined = parabolicRefinement(r, around: index)
        return Peak(lag: refined.lag / sampleRateHz, correlation: refined.value)
    }

    /// Correlation at an arbitrary lag in seconds, for the harmonic checks of §4.3.
    ///
    /// Interpolated between integer lags rather than rounded: the checks compare a
    /// refined lag's half and double, which are rarely integers, and rounding would make
    /// the comparison depend on where the peak happened to fall.
    public mutating func correlation(atLag seconds: TimeInterval) -> Double? {
        guard isReady, seconds.isFinite, seconds > 0 else { return nil }
        let window = ordered()
        let r = correlations(window)
        let exact = seconds * sampleRateHz
        let lower = Int(exact.rounded(.down))
        guard lower >= minLagSamples, lower + 1 <= maxLagSamples else { return nil }
        let fraction = exact - Double(lower)
        return r[lower] + (r[lower + 1] - r[lower]) * fraction
    }

    /// How close to the strongest peak another peak must be to be preferred for being at
    /// a shorter lag. See `strongestLocalMaximum` for why this exists.
    private static let fundamentalPreferenceRatio = 0.85

    /// The **fundamental** period, not merely the largest correlation.
    ///
    /// Two rules, and the second one is a bug this suite caught rather than something
    /// anticipated.
    ///
    /// First, a genuine local maximum is required rather than just the largest value: the
    /// largest value in a monotonically decaying correlation is always the shortest
    /// admissible lag, which is not a period, it is an edge.
    ///
    /// Second — and this is the subtle one — a periodic signal correlates with itself at
    /// *every multiple* of its period, and for a clean signal those peaks are all within
    /// floating-point noise of each other. Taking the largest therefore picks an
    /// arbitrary multiple: `testRecoversANonIntegerPeriodToWellUnderOneSample` reported a
    /// **200% period error** on a pure sinusoid at 28.7 samples, because the peak at
    /// 57.4 samples happened to score fractionally higher. The fix is to prefer the
    /// shortest lag whose correlation is within `fundamentalPreferenceRatio` of the best,
    /// which is the standard rule for pitch-style estimators and the right one here.
    ///
    /// It is also safe for the stride-versus-step problem this estimator exists to solve.
    /// If both a step-period and a stride-period peak are present, this picks the step
    /// period — and `CadenceEstimator` maps `L` and `2L` to the *same* cadence anyway
    /// (§4.3), so preferring the shorter lag cannot change the answer, only which reading
    /// produced it.
    private func strongestLocalMaximum(in r: [Double]) -> Int? {
        guard maxLagSamples - 1 >= minLagSamples + 1 else { return nil }

        var peaks: [(lag: Int, value: Double)] = []
        for lag in (minLagSamples + 1)...(maxLagSamples - 1) {
            guard r[lag] > r[lag - 1], r[lag] >= r[lag + 1] else { continue }
            peaks.append((lag, r[lag]))
        }
        guard let best = peaks.max(by: { $0.value < $1.value }) else { return nil }
        let threshold = best.value * Self.fundamentalPreferenceRatio
        // `best.value` can be negative for an anti-correlated signal, in which case
        // scaling by a positive ratio raises rather than lowers the bar. Fall back to the
        // plain maximum there; a negative-peaked window has no fundamental worth finding.
        guard best.value > 0 else { return best.lag }
        return peaks.first(where: { $0.value >= threshold })?.lag ?? best.lag
    }

    /// Sub-sample peak location by fitting a parabola through the peak and neighbours.
    private func parabolicRefinement(
        _ r: [Double], around index: Int
    ) -> (lag: Double, value: Double) {
        let y0 = r[index - 1], y1 = r[index], y2 = r[index + 1]
        let denominator = y0 - 2 * y1 + y2
        guard denominator != 0 else { return (Double(index), y1) }
        let delta = 0.5 * (y0 - y2) / denominator
        // A parabola fitted to three points of a real peak has its vertex between the
        // neighbours. Anything further out means the three points were not a peak, so
        // the integer index is kept rather than trusting an extrapolation.
        guard abs(delta) <= 1 else { return (Double(index), y1) }
        let value = y1 - 0.25 * (y0 - y2) * delta
        return (Double(index) + delta, value)
    }
}
