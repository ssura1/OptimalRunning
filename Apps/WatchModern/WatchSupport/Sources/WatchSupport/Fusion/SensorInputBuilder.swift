import Foundation
import ORModels

/// A location fix reduced to primitives, so this file never needs to import
/// CoreLocation. The app-target adapter does the `CLLocation` → this conversion.
public struct RawLocationReading: Sendable, Hashable {
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let altitudeMetres: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double

    public init(
        timestamp: TimeInterval,
        latitude: Double,
        longitude: Double,
        altitudeMetres: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMetres = altitudeMetres
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }
}

/// Builds one `EngineInput` per tick from raw sensor readings (T-036).
///
/// This is the seam the tier-equivalence test (AC-FR-K-1-2) actually depends on:
/// both watch tiers must produce the same `EngineInput` shape from equivalent raw
/// readings, or `RunEngine`'s output — provably identical given identical input —
/// stops being a guarantee about identical *behaviour*. Keeping this pure and
/// framework-free is what lets it be asserted directly, without a simulator.
public enum SensorInputBuilder {

    public static func build(
        timestamp: TimeInterval,
        location: RawLocationReading?,
        relativeAltitude: Double?,
        heartRate: Double?,
        isPaused: Bool,
        manualAdvanceRequested: Bool,
        fusedDistance: FusedDistance
    ) -> EngineInput {
        let locationSample = location.map {
            LocationSample(
                timestamp: $0.timestamp,
                latitude: $0.latitude,
                longitude: $0.longitude,
                altitudeMetres: $0.altitudeMetres,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: $0.verticalAccuracy
            )
        }

        return EngineInput(
            timestamp: timestamp,
            cumulativeDistance: fusedDistance.cumulativeDistance,
            location: locationSample,
            relativeAltitude: relativeAltitude,
            heartRate: heartRate,
            isPaused: isPaused,
            manualAdvanceRequested: manualAdvanceRequested,
            distanceSource: fusedDistance.activeSource
        )
    }
}
