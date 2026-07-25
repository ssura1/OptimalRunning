import Foundation

/// A colour in the sRGB space, stored as 8-bit channels.
///
/// `Core` has no UI dependency (ADR-001), so this is deliberately *not* a `Color` or
/// a `UIColor`. Keeping the palette as pure data is what lets contrast and
/// colour-vision-deficiency compliance be unit tests that run on Linux in
/// milliseconds, rather than something a designer eyeballs in a simulator.
public struct SRGBColor: Codable, Sendable, Hashable {

    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB`. Returns `nil` for anything else, so a typo in a
    /// palette definition fails a test rather than rendering black.
    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    public var hexString: String {
        let digits = "0123456789ABCDEF"
        func pair(_ byte: UInt8) -> String {
            let hi = digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))]
            let lo = digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))]
            return "\(hi)\(lo)"
        }
        return "#\(pair(red))\(pair(green))\(pair(blue))"
    }

    public static let white = SRGBColor(red: 255, green: 255, blue: 255)
    public static let black = SRGBColor(red: 0, green: 0, blue: 0)

    // MARK: Linearisation

    /// Channel values in [0, 1], gamma-encoded as stored.
    public var components: (r: Double, g: Double, b: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }

    /// Removes the sRGB transfer function. Every perceptual computation — luminance,
    /// CIELAB, colour-vision simulation — operates on linear light, not on the encoded
    /// values, and conflating the two is the most common way these calculations go
    /// quietly wrong.
    public var linear: (r: Double, g: Double, b: Double) {
        let c = components
        return (SRGBColor.toLinear(c.r), SRGBColor.toLinear(c.g), SRGBColor.toLinear(c.b))
    }

    public static func toLinear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    public static func toEncoded(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    public static func fromLinear(r: Double, g: Double, b: Double) -> SRGBColor {
        func channel(_ value: Double) -> UInt8 {
            UInt8(min(max((toEncoded(value) * 255).rounded(), 0), 255))
        }
        return SRGBColor(red: channel(r), green: channel(g), blue: channel(b))
    }

    // MARK: WCAG

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        let l = linear
        return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
    }

    /// WCAG contrast ratio against another colour, in [1, 21].
    ///
    /// The product requires at least 4.5:1 for every text-on-zone pairing
    /// (AC-FR-J-1-3), and that is asserted for all 24 pairings in test rather than
    /// trusted to review.
    public func contrastRatio(against other: SRGBColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        let lighter = Swift.max(a, b)
        let darker = Swift.min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
