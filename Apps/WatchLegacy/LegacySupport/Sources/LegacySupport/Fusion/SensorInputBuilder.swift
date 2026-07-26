import Foundation
import ORModels

/// A location fix reduced to primitives, so this file never imports CoreLocation. The
/// extension-target adapter does the `CLLocation` → this conversion.
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

/// Builds one `EngineInput` per tick from raw sensor readings — Legacy tier (T-063).
///
/// This is the seam AC-FR-K-1-2 actually rests on. `RunEngine`'s output is provably identical
/// given identical input, so tier equivalence reduces entirely to: *do both tiers construct the
/// same `EngineInput` from equivalent raw readings?* Everything downstream of this function is
/// Core, shared, and already tested; everything upstream is a framework call that no test can
/// reach without hardware. So this is the last point at which the two tiers can diverge in a
/// way a test can catch — which is why it is a pure function over primitives, in a package
/// `swift test` can run on the host with no simulator at all.
///
/// A deliberate duplicate of the Modern tier's builder (AC-FR-K-1-4), field order included.
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
