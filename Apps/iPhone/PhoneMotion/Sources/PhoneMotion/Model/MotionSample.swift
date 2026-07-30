import Foundation
import ORModels

// MARK: - Input

/// One motion sample, in framework-free terms.
///
/// The adapter converts `CMDeviceMotion` into this and hands it over; nothing in this
/// package knows CoreMotion exists (ADR-S-03). Accelerations are in **metres per second
/// squared**, not in g — CoreMotion reports g, so the conversion happens once, at the
/// adapter, rather than being a unit the reader has to remember.
public struct MotionSample: Codable, Sendable, Hashable {
    /// Seconds since the stream started. Monotonic, never wall-clock — determinism
    /// depends on it exactly as `EngineInput.timestamp` does (AC-FR-A-1-6).
    public let timestamp: TimeInterval
    /// Acceleration with gravity already removed, device frame, m/s².
    public let userAcceleration: Vector3
    /// The gravity vector in the device frame, m/s². Points *down*.
    public let gravity: Vector3
    /// Angular velocity, device frame, rad/s. Recorded for carry-position diagnostics;
    /// the estimator does not currently integrate it.
    public let rotationRate: Vector3

    public init(
        timestamp: TimeInterval,
        userAcceleration: Vector3,
        gravity: Vector3,
        rotationRate: Vector3 = .zero
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
    }
}

/// A position fix, in framework-free terms.
///
/// Distinct from `ORModels.LocationSample` only in carrying instantaneous speed and a
/// cumulative distance, both of which the fusion layer uses and the pace engine does
/// not. The adapter builds both from one `CLLocation`.
public struct LocationFix: Codable, Sendable, Hashable {
    public let timestamp: TimeInterval
    /// Cumulative horizontal distance along the track, metres, as accumulated by the
    /// adapter from successive fixes.
    public let cumulativeDistanceMetres: Double
    /// Metres. Negative means the fix is invalid, matching CoreLocation's convention.
    public let horizontalAccuracy: Double
    /// Instantaneous speed, m/s, or `nil` when unavailable.
    public let speedMetresPerSecond: Double?

    public init(
        timestamp: TimeInterval,
        cumulativeDistanceMetres: Double,
        horizontalAccuracy: Double,
        speedMetresPerSecond: Double? = nil
    ) {
        self.timestamp = timestamp
        self.cumulativeDistanceMetres = cumulativeDistanceMetres
        self.horizontalAccuracy = horizontalAccuracy
        self.speedMetresPerSecond = speedMetresPerSecond
    }

    public func isUsable(maxHorizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= maxHorizontalAccuracy
    }
}

// MARK: - Output

/// One detected foot strike.
public struct StepEvent: Codable, Sendable, Hashable {
    public let timestamp: TimeInterval
    /// Peak-to-peak gait-band vertical acceleration over the interval that ended at this
    /// event, m/s². The `A` of the step-length model (design.md §5.2).
    public let amplitude: Double
    /// Step frequency in force at this event, Hz.
    public let stepFrequency: Double
    /// Whether this event came from the impact detector or from the phase-locked
    /// fallback (design.md §4.2).
    public let origin: StepEventOrigin

    public init(
        timestamp: TimeInterval,
        amplitude: Double,
        stepFrequency: Double,
        origin: StepEventOrigin
    ) {
        self.timestamp = timestamp
        self.amplitude = amplitude
        self.stepFrequency = stepFrequency
        self.origin = origin
    }
}

/// How a step event was arrived at.
public enum StepEventOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    /// A peak in the impact envelope — a real, located foot strike.
    case impactPeak
    /// Synthesised at the estimated cadence because the impact channel was not
    /// producing usable peaks. The *rate* is right, the individual instant is
    /// approximate — and for distance, which is a sum of step lengths, the rate is what
    /// matters (design.md §4.2).
    case phaseLocked
}

// `MotionFlag` is declared in `ORModels`, not here.
//
// It used to live in this file, which read naturally — it is the estimator's own vocabulary
// for what went wrong. But these values have to reach the run record and the detail screen
// (AC-FR-S-E-2-4, DEG-S-5), and a type declared here can only get there by every screen that
// shows it importing this package. `Tools/check-phonemotion-isolation.sh` forbids exactly
// that, so the declaration moved to the layer both sides already share.

/// Everything the caller needs, from one call (design.md §7.1).
public struct MotionEstimate: Sendable, Hashable {
    /// The fused figure the adapter hands to `Core` as `EngineInput.cumulativeDistance`.
    public let cumulativeDistanceMetres: Double
    /// Which leg produced the most recent delta. `.location` or `.motionModel`.
    public let source: DistanceSource
    /// Steps per minute, or `nil` when no confident estimate exists.
    public let cadenceStepsPerMinute: Double?
    public let cadenceConfidence: Double
    /// Running totals backing the provenance display (FR-S-E-2).
    public let measuredMetres: Double
    public let estimatedMetres: Double
    /// Cumulative count of detected step events.
    public let stepCount: Int
    /// The calibration as it stands, in the form that crosses the package boundary
    /// (AC-FR-S-C-2-6). Carried on the estimate rather than read from a property so
    /// `tick(at:)` stays the single output entry point it was designed to be.
    public let calibration: CalibrationSummary
    public let flags: Set<MotionFlag>

    public init(
        cumulativeDistanceMetres: Double,
        source: DistanceSource,
        cadenceStepsPerMinute: Double?,
        cadenceConfidence: Double,
        measuredMetres: Double,
        estimatedMetres: Double,
        stepCount: Int,
        calibration: CalibrationSummary,
        flags: Set<MotionFlag>
    ) {
        self.cumulativeDistanceMetres = cumulativeDistanceMetres
        self.source = source
        self.cadenceStepsPerMinute = cadenceStepsPerMinute
        self.cadenceConfidence = cadenceConfidence
        self.measuredMetres = measuredMetres
        self.estimatedMetres = estimatedMetres
        self.stepCount = stepCount
        self.calibration = calibration
        self.flags = flags
    }
}
