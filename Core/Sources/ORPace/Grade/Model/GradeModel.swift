import Foundation
import ORModels

/// Converts terrain slope into a multiplier on the target pace (FR-A-4, ADR-006).
///
/// The basis is Minetti's cost-of-running polynomial, which fits oxygen cost well.
/// Applying it *raw* to a pace target does not work: at −6% grade it would demand an
/// 8:00/mi runner hit 5:47/mi, and its cost minimum sits near −18% grade where pooled
/// athlete data puts the practical minimum nearer −10%. Runners cannot convert
/// metabolic savings into speed one-for-one, because braking forces and turnover
/// limits bound descent speed.
///
/// So the deviation from flat is attenuated asymmetrically — a runner can spend the
/// full metabolic cost of a climb but cannot recover the full saving of a descent —
/// and then clamped. Calibrated against published Grade Adjusted Pace behaviour in the
/// ±3% band where nearly all road running happens: at +2% this gives 1.102 against a
/// reported ≈1.10, and at −2% it gives 0.949 against ≈0.95 (AC-FR-A-4-9).
public struct GradeModel: Sendable {

    private let config: GradeConfiguration

    public init(config: GradeConfiguration) {
        self.config = config
    }

    /// Minetti's cost of running in J·kg⁻¹·m⁻¹ at gradient `g` (dimensionless).
    public static func cost(at g: Double) -> Double {
        // Horner form: fewer multiplications and better conditioned than the
        // literal power series.
        (((((155.4 * g) - 30.4) * g - 43.3) * g + 46.3) * g + 19.5) * g + 3.6
    }

    /// Cost on the level, the normalising constant. Exact by construction.
    public static let levelCost: Double = 3.6

    /// The raw, unattenuated ratio `C(g)/C(0)`. Exposed for tests and for the
    /// post-run explanation of why the applied factor differs from the textbook one.
    public static func rawRatio(at g: Double) -> Double {
        cost(at: g) / levelCost
    }

    /// The multiplier actually applied to the target pace.
    ///
    /// Above 1 means a slower prescribed pace (uphill); below 1 means faster
    /// (downhill), matching AC-FR-A-4-5. Non-finite input yields identity rather than
    /// propagating NaN into the zone classifier, where it would silently produce
    /// `neutral` forever.
    public func factor(at grade: Double) -> PaceRatio {
        guard grade.isFinite else { return .identity }

        let clampedGrade = min(max(grade, config.minGrade), config.maxGrade)
        let lambda = clampedGrade >= 0 ? config.lambdaUp : config.lambdaDown
        let attenuated = 1 + lambda * (GradeModel.rawRatio(at: clampedGrade) - 1)
        let clamped = min(max(attenuated, config.minFactor), config.maxFactor)

        return PaceRatio(value: clamped)
    }

    /// Whether the applied factor is far enough from 1.0 to be worth showing the
    /// runner a hill indicator (AC-FR-A-4-7).
    public func isSignificant(_ factor: PaceRatio) -> Bool {
        abs(factor.value - 1.0) > config.hillIndicatorThreshold
    }

    /// Applies the factor to a target pace.
    public func adjust(_ target: Pace, grade: Double) -> Pace {
        target.scaled(by: factor(at: grade))
    }
}
