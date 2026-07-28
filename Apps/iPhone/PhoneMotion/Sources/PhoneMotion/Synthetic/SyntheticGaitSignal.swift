import Foundation

// MARK: - The wall

/// A generated, **labelled** motion signal. Not a recording, and never a substitute for
/// one.
///
/// ## Read this before using it
///
/// The iOS Simulator has no accelerometer and no gyroscope (CON-S-1), so it is tempting
/// to generate "accelerometer-like" data and call the result validation. It is not.
/// A synthetic signal is built from an assumption about what running looks like; running
/// an estimator over it and reporting a distance error measures **the generator's
/// assumption round-tripped through the estimator** — a tautology dressed as a result.
///
/// So this type exists for exactly one purpose: **property tests where the generated
/// label is the ground truth by construction** — a known step count, a known cadence, a
/// known stationary interval. Those are structural claims ("the detector never
/// double-counts") and they are genuinely provable this way.
///
/// It must never appear in a test that asserts a distance-, cadence- or step-count
/// *accuracy percentage* against a reference. That is what recorded traces are for
/// (FR-S-F-2), and `Tools/check-motion-fixtures.sh` fails the build if this type and an
/// accuracy-bound assertion appear in the same file (AC-FR-S-F-3-4).
///
/// The name says `Synthetic` and the directory says `Synthetic` for the same reason: so
/// no reader of a failing test has to wonder which kind of input produced it.
public struct SyntheticGaitSignal: Sendable {

    /// What the generator was asked for — and therefore what is true about the output.
    public struct Labels: Sendable, Hashable {
        /// Exact times of the generated foot strikes.
        public let stepTimes: [TimeInterval]
        /// The cadence the signal was generated at, spm.
        public let stepsPerMinute: Double
        /// Intervals during which no step was generated.
        public let stationaryIntervals: [ClosedRange<TimeInterval>]

        public var stepCount: Int { stepTimes.count }
    }

    public let samples: [MotionSample]
    public let labels: Labels

    // MARK: - Generation

    /// Builds a signal with an arm swing at *stride* frequency and footfall impacts at
    /// *step* frequency — the structure that makes the stride-versus-step ambiguity real
    /// (design.md §3.1).
    ///
    /// - Parameters:
    ///   - stepsPerMinute: cadence.
    ///   - duration: seconds.
    ///   - sampleRateHz: grid rate.
    ///   - armSwingAmplitude: peak arm-swing acceleration, m/s². Set at or above
    ///     `impactAmplitude` to reproduce the case that defeats a fixed frequency
    ///     threshold.
    ///   - impactAmplitude: peak footfall transient, m/s².
    ///   - stationary: an interval during which the runner is standing still.
    ///   - noiseAmplitude: seeded white noise, m/s².
    ///   - seed: RNG seed, so a failure reproduces.
    ///   - rotation: a fixed device attitude, for orientation-invariance tests.
    public static func make(
        stepsPerMinute: Double,
        duration: TimeInterval,
        sampleRateHz: Double = 100,
        armSwingAmplitude: Double = 12,
        impactAmplitude: Double = 8,
        stationary: ClosedRange<TimeInterval>? = nil,
        noiseAmplitude: Double = 0,
        seed: UInt64 = 0x5EED,
        rotation: Rotation = .identity
    ) -> SyntheticGaitSignal {
        let stepFrequency = stepsPerMinute / 60
        let strideFrequency = stepFrequency / 2
        let interval = 1 / sampleRateHz
        var rng = SplitMix64(seed: seed)

        var stepTimes: [TimeInterval] = []
        var t = 1.0 / stepFrequency
        while t < duration {
            if stationary?.contains(t) != true { stepTimes.append(t) }
            t += 1 / stepFrequency
        }

        var samples: [MotionSample] = []
        samples.reserveCapacity(Int(duration * sampleRateHz))
        var time = 0.0
        while time < duration {
            let isStill = stationary?.contains(time) == true
            var vertical = 0.0
            if !isStill {
                // Arm swing: the large, low-frequency component, at stride frequency.
                vertical += armSwingAmplitude * sin(2 * .pi * strideFrequency * time)
                // Footfall impacts: short bursts at step frequency, with energy high
                // enough in frequency to survive the impact band-pass.
                vertical += impactAmplitude * impulse(
                    time: time, stepTimes: stepTimes, carrierHz: 12, widthSeconds: 0.035)
            }
            if noiseAmplitude > 0 {
                vertical += noiseAmplitude * (rng.nextUnit() - 0.5) * 2
            }
            samples.append(sample(at: time, verticalAcceleration: vertical, rotation: rotation))
            time += interval
        }

        return SyntheticGaitSignal(
            samples: samples,
            labels: Labels(
                stepTimes: stepTimes,
                stepsPerMinute: stepsPerMinute,
                stationaryIntervals: stationary.map { [$0] } ?? []))
    }

    /// A Gaussian-windowed burst at each step time.
    private static func impulse(
        time: TimeInterval, stepTimes: [TimeInterval], carrierHz: Double, widthSeconds: Double
    ) -> Double {
        var total = 0.0
        for step in stepTimes {
            let dt = time - step
            if abs(dt) > 4 * widthSeconds { continue }
            let window = exp(-(dt * dt) / (2 * widthSeconds * widthSeconds))
            total += window * cos(2 * .pi * carrierHz * dt)
        }
        return total
    }

    /// Places a world-frame vertical acceleration into the device frame.
    ///
    /// World `z` is up. The device frame is the world frame rotated by `rotation`, so
    /// both the acceleration and gravity are expressed through the same transform — which
    /// is what makes the gravity projection recover the original vertical value exactly,
    /// and therefore what makes the orientation-invariance property test meaningful
    /// rather than circular.
    private static func sample(
        at time: TimeInterval, verticalAcceleration: Double, rotation: Rotation
    ) -> MotionSample {
        let worldAcceleration = Vector3(x: 0, y: 0, z: verticalAcceleration)
        let worldGravity = Vector3(x: 0, y: 0, z: -9.81)
        return MotionSample(
            timestamp: time,
            userAcceleration: rotation.apply(worldAcceleration),
            gravity: rotation.apply(worldGravity))
    }
}

// MARK: - Support

/// A fixed rotation, for placing a synthetic signal into an arbitrary device attitude.
public struct Rotation: Sendable, Hashable {
    private let m: [Double]  // row-major 3×3

    public static let identity = Rotation(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    private init(m: [Double]) { self.m = m }

    /// Rotation of `angle` radians about a unit axis (Rodrigues' formula).
    ///
    /// Written out element by element rather than as one array literal: the nine
    /// compound expressions in a single literal defeat Swift's type checker outright
    /// ("unable to type-check this expression in reasonable time"), which is a compile
    /// error rather than a slow build.
    public static func axisAngle(axis: Vector3, radians angle: Double) -> Rotation {
        guard let u = axis.normalized else { return .identity }
        let c = cos(angle)
        let s = sin(angle)
        let t: Double = 1 - c
        let (x, y, z) = (u.x, u.y, u.z)

        let m00: Double = t * x * x + c
        let m01: Double = t * x * y - s * z
        let m02: Double = t * x * z + s * y
        let m10: Double = t * x * y + s * z
        let m11: Double = t * y * y + c
        let m12: Double = t * y * z - s * x
        let m20: Double = t * x * z - s * y
        let m21: Double = t * y * z + s * x
        let m22: Double = t * z * z + c

        return Rotation(m: [m00, m01, m02, m10, m11, m12, m20, m21, m22])
    }

    public func apply(_ v: Vector3) -> Vector3 {
        Vector3(
            x: m[0] * v.x + m[1] * v.y + m[2] * v.z,
            y: m[3] * v.x + m[4] * v.y + m[5] * v.z,
            z: m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }
}

/// A small, seeded PRNG.
///
/// Hand-rolled rather than `SystemRandomNumberGenerator` for the reason the core track's
/// property suite gives: a failure that cannot be reproduced is not a finding, it is a
/// rumour. Same seed, same signal, forever, on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
