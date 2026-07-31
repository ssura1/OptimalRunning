import Foundation
import ORIntervals
import ORModels
import ORPace
import SwiftData
import XCTest

@testable import PhoneSupport

/// Exporting a recorded run (S-067).
///
/// Two obligations pull against each other here and both are tested, because satisfying
/// either alone produces something worthless. An export that carries no absolute position
/// is trivial to write — emit nothing — and an export that preserves everything is trivial
/// too, and is the mistake this repository has already made once. So: **the origin must be
/// gone, and the shape must survive.**
///
/// The privacy half is asserted against the serialised bytes rather than against the model,
/// because the model is where a future field could be added without anyone noticing that it
/// happens to carry a coordinate.
final class RunExportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try RunStoreContainer.inMemory())
    }

    /// Somewhere specific, so a leak would be visible as a literal in the output.
    private static let originLatitude = 42.361_145
    private static let originLongitude = -71.057_083

    /// A closed loop with movement on both axes — a straight north-south line would pass a
    /// longitude test by accident.
    private static func route(pointCount: Int = 60) -> [RoutePoint] {
        (0..<pointCount).map { index in
            let angle = Double(index) / Double(pointCount) * 2 * .pi
            return RoutePoint(
                timestamp: Double(index) * 5,
                latitude: originLatitude + 0.002 * sin(angle),
                longitude: originLongitude + 0.003 * (1 - cos(angle)),
                altitudeMetres: 10 + 5 * sin(angle))
        }
    }

    private func exported(
        _ built: FixtureEnvelopes.Built, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (data: Data, json: [String: Any]) {
        let context = try makeContext()
        let record = try RunRepository(context: context).upsert(built.envelope)
        let analysis = try RunAnalysis(record: record)
        let data = try RunExport.data(for: analysis, appVersion: "1.0-test")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return (data, json)
    }

    // MARK: - The origin is gone

    func testNoExportedFieldCarriesAnAbsoluteCoordinate() throws {
        let built = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling", route: Self.route())
        let (data, json) = try exported(built)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        for forbidden in ["latitude", "longitude", "\"lat\"", "\"lon\""] {
            XCTAssertFalse(
                text.contains(forbidden),
                "the export must not carry a key named \(forbidden)")
        }

        // The key check, and the one that survives a field being renamed: the digits
        // themselves must not appear anywhere. Three decimal places is about 100 m, which
        // already names a neighbourhood.
        //
        // Truncated rather than rounded. `String(format: "%.5f", 42.361145)` is "42.36115",
        // which does not occur in "42.361145" — so a rounding check silently skips whichever
        // precisions happen to round up, and would report a pass over a real leak. Found by
        // planting one.
        for places in 3...6 {
            XCTAssertFalse(
                text.contains(Self.truncated(Self.originLatitude, places: places)),
                "leaked latitude to \(places) places")
            XCTAssertFalse(
                text.contains(Self.truncated(abs(Self.originLongitude), places: places)),
                "leaked longitude to \(places) places")
        }

        let route = try XCTUnwrap(json["route"] as? [[String: Any]])
        let first = try XCTUnwrap(route.first)
        XCTAssertEqual(first["eastMetres"] as? Double, 0)
        XCTAssertEqual(first["northMetres"] as? Double, 0)
        XCTAssertEqual(
            first["t"] as? Double, 0,
            "timestamps are relative to the run's own first fix too — an absolute one dates "
                + "the run to the second")
    }

    /// Altitude is kept. It is not a position: it says the run climbed 17 m, which is what
    /// makes a grade-adjusted pace checkable, and it locates nobody.
    func testAltitudeSurvivesBecauseItIsNotAPosition() throws {
        let built = try FixtureEnvelopes.standalone(
            "hilly-10k", route: Self.route())
        let (_, json) = try exported(built)

        let route = try XCTUnwrap(json["route"] as? [[String: Any]])
        let altitudes = route.compactMap { $0["altitudeMetres"] as? Double }
        XCTAssertEqual(altitudes.count, route.count)
        XCTAssertGreaterThan(
            try XCTUnwrap(altitudes.max()) - XCTUnwrap(altitudes.min()), 1,
            "the altitude profile must still vary, or the elevation column is useless")
    }

    // MARK: - The shape survives

    /// The counterweight. A scrubbed route that no longer describes the run is safe and
    /// worthless; this is what makes the export worth taking.
    func testTheTrackKeepsItsLengthAndItsShape() throws {
        let original = Self.route()
        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling", route: original)
        let (_, json) = try exported(built)

        let route = try XCTUnwrap(json["route"] as? [[String: Any]])
        XCTAssertEqual(route.count, original.count)

        let exportedLength = zip(route, route.dropFirst()).reduce(0.0) { total, pair in
            let (a, b) = pair
            let dx = (b["eastMetres"] as? Double ?? 0) - (a["eastMetres"] as? Double ?? 0)
            let dy = (b["northMetres"] as? Double ?? 0) - (a["northMetres"] as? Double ?? 0)
            return total + (dx * dx + dy * dy).squareRoot()
        }
        let trueLength = zip(original, original.dropFirst()).reduce(0.0) {
            $0 + Self.haversine($1.0, $1.1)
        }

        XCTAssertGreaterThan(trueLength, 100, "the fixture route must be worth measuring")
        XCTAssertEqual(
            exportedLength, trueLength, accuracy: trueLength * 0.01,
            """
            The exported track must be the same length as the run, within the flat-earth \
            approximation the scrubber uses. If this drifts, an analysis done on an export \
            no longer describes the run it came from.
            """)
    }

    // MARK: - What an investigation needs

    func testAPhoneRunExportsTheEvidenceThatExplainsItsDistance() throws {
        let built = try FixtureEnvelopes.standalone(
            "gps-dropout-tunnel",
            telemetry: .partlyEstimated,
            route: Self.route(),
            estimatedSpans: [.init(startSeconds: 120, endSeconds: 300)])
        let (_, json) = try exported(built)

        let standalone = try XCTUnwrap(
            json["standalone"] as? [String: Any],
            "a phone run without its motion facts is a distance with no explanation")
        XCTAssertEqual(standalone["carryPosition"] as? String, "handHeld")
        XCTAssertGreaterThan(try XCTUnwrap(standalone["estimatedMetres"] as? Double), 0)
        XCTAssertNotNil(standalone["measuredFraction"] as? Double)
        XCTAssertNotNil(standalone["calibrationObservations"] as? Int)
        XCTAssertGreaterThan(try XCTUnwrap(standalone["stepCount"] as? Int), 0)

        let spans = try XCTUnwrap(standalone["estimatedSpans"] as? [[Double]])
        XCTAssertEqual(
            spans, [[120, 300]],
            "which stretches were estimated is the first question asked of a distance that "
                + "looks wrong")
    }

    /// Runs recorded before the exporter existed, and runs from the other tier, go through
    /// the same path — the export is built from the store, not from anything captured at
    /// the time of the run.
    func testAWatchRunExportsWithoutStandaloneFacts() throws {
        let built = try FixtureEnvelopes.build("tempo-5mi-rolling", route: Self.route())
        let (_, json) = try exported(built)

        XCTAssertNil(
            json["standalone"],
            "a watch run has no carry position, and inventing one would be a fabrication")
        XCTAssertEqual(json["deviceTier"] as? String, DeviceTier.modern.rawValue)
        XCTAssertFalse(try XCTUnwrap(json["samples"] as? [[String: Any]]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(json["route"] as? [[String: Any]]).isEmpty)
    }

    func testSamplesCarryPaceTargetAndZoneInStableUnits() throws {
        let built = try FixtureEnvelopes.standalone("tempo-5mi-rolling")
        let (_, json) = try exported(built)

        let samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
        XCTAssertGreaterThan(samples.count, 100)

        let judged = samples.filter { ($0["zone"] as? String) != "neutral" }
        XCTAssertFalse(judged.isEmpty, "a tempo run against a target must judge something")

        let withPace = try XCTUnwrap(samples.first { $0["paceSecondsPerKilometre"] != nil })
        let pace = try XCTUnwrap(withPace["paceSecondsPerKilometre"] as? Double)
        XCTAssertTrue(
            (120...900).contains(pace),
            "seconds per kilometre regardless of the runner's unit preference — a number "
                + "whose unit depends on a setting elsewhere in the file gets read wrong")
    }

    func testTheFilenameSortsChronologicallyAndSaysWhatItIs() throws {
        let context = try makeContext()
        let built = try FixtureEnvelopes.standalone(
            "tempo-5mi-rolling",
            startedAt: Date(timeIntervalSince1970: 1_784_000_000))
        let record = try RunRepository(context: context).upsert(built.envelope)

        let name = RunExport.filename(for: try RunAnalysis(record: record))
        XCTAssertTrue(name.hasPrefix("run-2026-07-"), "got \(name)")
        XCTAssertTrue(name.hasSuffix("-tempo.json"), "got \(name)")
    }

    // MARK: - Helpers

    /// "42.361145" at 4 places is "42.3611" — the leading digits as they would actually be
    /// written, never rounded up into a string the file does not contain.
    private static func truncated(_ value: Double, places: Int) -> String {
        let full = String(format: "%.9f", value)
        guard let dot = full.firstIndex(of: ".") else { return full }
        let end = full.index(dot, offsetBy: places + 1)
        return String(full[full.startIndex..<end])
    }

    private static func haversine(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let earthRadius = 6_371_008.8
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}
