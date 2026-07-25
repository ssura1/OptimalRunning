import Foundation

// MARK: - Pace

/// Seconds per metre. The single pace representation in the system (design.md §4).
///
/// Pace is stored rather than speed because every tolerance in the product is expressed
/// as a percentage *of pace* (ADR-003). Storing speed would make a "5% band" asymmetric
/// in the units the runner actually reads.
///
/// Larger values are slower. `Comparable` follows that ordering, so `a < b` means
/// "a is faster than b" — the opposite of the speed intuition, which is why the
/// comparison helpers `isFaster(than:)` / `isSlower(than:)` exist and should be
/// preferred at call sites where the direction matters.
public struct Pace: Hashable, Codable, Sendable {

    /// Metres in one statute mile. Exact by definition.
    public static let metresPerMile: Double = 1609.344

    public let secondsPerMetre: Double

    public init(secondsPerMetre: Double) {
        self.secondsPerMetre = secondsPerMetre
    }

    public init(minutesPerMile: Double) {
        self.secondsPerMetre = minutesPerMile * 60 / Pace.metresPerMile
    }

    public init(secondsPerMile: Double) {
        self.secondsPerMetre = secondsPerMile / Pace.metresPerMile
    }

    public init(minutesPerKilometre: Double) {
        self.secondsPerMetre = minutesPerKilometre * 60 / 1000
    }

    public init(secondsPerKilometre: Double) {
        self.secondsPerMetre = secondsPerKilometre / 1000
    }

    /// Derives pace from a distance and the time taken to cover it.
    /// Returns `nil` for non-positive or non-finite inputs, so callers never
    /// construct an infinite pace from a zero-distance window.
    public init?(distanceMetres: Double, seconds: Double) {
        guard distanceMetres > 0, seconds > 0,
              distanceMetres.isFinite, seconds.isFinite else { return nil }
        self.secondsPerMetre = seconds / distanceMetres
    }

    // MARK: Conversions

    public var secondsPerMile: Double { secondsPerMetre * Pace.metresPerMile }
    public var minutesPerMile: Double { secondsPerMile / 60 }
    public var secondsPerKilometre: Double { secondsPerMetre * 1000 }
    public var minutesPerKilometre: Double { secondsPerKilometre / 60 }
    public var metresPerSecond: Double { 1 / secondsPerMetre }

    /// A pace is usable only if it is finite and strictly positive.
    public var isValid: Bool { secondsPerMetre.isFinite && secondsPerMetre > 0 }

    // MARK: Ratio arithmetic (ADR-003)

    /// Scales pace by a ratio. A ratio above 1 yields a *slower* pace.
    public func scaled(by ratio: PaceRatio) -> Pace {
        Pace(secondsPerMetre: secondsPerMetre * ratio.value)
    }

    /// The ratio of this pace to `reference`. Above 1 means this pace is slower.
    ///
    /// This is the quantity the zone classifier consumes (AC-FR-A-3-2).
    public func ratio(to reference: Pace) -> PaceRatio {
        PaceRatio(value: secondsPerMetre / reference.secondsPerMetre)
    }

    /// How much slower this pace is than `reference`, as a percentage.
    ///
    /// The convention this encodes is load-bearing and is asserted directly by
    /// AC-FR-A-1-4: 540 s/mi is 12.5% slower than 480 s/mi, because 540/480 = 1.125.
    /// A negative result means this pace is faster.
    public func percentSlower(than reference: Pace) -> Double {
        ratio(to: reference).percentSlower
    }

    public func isFaster(than other: Pace) -> Bool { secondsPerMetre < other.secondsPerMetre }
    public func isSlower(than other: Pace) -> Bool { secondsPerMetre > other.secondsPerMetre }

    /// Signed difference in seconds per the given unit. Positive means slower than
    /// `reference` — matching how the run screen renders its delta (AC-FR-J-1-2).
    public func signedDelta(from reference: Pace, in unit: UnitPreference) -> Double {
        switch unit {
        case .miles: return secondsPerMile - reference.secondsPerMile
        case .kilometres: return secondsPerKilometre - reference.secondsPerKilometre
        }
    }
}

extension Pace: Comparable {
    /// Ordered by pace value, so the "smaller" pace is the faster one.
    public static func < (lhs: Pace, rhs: Pace) -> Bool {
        lhs.secondsPerMetre < rhs.secondsPerMetre
    }
}

// MARK: - PaceRatio

/// A dimensionless multiplier on pace. Values above 1 mean slower (ADR-003).
///
/// Having a distinct type rather than a bare `Double` is what stops a speed ratio
/// from being silently substituted for a pace ratio — the two are reciprocals, and
/// the resulting bug would be a subtle mis-classification rather than a crash.
public struct PaceRatio: Hashable, Codable, Sendable {

    public let value: Double

    public static let identity = PaceRatio(value: 1.0)

    public init(value: Double) {
        self.value = value
    }

    /// `PaceRatio(percentSlower: 12.5).value == 1.125` — the memo's worked example.
    /// Negative percentages mean faster.
    public init(percentSlower percent: Double) {
        self.value = 1 + percent / 100
    }

    /// Percentage slower than the reference. Negative means faster.
    public var percentSlower: Double { (value - 1) * 100 }

    public var isSlower: Bool { value > 1 }
    public var isFaster: Bool { value < 1 }

    /// Composes two ratios. Used to apply the grade factor on top of the curve drift.
    public func multiplied(by other: PaceRatio) -> PaceRatio {
        PaceRatio(value: value * other.value)
    }

    public func clamped(to range: ClosedRange<Double>) -> PaceRatio {
        PaceRatio(value: Swift.min(Swift.max(value, range.lowerBound), range.upperBound))
    }
}

extension PaceRatio: Comparable {
    public static func < (lhs: PaceRatio, rhs: PaceRatio) -> Bool { lhs.value < rhs.value }
}
