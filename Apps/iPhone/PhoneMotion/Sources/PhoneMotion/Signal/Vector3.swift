import Foundation

/// A three-component vector in the device frame.
///
/// Deliberately not `SIMD3<Double>`: this package is arithmetic that must produce
/// bit-identical results on Linux and on a phone (NFR-S-14), and hand-written scalar
/// operations make the evaluation order explicit rather than leaving it to whatever a
/// vectoriser decides on each platform.
public struct Vector3: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    public func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    /// Unit vector, or `nil` when the magnitude is zero or non-finite.
    ///
    /// Returning `nil` rather than a zero vector is load-bearing: a zero "unit" vector
    /// would silently project every acceleration onto nothing, and the vertical channel
    /// would read as a flat zero — a runner standing perfectly still, forever, with no
    /// error anywhere.
    public var normalized: Vector3? {
        let m = magnitude
        guard m.isFinite, m > 0 else { return nil }
        return Vector3(x: x / m, y: y / m, z: z / m)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
}
