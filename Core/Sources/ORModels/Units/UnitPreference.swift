import Foundation

/// Whether the runner reads miles or kilometres (AC-FR-I-1-4).
///
/// All stored data is unit-independent — metres and seconds throughout — so changing
/// this preference re-renders history rather than converting it.
public enum UnitPreference: String, Codable, Sendable, Hashable, CaseIterable {
    case miles
    case kilometres

    /// Metres in one unit of the preferred distance.
    public var metresPerUnit: Double {
        switch self {
        case .miles: return Pace.metresPerMile
        case .kilometres: return 1000
        }
    }
}

// MARK: - Formatting

/// Numeric formatting for pace, distance, and duration.
///
/// These produce *numeric* strings only. Unit words and captions are localized in the
/// app layer (NFR-23) — Core has no string catalog and no locale opinion. The symbol
/// helpers here exist for tests, logs, and the replay CLI, and are explicitly not for
/// display without localization.
public enum ORFormat {

    /// Formats a duration as `m:ss`, or `h:mm:ss` past an hour.
    /// Negative durations format with a leading minus and the same shape.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--" }
        let negative = seconds < 0
        let total = Int((abs(seconds)).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let body: String
        if h > 0 {
            body = "\(h):\(pad(m)):\(pad(s))"
        } else {
            body = "\(m):\(pad(s))"
        }
        return negative ? "-\(body)" : body
    }

    /// Formats pace as `m:ss` per the preferred unit. Invalid pace renders as `--`.
    public static func pace(_ pace: Pace?, in unit: UnitPreference) -> String {
        guard let pace, pace.isValid else { return "--" }
        switch unit {
        case .miles: return duration(pace.secondsPerMile)
        case .kilometres: return duration(pace.secondsPerKilometre)
        }
    }

    /// Formats a signed pace delta as `+12` / `-8` seconds per preferred unit.
    /// The sign is always explicit, because an unsigned delta on the run screen is
    /// ambiguous about direction (AC-FR-J-1-2).
    public static func signedSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--" }
        let rounded = Int(seconds.rounded())
        return rounded >= 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// Formats a distance in the preferred unit with the given fractional precision.
    public static func distance(
        _ metres: Double,
        in unit: UnitPreference,
        fractionDigits: Int = 2
    ) -> String {
        guard metres.isFinite else { return "--" }
        let value = metres / unit.metresPerUnit
        return fixed(value, fractionDigits: fractionDigits)
    }

    /// Non-localized unit symbol. Tests and the replay CLI only — see the type note.
    public static func paceSymbol(_ unit: UnitPreference) -> String {
        switch unit {
        case .miles: return "/mi"
        case .kilometres: return "/km"
        }
    }

    // MARK: Private

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Fixed-point formatting without `String(format:)`, which behaves differently
    /// across Foundation implementations and would break Linux/macOS parity.
    private static func fixed(_ value: Double, fractionDigits: Int) -> String {
        guard fractionDigits > 0 else { return "\(Int(value.rounded()))" }
        let scale = pow(10.0, Double(fractionDigits))
        let scaled = (value * scale).rounded()
        let negative = scaled < 0
        let magnitude = Int(abs(scaled))
        let divisor = Int(scale)
        let whole = magnitude / divisor
        let frac = magnitude % divisor
        var fracString = "\(frac)"
        while fracString.count < fractionDigits { fracString = "0" + fracString }
        return "\(negative ? "-" : "")\(whole).\(fracString)"
    }
}
