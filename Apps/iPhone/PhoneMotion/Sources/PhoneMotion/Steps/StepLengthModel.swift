import Foundation

/// Estimates the ground distance covered by one step (standalone/design.md §5).
///
/// ## The model
///
///     stepLength = g(c) · C · h · ( A / (h · f²) )^p
///
/// | Symbol | Meaning | Source |
/// |---|---|---|
/// | `A` | Peak-to-peak gait-band vertical acceleration over the step, m/s² | Weinberg's amplitude term |
/// | `h` | Runner height, m | Renaudin et al.'s height scaling |
/// | `f` | Step frequency, Hz | — |
/// | `p` | Amplitude exponent, default 0.25 | Weinberg's fourth root, as a *prior* |
/// | `C` | Scale | **Learned from GNSS. No shipped default** (ADR-S-06) |
/// | `g(c)` | Per-cadence-band gain | Apple's calibrate-against-GPS precedent |
///
/// `A / (h·f²)` is dimensionless — `h·f²` has units of m/s², the same as `A` — which is
/// what lets `C` be a pure number rather than a quantity whose units silently encode a
/// sampling rate. That is the class of bug that survives every test until someone
/// changes the sample rate.
///
/// ## Why the amplitude term is load-bearing rather than a refinement
///
/// Van Oeveren et al. give `SF [strides/min] = 75.01 + 3.006·v [m/s]` over
/// 1.64–4.68 m/s. Inverting it, an **80% increase in speed raises cadence by 7.3% and
/// step length by 68%** — speed at running intensities is almost entirely a step-length
/// phenomenon, exactly opposite to walking. Fitting a cadence-only model to that gives
/// `ds/df ≈ 3.08 m per Hz`, so a 2 spm cadence error becomes a **9.6%** step-length
/// error. A cadence-only model at running speeds amplifies measurement error tenfold,
/// and no amount of measuring cadence better fixes it: the sensitivity is structural.
///
/// ## Why there is no default scale
///
/// Every published coefficient set was fitted to a particular placement, population and
/// gait, and nothing published covers a hand-held phone at running speeds (CON-S-5).
/// Shipping a number lifted from a walking study and presenting the result as an
/// estimate would be exactly the false confidence this track exists to avoid. Learning
/// `C` takes one 100 m window of good GPS — seconds, not runs — so the honest option is
/// also the cheap one.
public struct StepLengthModel: Sendable, Hashable {
    private let config: StepLengthConfiguration
    private let heightMetres: Double
    /// True when the height is the configured default rather than the runner's own
    /// (AC-FR-S-B-4-6).
    public let heightIsAssumed: Bool

    public init(configuration: StepLengthConfiguration, runnerHeightMetres: Double?) {
        config = configuration
        if let h = runnerHeightMetres, h.isFinite, (1.0...2.5).contains(h) {
            heightMetres = h
            heightIsAssumed = false
        } else {
            heightMetres = configuration.defaultHeightMetres
            heightIsAssumed = true
        }
    }

    /// The dimensionless amplitude group, or `nil` when the inputs cannot produce one.
    ///
    /// Public because the calibrator needs exactly this quantity summed over a window in
    /// order to solve for `C`, and recomputing it there would be a second definition of
    /// the model free to disagree with this one.
    public func amplitudeGroup(amplitude: Double, stepFrequencyHz: Double) -> Double? {
        guard
            amplitude.isFinite, amplitude > 0,
            stepFrequencyHz.isFinite, stepFrequencyHz > 0
        else { return nil }
        let denominator = heightMetres * stepFrequencyHz * stepFrequencyHz
        guard denominator > 0 else { return nil }
        let group = amplitude / denominator
        guard group.isFinite, group > 0 else { return nil }
        return pow(group, config.amplitudeExponent)
    }

    /// The unscaled model, `h · (A/(h f²))^p`. Multiplied by `C · g(c)` to get a length.
    public func unscaledLength(amplitude: Double, stepFrequencyHz: Double) -> Double? {
        amplitudeGroup(amplitude: amplitude, stepFrequencyHz: stepFrequencyHz)
            .map { heightMetres * $0 }
    }

    /// The calibrated estimate.
    ///
    /// Returns `nil` — never a default — when there is no scale to apply. A caller with
    /// no calibration should be reporting no motion distance, which is what ADR-S-06
    /// requires and what the fusion layer does.
    public func stepLength(
        amplitude: Double, stepFrequencyHz: Double, scale: Double?, gain: Double
    ) -> StepLengthEstimate? {
        guard
            let scale, scale.isFinite, scale > 0,
            gain.isFinite, gain > 0,
            let unscaled = unscaledLength(amplitude: amplitude, stepFrequencyHz: stepFrequencyHz)
        else { return nil }
        return clamped(gain * scale * unscaled, stepFrequencyHz: stepFrequencyHz, isPrior: false)
    }

    /// The lowest step frequency the van Oeveren inversion is valid at, Hz.
    ///
    /// The published relation was fitted over **1.64–4.68 m/s**, and inverting it maps
    /// that entire speed range onto a startlingly narrow cadence band: 159.88 spm at
    /// 1.64 m/s to 178.16 spm at 4.68 m/s. Below the floor the inversion returns a
    /// *negative* speed — at 150 spm it gives −0.0033 m/s — so this is not a
    /// conservatism, it is the boundary at which the formula stops meaning anything.
    ///
    /// That narrowness is also the sharpest possible statement of design.md §5.1's
    /// argument: a 185% increase in running speed shows up as an 11% increase in
    /// cadence, so a model that reads speed from cadence is reading an 11% signal to
    /// explain a 185% effect.
    public static let priorMinimumStepFrequencyHz = (75.01 + 3.006 * 1.64) / 30
    /// The highest step frequency the inversion is valid at, Hz. Above it the model
    /// extrapolates hard — 190 spm implies 6.65 m/s, a 4:02/mi pace, for anyone whose
    /// feet happen to turn over quickly.
    public static let priorMaximumStepFrequencyHz = (75.01 + 3.006 * 4.68) / 30

    /// The zero-parameter fallback used when GNSS has never been available and no
    /// calibration exists (DEG-S-2, design.md §5.4).
    ///
    ///     v = (30·f − 75.01) / 3.006 ,   stepLength = (h/hRef) · v / f
    ///
    /// This is the steep, error-amplifying inversion the model above exists to avoid —
    /// which is precisely why it is the *last* resort and why NFR-S-11 bounds it at 12%
    /// rather than 6%. It is used because the alternative is reporting nothing at all,
    /// and unlike an invented constant its provenance is published.
    ///
    /// Returns `nil` outside the relation's published validity band. Extrapolating a
    /// group-level linear fit past its own data is how a runner with a quick, short
    /// stride gets told they are running 4:02 miles.
    public func priorStepLength(stepFrequencyHz f: Double) -> StepLengthEstimate? {
        guard f.isFinite, f > 0 else { return nil }
        guard
            f >= Self.priorMinimumStepFrequencyHz,
            f <= Self.priorMaximumStepFrequencyHz
        else { return nil }
        let strideFrequencyPerMinute = 30 * f
        let speed = (strideFrequencyPerMinute - 75.01) / 3.006
        guard speed.isFinite, speed > 0 else { return nil }
        let scaled = (heightMetres / config.referenceHeightMetres) * speed / f
        return clamped(scaled, stepFrequencyHz: f, isPrior: true)
    }

    private func clamped(
        _ raw: Double, stepFrequencyHz: Double, isPrior: Bool
    ) -> StepLengthEstimate? {
        guard raw.isFinite else { return nil }
        var metres = raw
        var wasClamped = false
        if metres < config.minimumMetres {
            metres = config.minimumMetres
            wasClamped = true
        } else if metres > config.maximumMetres {
            metres = config.maximumMetres
            wasClamped = true
        }
        // The implied speed is checked against the *same* band the core rolling-pace
        // estimator applies (design.md §5.1), so an implausible pace is rejected at one
        // consistent boundary rather than at two that can drift apart.
        let impliedSpeed = metres * stepFrequencyHz
        guard PlausibleRunningPace.admits(metresPerSecond: impliedSpeed) else { return nil }
        return StepLengthEstimate(metres: metres, wasClamped: wasClamped, usedPrior: isPrior)
    }
}

/// One step's estimated length, with what happened to it on the way out.
public struct StepLengthEstimate: Sendable, Hashable {
    public let metres: Double
    /// A clamp is flagged, never silent (AC-FR-S-B-4-4) — a run full of clamped steps is
    /// a model that is wrong, and it should be visible as that rather than as a
    /// suspiciously tidy distance.
    public let wasClamped: Bool
    /// Whether this came from the published no-GNSS prior rather than the calibrated
    /// model.
    public let usedPrior: Bool
}
