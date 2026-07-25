import Foundation

// MARK: - Pace band

/// The tolerance envelope around the target pace curve (FR-A-3).
///
/// Four independent thresholds rather than two, because the bands are deliberately
/// **asymmetric** (AC-FR-A-3-3). Easy runs are the case that matters: running an easy
/// day too fast is the most common and most costly recreational error, while running
/// it slower is nearly free. So easy gets a tight fast side and a loose slow side.
///
/// All four are fractions of pace, not speed (ADR-003): `fastNear = 0.02` means "2%
/// faster than target", which at an 8:00/mi target is 7:50/mi.
public struct PaceBand: Codable, Sendable, Hashable {
    /// Fraction faster than target at which the zone becomes `slightlyFast`.
    public let fastNear: Double
    /// Fraction faster than target at which the zone becomes `tooFast`.
    public let fastFar: Double
    /// Fraction slower than target at which the zone becomes `slightlySlow`.
    public let slowNear: Double
    /// Fraction slower than target at which the zone becomes `tooSlow`.
    public let slowFar: Double

    public init(fastNear: Double, fastFar: Double, slowNear: Double, slowFar: Double) {
        self.fastNear = fastNear
        self.fastFar = fastFar
        self.slowNear = slowNear
        self.slowFar = slowFar
    }

    /// Convenience for the percentages the requirements are written in.
    public init(
        fastNearPercent: Double,
        fastFarPercent: Double,
        slowNearPercent: Double,
        slowFarPercent: Double
    ) {
        self.init(
            fastNear: fastNearPercent / 100,
            fastFar: fastFarPercent / 100,
            slowNear: slowNearPercent / 100,
            slowFar: slowFarPercent / 100
        )
    }

    // MARK: Defaults (AC-FR-A-3-4)

    /// Symmetric: for a tempo run both errors defeat the session's purpose equally.
    public static let tempo = PaceBand(
        fastNearPercent: 2.0, fastFarPercent: 5.0,
        slowNearPercent: 2.0, slowFarPercent: 5.0
    )

    /// Asymmetric by design — see the type documentation.
    public static let easy = PaceBand(
        fastNearPercent: 3.0, fastFarPercent: 6.0,
        slowNearPercent: 6.0, slowFarPercent: 12.0
    )

    /// Mildly asymmetric: a long run tolerates fading more than surging.
    public static let long = PaceBand(
        fastNearPercent: 2.5, fastFarPercent: 5.5,
        slowNearPercent: 5.0, slowFarPercent: 10.0
    )

    /// Used for interval steps that carry a target but no explicit band.
    public static let interval = PaceBand(
        fastNearPercent: 3.0, fastFarPercent: 6.0,
        slowNearPercent: 3.0, slowFarPercent: 6.0
    )

    public static func standard(for runType: RunType) -> PaceBand {
        switch runType {
        case .tempo: return .tempo
        case .easy: return .easy
        case .long: return .long
        case .interval, .vo2max: return .interval
        }
    }

    /// Widens every threshold by a multiplier.
    ///
    /// Used when GPS has degraded (DEG-1): the signal is noisier, so judging it as
    /// tightly would produce colour changes the runner did not cause.
    public func widened(by factor: Double) -> PaceBand {
        PaceBand(
            fastNear: fastNear * factor,
            fastFar: fastFar * factor,
            slowNear: slowNear * factor,
            slowFar: slowFar * factor
        )
    }

    /// Thresholds must be ordered and positive, or classification is meaningless.
    public var isWellFormed: Bool {
        fastNear > 0 && slowNear > 0
            && fastFar > fastNear && slowFar > slowNear
            && fastFar < 1.0
            && [fastNear, fastFar, slowNear, slowFar].allSatisfy(\.isFinite)
    }
}

// MARK: - Target pace curve

/// The expected pace as a function of run progress (FR-A-2).
///
/// Not flat in general. The defaults keep tempo and easy near-flat and give long runs
/// a real closing drift — see ADR-005 for why the memo's observed opening-fast shape
/// is absorbed by the *band* rather than prescribed by the curve.
public struct TargetPaceCurve: Codable, Sendable, Hashable {
    /// Fraction offset at progress 0. Negative is faster than base.
    public let openingOffset: Double
    /// Fraction offset at progress 1. Positive is slower than base.
    public let closingOffset: Double
    /// Progress at which the ramp from opening to closing begins.
    public let rampStart: Double

    public init(openingOffset: Double, closingOffset: Double, rampStart: Double) {
        self.openingOffset = openingOffset
        self.closingOffset = closingOffset
        self.rampStart = rampStart
    }

    /// Piecewise: flat at `openingOffset` until `rampStart`, then linear to
    /// `closingOffset` at progress 1 (AC-FR-A-2-1).
    public func drift(at progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        guard p > rampStart else { return openingOffset }
        // rampStart is validated below 1, so this denominator cannot be zero.
        let t = (p - rampStart) / (1 - rampStart)
        return openingOffset + (closingOffset - openingOffset) * t
    }

    public func targetPace(base: Pace, progress: Double) -> Pace {
        base.scaled(by: PaceRatio(value: 1 + drift(at: progress)))
    }

    // MARK: Defaults (AC-FR-A-2-2 … 4)

    /// Flat for the first half, then +1.5% by the finish.
    public static let tempo = TargetPaceCurve(
        openingOffset: 0.0, closingOffset: 0.015, rampStart: 0.50
    )

    /// Flat throughout (AC-FR-A-2-3).
    public static let easy = TargetPaceCurve(
        openingOffset: 0.0, closingOffset: 0.0, rampStart: 0.0
    )

    /// Flat for the first 60%, then +4% by the finish — the memo's explicit request
    /// that long runs may fade, and how long runs are actually coached.
    public static let long = TargetPaceCurve(
        openingOffset: 0.0, closingOffset: 0.040, rampStart: 0.60
    )

    /// Interval steps hold their target for the whole rep.
    public static let flat = TargetPaceCurve(
        openingOffset: 0.0, closingOffset: 0.0, rampStart: 0.0
    )

    public static func standard(for runType: RunType) -> TargetPaceCurve {
        switch runType {
        case .tempo: return .tempo
        case .easy: return .easy
        case .long: return .long
        case .interval, .vo2max: return .flat
        }
    }

    public var isWellFormed: Bool {
        rampStart >= 0 && rampStart < 1
            && openingOffset.isFinite && closingOffset.isFinite
            && openingOffset > -1 && closingOffset > -1
    }
}
