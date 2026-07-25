import Foundation

// MARK: - Small matrix

/// A 3×3 matrix, just enough for colour-space transforms.
///
/// The inverse is computed rather than hardcoded: a transcribed inverse is a silent
/// correctness risk nobody reviews, and a 3×3 inversion is four lines.
public struct Matrix3: Sendable, Equatable {
    public let m: [[Double]]

    public init(_ rows: [[Double]]) {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 })
        self.m = rows
    }

    public func multiply(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
            m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
            m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2
        )
    }

    public func multiply(_ other: Matrix3) -> Matrix3 {
        var out = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                out[i][j] = (0..<3).reduce(0) { $0 + m[i][$1] * other.m[$1][j] }
            }
        }
        return Matrix3(out)
    }

    public var determinant: Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    /// Returns `nil` for a singular matrix.
    public var inverse: Matrix3? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        func cof(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) -> Double {
            m[r0][c0] * m[r1][c1] - m[r0][c1] * m[r1][c0]
        }
        let adj: [[Double]] = [
            [cof(1, 2, 1, 2), -cof(0, 2, 1, 2), cof(0, 1, 1, 2)],
            [-cof(1, 2, 0, 2), cof(0, 2, 0, 2), -cof(0, 1, 0, 2)],
            [cof(1, 2, 0, 1), -cof(0, 2, 0, 1), cof(0, 1, 0, 1)],
        ]
        return Matrix3(adj.map { $0.map { $0 / det } })
    }
}

// MARK: - CIELAB

/// A colour in CIE L*a*b*.
public struct LabColor: Sendable, Equatable {
    public let l: Double
    public let a: Double
    public let b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// CIE76 ΔE*ab — Euclidean distance in Lab.
    ///
    /// Note this includes the lightness term, so two colours a dichromat cannot
    /// separate *by hue* can still score a healthy ΔE purely because one is lighter.
    /// That is not a flaw here — the CVD palette is deliberately designed with a wide
    /// lightness spread precisely so that lightness carries the signal when hue
    /// cannot. But it does mean a passing ΔE is not on its own proof of hue
    /// discrimination, which is why redundant glyph-and-delta encoding is
    /// unconditional (FR-J-1) rather than something the CVD palette switches on.
    public func deltaE(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

public enum ColorScience {

    /// sRGB (linear) → CIE XYZ, D65.
    public static let linearRGBToXYZ = Matrix3([
        [0.4124, 0.3576, 0.1805],
        [0.2126, 0.7152, 0.0722],
        [0.0193, 0.1192, 0.9505],
    ])

    /// D65 reference white.
    public static let whitePoint = (x: 0.95047, y: 1.0, z: 1.08883)

    public static func lab(of color: SRGBColor) -> LabColor {
        let l = color.linear
        let (x, y, z) = linearRGBToXYZ.multiply((l.r, l.g, l.b))

        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
        }

        let fx = f(x / whitePoint.x)
        let fy = f(y / whitePoint.y)
        let fz = f(z / whitePoint.z)

        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public static func deltaE(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        lab(of: a).deltaE(to: lab(of: b))
    }
}

// MARK: - Colour vision deficiency

/// The three common dichromacies.
public enum ColorVisionDeficiency: String, Sendable, CaseIterable {
    /// Missing long-wavelength cones. Reds darken toward black.
    case protanopia
    /// Missing medium-wavelength cones. The most common; red and green converge.
    case deuteranopia
    /// Missing short-wavelength cones. Rare; blue and yellow converge.
    case tritanopia
}

/// Simulates dichromatic vision using the Viénot–Brettel–Mollon linear model.
///
/// Used only to *verify* palettes in test (AC-FR-J-2-2), never to render. The point is
/// that a contributor who adjusts a swatch and collapses two zones together finds out
/// from CI in under a minute, rather than from a user who cannot tell whether they are
/// running too fast or too slow.
public enum ColorVisionSimulation {

    /// Linear RGB → LMS cone response.
    public static let rgbToLMS = Matrix3([
        [17.8824, 43.5161, 4.11935],
        [3.45565, 27.1554, 3.86714],
        [0.0299566, 0.184309, 1.46709],
    ])

    public static func transform(for deficiency: ColorVisionDeficiency) -> Matrix3 {
        switch deficiency {
        case .protanopia:
            return Matrix3([
                [0, 2.02344, -2.52581],
                [0, 1, 0],
                [0, 0, 1],
            ])
        case .deuteranopia:
            return Matrix3([
                [1, 0, 0],
                [0.494207, 0, 1.24827],
                [0, 0, 1],
            ])
        case .tritanopia:
            return Matrix3([
                [1, 0, 0],
                [0, 1, 0],
                [-0.395913, 0.801109, 0],
            ])
        }
    }

    public static func simulate(_ color: SRGBColor, as deficiency: ColorVisionDeficiency) -> SRGBColor {
        // Force-unwrap is safe and deliberate: `rgbToLMS` is a compile-time constant
        // with a non-zero determinant, asserted by a test. A nil here would mean the
        // constant had been edited into something meaningless.
        guard let lmsToRGB = rgbToLMS.inverse else { return color }

        let linear = color.linear
        let lms = rgbToLMS.multiply((linear.r, linear.g, linear.b))
        let projected = transform(for: deficiency).multiply(lms)
        let back = lmsToRGB.multiply(projected)

        return SRGBColor.fromLinear(r: back.0, g: back.1, b: back.2)
    }
}
