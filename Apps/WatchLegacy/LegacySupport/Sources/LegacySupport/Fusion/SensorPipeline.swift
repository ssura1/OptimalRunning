import Foundation
import ORModels

/// One tick's worth of raw sensor state, before fusion or interpretation — Legacy tier.
///
/// Every distance field is optional, and `nil` means *this source has nothing to say right
/// now*, never "zero metres". See `DistanceReading` for why that distinction is load-bearing.
public struct RawSensorTick: Sendable, Hashable {
    public let timestamp: TimeInterval
    public let healthKitDistance: Double?
    public let locationDistance: Double?
    public let pedometerDistance: Double?
    public let location: RawLocationReading?
    /// Whether the accompanying fix cleared the adapter's accuracy threshold. Separate from
    /// `location` because an inaccurate fix is still worth recording for the route even when it
    /// must not anchor distance.
    public let isLocationFixUsable: Bool
    public let relativeAltitude: Double?
    public let heartRate: Double?
    public let isPaused: Bool
    public let manualAdvanceRequested: Bool

    public init(
        timestamp: TimeInterval,
        healthKitDistance: Double? = nil,
        locationDistance: Double? = nil,
        pedometerDistance: Double? = nil,
        location: RawLocationReading? = nil,
        isLocationFixUsable: Bool = false,
        relativeAltitude: Double? = nil,
        heartRate: Double? = nil,
        isPaused: Bool = false,
        manualAdvanceRequested: Bool = false
    ) {
        self.timestamp = timestamp
        self.healthKitDistance = healthKitDistance
        self.locationDistance = locationDistance
        self.pedometerDistance = pedometerDistance
        self.location = location
        self.isLocationFixUsable = isLocationFixUsable
        self.relativeAltitude = relativeAltitude
        self.heartRate = heartRate
        self.isPaused = isPaused
        self.manualAdvanceRequested = manualAdvanceRequested
    }
}

/// Turns raw sensor readings into the `EngineInput` stream Core consumes — Legacy tier (T-063,
/// T-064).
///
/// The entirety of this tier's sensor *logic*. The extension target's `LiveSensorFeed` does
/// nothing but talk to HealthKit, CoreLocation and CoreMotion and hand the numbers here, which
/// is what makes AC-FR-K-1-2 checkable with `swift test` — the seam under test is this type,
/// not a `CLLocationManager` that needs a wrist to say anything.
///
/// A deliberate duplicate of the Modern tier's pipeline (AC-FR-K-1-4). It composes, and does
/// not reimplement, the two pieces of state it needs: `DistanceFusion` for source priority and
/// monotonicity, `GPSAvailabilityTracker` for how long a fix drought must last before the
/// pedometer takes over (DEG-1).
///
/// ## Series 3 and grade adjustment
///
/// Series 3 *does* carry the barometric altimeter (it arrived with Series 3 itself), so grade
/// adjustment is genuinely in scope for this tier and must not silently no-op — T-063 calls
/// this out explicitly. The altimeter is therefore treated exactly as on Modern: forwarded
/// outdoors, suppressed indoors. The one Series 3 hardware gap that *does* matter is the
/// always-on display, which is a presentation concern and appears nowhere in this file.
public struct SensorPipeline: Sendable {

    private var fusion = DistanceFusion()
    private var gps: GPSAvailabilityTracker
    private let activity: RunActivityKind

    public init(activity: RunActivityKind, gpsTimeoutSeconds: TimeInterval = 10) {
        self.activity = activity
        self.gps = GPSAvailabilityTracker(timeoutSeconds: gpsTimeoutSeconds)
    }

    /// The most recently selected distance source, for the degraded-run indicator.
    public private(set) var activeSource: DistanceSource = .location

    public mutating func makeInput(from tick: RawSensorTick) -> EngineInput {
        gps.record(timestamp: tick.timestamp, isUsableFix: tick.isLocationFixUsable)

        // Indoors, CoreLocation is not merely unavailable — it must be *excluded*. A treadmill
        // run near a window picks up a wandering fix reporting real metres the runner never
        // covered, and it would outrank the pedometer on priority (design.md §8.2). DEG-10 is
        // the requirement; this line is where it bites.
        let locationUsable = activity == .outdoorRun && gps.isAvailable

        let fused = fusion.fuse(
            healthKit: reading(.healthKit, tick.healthKitDistance, available: true),
            location: reading(.location, tick.locationDistance, available: locationUsable),
            pedometer: reading(.pedometer, tick.pedometerDistance, available: true)
        )
        activeSource = fused.activeSource

        return SensorInputBuilder.build(
            timestamp: tick.timestamp,
            // Indoors the route is meaningless and the altimeter is disabled, so no location
            // sample is forwarded at all. RunEngine reads "pedometer source with no location"
            // as the indoor signal (DEG-10); a stray fix would defeat that detection.
            location: activity == .outdoorRun ? tick.location : nil,
            relativeAltitude: activity == .outdoorRun ? tick.relativeAltitude : nil,
            heartRate: tick.heartRate,
            isPaused: tick.isPaused,
            manualAdvanceRequested: tick.manualAdvanceRequested,
            fusedDistance: fused
        )
    }

    public mutating func reset() {
        fusion.reset()
        gps.reset()
        activeSource = .location
    }

    /// A missing reading becomes an explicitly unavailable one rather than being dropped, so
    /// the fusion layer distinguishes "silent" from "stationary".
    private func reading(
        _ source: DistanceSource,
        _ distance: Double?,
        available: Bool
    ) -> DistanceReading {
        DistanceReading(
            source: source,
            cumulativeDistance: distance ?? 0,
            isAvailable: available && distance != nil
        )
    }
}
