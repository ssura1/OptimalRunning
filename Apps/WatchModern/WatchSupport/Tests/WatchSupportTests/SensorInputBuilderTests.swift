import XCTest
import ORModels
@testable import WatchSupport

final class SensorInputBuilderTests: XCTestCase {

    func testBuildsWithFullData() {
        let location = RawLocationReading(
            timestamp: 10, latitude: 51.5, longitude: -0.1, altitudeMetres: 42,
            horizontalAccuracy: 5, verticalAccuracy: 3
        )
        let input = SensorInputBuilder.build(
            timestamp: 10,
            location: location,
            relativeAltitude: 12,
            heartRate: 150,
            isPaused: false,
            manualAdvanceRequested: false,
            fusedDistance: FusedDistance(cumulativeDistance: 1000, activeSource: .healthKit)
        )

        XCTAssertEqual(input.timestamp, 10)
        XCTAssertEqual(input.cumulativeDistance, 1000)
        XCTAssertEqual(input.relativeAltitude, 12)
        XCTAssertEqual(input.heartRate, 150)
        XCTAssertEqual(input.distanceSource, .healthKit)
        XCTAssertNotNil(input.location)
        XCTAssertEqual(input.location?.latitude, 51.5)
        XCTAssertEqual(input.location?.horizontalAccuracy, 5)
    }

    func testOmitsLocationWhenNoFixIsPresent() {
        let input = SensorInputBuilder.build(
            timestamp: 10,
            location: nil,
            relativeAltitude: nil,
            heartRate: nil,
            isPaused: false,
            manualAdvanceRequested: false,
            fusedDistance: FusedDistance(cumulativeDistance: 500, activeSource: .pedometer)
        )
        XCTAssertNil(input.location)
        XCTAssertNil(input.relativeAltitude)
        XCTAssertNil(input.heartRate)
        XCTAssertEqual(input.distanceSource, .pedometer)
    }

    func testPropagatesPauseAndManualAdvanceFlags() {
        let input = SensorInputBuilder.build(
            timestamp: 5, location: nil, relativeAltitude: nil, heartRate: nil,
            isPaused: true, manualAdvanceRequested: true,
            fusedDistance: FusedDistance(cumulativeDistance: 0, activeSource: .location)
        )
        XCTAssertTrue(input.isPaused)
        XCTAssertTrue(input.manualAdvanceRequested)
    }
}
