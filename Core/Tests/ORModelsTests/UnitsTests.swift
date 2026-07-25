import XCTest
@testable import ORModels

/// T-007 — units and pace primitives (AC-FR-A-1-4, ADR-003).
final class UnitsTests: XCTestCase {

    // MARK: The load-bearing convention

    /// The single most important assertion in the package.
    ///
    /// Every band, drift, and grade factor in the product is a percentage *of pace*.
    /// If this convention ever silently becomes a percentage of speed, nothing crashes
    /// — the app just mis-classifies every runner by a few percent, in a direction
    /// that varies with pace. That is why it is asserted exactly, not approximately.
    func testPercentagesAreDefinedOnPaceNotSpeed() {
        XCTAssertEqual(PaceRatio(percentSlower: 12.5).value, 1.125, "12.5% slower must be exactly 1.125")

        let eight = Pace(secondsPerMile: 480)
        let nine = Pace(secondsPerMile: 540)

        XCTAssertEqual(nine.ratio(to: eight).value, 1.125, accuracy: 1e-12)
        XCTAssertEqual(nine.percentSlower(than: eight), 12.5, accuracy: 1e-9)

        // And the inverse direction is *not* -12.5% — that asymmetry is exactly what
        // defining percentages on pace means.
        XCTAssertEqual(eight.percentSlower(than: nine), -11.111, accuracy: 1e-3)
    }

    func testScalingByRatioProducesTheExpectedPace() {
        let eight = Pace(minutesPerMile: 8)
        let scaled = eight.scaled(by: PaceRatio(percentSlower: 12.5))
        XCTAssertEqual(scaled.secondsPerMile, 540, accuracy: 1e-9)
        XCTAssertEqual(ORFormat.pace(scaled, in: .miles), "9:00")
    }

    // MARK: Conversions

    func testConversionsRoundTrip() {
        for minutes in stride(from: 4.0, through: 20.0, by: 0.25) {
            let pace = Pace(minutesPerMile: minutes)
            XCTAssertEqual(pace.minutesPerMile, minutes, accuracy: 1e-9)

            let metric = Pace(minutesPerKilometre: minutes)
            XCTAssertEqual(metric.minutesPerKilometre, minutes, accuracy: 1e-9)
        }
    }

    func testMileAndKilometreRelationship() {
        let pace = Pace(minutesPerMile: 8)
        // A mile is longer, so seconds-per-mile exceeds seconds-per-kilometre.
        XCTAssertEqual(pace.secondsPerMile / pace.secondsPerKilometre, 1.609344, accuracy: 1e-9)
    }

    func testSpeedConversion() {
        let pace = Pace(secondsPerKilometre: 300)   // 5:00/km
        XCTAssertEqual(pace.metresPerSecond, 1000.0 / 300.0, accuracy: 1e-12)
    }

    func testDistanceAndTimeInitializerRejectsDegenerateInput() {
        XCTAssertNil(Pace(distanceMetres: 0, seconds: 10))
        XCTAssertNil(Pace(distanceMetres: 100, seconds: 0))
        XCTAssertNil(Pace(distanceMetres: -5, seconds: 10))
        XCTAssertNil(Pace(distanceMetres: .nan, seconds: 10))
        XCTAssertNil(Pace(distanceMetres: 100, seconds: .infinity))
        XCTAssertNotNil(Pace(distanceMetres: 100, seconds: 30))
    }

    func testValidityRejectsNonFiniteAndNonPositive() {
        XCTAssertFalse(Pace(secondsPerMetre: 0).isValid)
        XCTAssertFalse(Pace(secondsPerMetre: -1).isValid)
        XCTAssertFalse(Pace(secondsPerMetre: .nan).isValid)
        XCTAssertFalse(Pace(secondsPerMetre: .infinity).isValid)
        XCTAssertTrue(Pace(minutesPerMile: 8).isValid)
    }

    // MARK: Ordering

    func testComparableOrdersBySlownessNotSpeed() {
        let fast = Pace(minutesPerMile: 6)
        let slow = Pace(minutesPerMile: 10)
        XCTAssertLessThan(fast, slow)
        XCTAssertTrue(fast.isFaster(than: slow))
        XCTAssertTrue(slow.isSlower(than: fast))
    }

    // MARK: Deltas

    func testSignedDeltaIsPositiveWhenSlower() {
        let target = Pace(secondsPerMile: 480)
        let actual = Pace(secondsPerMile: 495)
        XCTAssertEqual(actual.signedDelta(from: target, in: .miles), 15, accuracy: 1e-9)
        XCTAssertLessThan(target.signedDelta(from: actual, in: .miles), 0)
    }

    func testSignedDeltaRespectsUnitPreference() {
        let target = Pace(secondsPerKilometre: 300)
        let actual = Pace(secondsPerKilometre: 310)
        XCTAssertEqual(actual.signedDelta(from: target, in: .kilometres), 10, accuracy: 1e-9)
        XCTAssertEqual(
            actual.signedDelta(from: target, in: .miles),
            10 * 1.609344,
            accuracy: 1e-6
        )
    }

    // MARK: PaceRatio

    func testRatioComposition() {
        let a = PaceRatio(percentSlower: 10)
        let b = PaceRatio(percentSlower: 10)
        XCTAssertEqual(a.multiplied(by: b).value, 1.21, accuracy: 1e-12)
    }

    func testRatioClamping() {
        XCTAssertEqual(PaceRatio(value: 2.0).clamped(to: 0.9...1.3).value, 1.3)
        XCTAssertEqual(PaceRatio(value: 0.1).clamped(to: 0.9...1.3).value, 0.9)
        XCTAssertEqual(PaceRatio(value: 1.1).clamped(to: 0.9...1.3).value, 1.1)
    }

    func testRatioDirectionFlags() {
        XCTAssertTrue(PaceRatio(percentSlower: 5).isSlower)
        XCTAssertTrue(PaceRatio(percentSlower: -5).isFaster)
        XCTAssertFalse(PaceRatio.identity.isSlower)
        XCTAssertFalse(PaceRatio.identity.isFaster)
    }

    // MARK: Formatting

    func testDurationFormatting() {
        XCTAssertEqual(ORFormat.duration(0), "0:00")
        XCTAssertEqual(ORFormat.duration(59), "0:59")
        XCTAssertEqual(ORFormat.duration(60), "1:00")
        XCTAssertEqual(ORFormat.duration(605), "10:05")
        XCTAssertEqual(ORFormat.duration(3600), "1:00:00")
        XCTAssertEqual(ORFormat.duration(3725), "1:02:05")
        XCTAssertEqual(ORFormat.duration(-90), "-1:30")
        XCTAssertEqual(ORFormat.duration(.nan), "--")
    }

    func testPaceFormattingForBothUnits() {
        let pace = Pace(minutesPerMile: 8)
        XCTAssertEqual(ORFormat.pace(pace, in: .miles), "8:00")
        XCTAssertEqual(ORFormat.pace(pace, in: .kilometres), "4:58")
        XCTAssertEqual(ORFormat.pace(nil, in: .miles), "--")
        XCTAssertEqual(ORFormat.pace(Pace(secondsPerMetre: .nan), in: .miles), "--")
    }

    func testSignedSecondsAlwaysCarriesItsSign() {
        XCTAssertEqual(ORFormat.signedSeconds(12), "+12")
        XCTAssertEqual(ORFormat.signedSeconds(-8), "-8")
        XCTAssertEqual(ORFormat.signedSeconds(0), "+0")
        XCTAssertEqual(ORFormat.signedSeconds(.nan), "--")
    }

    func testDistanceFormattingRespectsUnits() {
        XCTAssertEqual(ORFormat.distance(1609.344, in: .miles), "1.00")
        XCTAssertEqual(ORFormat.distance(5000, in: .kilometres), "5.00")
        XCTAssertEqual(ORFormat.distance(5000, in: .kilometres, fractionDigits: 1), "5.0")
        XCTAssertEqual(ORFormat.distance(5000, in: .kilometres, fractionDigits: 0), "5")
        XCTAssertEqual(ORFormat.distance(.nan, in: .miles), "--")
    }

    func testUnitSymbols() {
        XCTAssertEqual(ORFormat.paceSymbol(.miles), "/mi")
        XCTAssertEqual(ORFormat.paceSymbol(.kilometres), "/km")
        XCTAssertEqual(UnitPreference.miles.metresPerUnit, 1609.344)
        XCTAssertEqual(UnitPreference.kilometres.metresPerUnit, 1000)
    }

    // MARK: Codable

    func testPaceAndRatioRoundTripThroughJSON() throws {
        let pace = Pace(minutesPerMile: 7.5)
        let decodedPace = try JSONDecoder().decode(Pace.self, from: JSONEncoder().encode(pace))
        XCTAssertEqual(decodedPace, pace)

        let ratio = PaceRatio(percentSlower: 3.25)
        let decodedRatio = try JSONDecoder().decode(PaceRatio.self, from: JSONEncoder().encode(ratio))
        XCTAssertEqual(decodedRatio, ratio)
    }
}
