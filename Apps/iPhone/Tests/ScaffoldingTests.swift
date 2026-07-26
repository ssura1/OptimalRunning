import XCTest
import ORModels
import ORStats
import PhoneSupport
import SwiftData
@testable import OptimalRunner

/// The iOS-side test target.
///
/// **Why this exists, given `swift test` covers `PhoneSupport`.** The package suite runs on the
/// macOS host: fast, simulator-free, and proving behaviour on the wrong platform. This target runs
/// the same logic compiled for **iOS**, which is where storage behaviour can genuinely differ —
/// and one of the measurements behind T-053's design (Core Data's ~128 KiB externalisation
/// threshold) was taken on macOS. If iOS drew that line elsewhere, the claim that long runs' blobs
/// stay out of the store file would be wrong on the only platform that ships. Wave 2 learned this
/// the expensive way, when `volumeAvailableCapacityForImportantUsageKey` compiled on macOS and did
/// not exist on watchOS.
///
/// Deliberately a thin platform suite rather than a duplicate of the 94-test package suite.
final class ScaffoldingTests: XCTestCase {

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeRecord(blobBytes: Int) -> RunRecord {
        RunRecord(
            runID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_400),
            runTypeRaw: RunType.tempo.rawValue,
            deviceTierRaw: DeviceTier.modern.rawValue,
            distanceMetres: 8_000,
            activeSeconds: 2_400,
            averagePaceSecondsPerMetre: 0.3,
            averageHeartRate: 150,
            maxHeartRate: 175,
            elevationGainMetres: 40,
            timeInZoneSeconds: Array(repeating: 400, count: PaceZone.allCases.count),
            packedSamples: Data(repeating: 0x5A, count: blobBytes)
        )
    }

    func testCoreAndPhoneSupportLinkOnIOS() throws {
        XCTAssertEqual(RunType.allCases.count, 5)
        XCTAssertEqual(PaceZone.allCases.count, 6)
        XCTAssertNoThrow(try RunStoreContainer.inMemory())
    }

    /// The externalisation threshold, re-measured on iOS.
    ///
    /// The macOS measurement put it between 128 and 160 KiB. If iOS differs, T-053's design note is
    /// wrong where it matters, and this fails rather than the docs quietly becoming fiction.
    func testTheExternalisationThresholdMatchesTheMacOSMeasurement() throws {
        let directory = scratchDirectory()

        func externalFileCount(blobBytes: Int) throws -> Int {
            let storeURL = directory.appendingPathComponent("threshold-\(blobBytes).store")
            let container = try RunStoreContainer.make(url: storeURL)
            let context = ModelContext(container)
            context.insert(makeRecord(blobBytes: blobBytes))
            try context.save()

            guard let walker = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return 0 }

            var count = 0
            for case let url as URL in walker {
                guard url.path.contains("_EXTERNAL_DATA"),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                count += 1
            }
            return count
        }

        XCTAssertEqual(
            try externalFileCount(blobBytes: 64 * 1024), 0,
            "on iOS a 64 KB blob was externalised; the threshold differs from the macOS measurement"
        )
        XCTAssertGreaterThan(
            try externalFileCount(blobBytes: 200 * 1024), 0,
            "on iOS a 200 KB blob was stored inline; .externalStorage is doing nothing here"
        )
    }

    /// The full pipeline — envelope, compress, ingest, store, analyse — compiled for iOS.
    ///
    /// The codec is the part most likely to differ by platform, since it goes through the
    /// `Compression` framework.
    func testAFixtureRoundTripsThroughTheWholePipelineOnIOS() throws {
        let context = ModelContext(try RunStoreContainer.inMemory())
        let library = RunLibrary(context: context)

        let envelope = try Self.makeTempoEnvelope()
        let payload = try SyncPayloadCodec.encode(envelope)

        XCTAssertTrue(library.ingest(payload: payload).isAccepted, "iOS refused a valid payload")
        XCTAssertEqual(try library.runs.count(), 1)

        let record = try XCTUnwrap(try library.runs.record(for: envelope.runID))
        XCTAssertEqual(record.distanceMetres, envelope.summary.distanceMetres, accuracy: 1e-6)

        let analysis = try RunAnalysis(record: record)
        XCTAssertTrue(analysis.hasSamples)
        XCTAssertEqual(
            analysis.zoneShares().reduce(0) { $0 + $1.percentage }, 100, accuracy: 0.1
        )
        XCTAssertFalse(analysis.splits(unit: .miles).isEmpty)
    }

    /// Re-delivery stays idempotent on iOS, which is the property the whole sync design rests on.
    func testIdempotentIngestHoldsOnIOS() throws {
        let context = ModelContext(try RunStoreContainer.inMemory())
        let library = RunLibrary(context: context)
        let payload = try SyncPayloadCodec.encode(Self.makeTempoEnvelope())

        library.ingest(payload: payload)
        library.ingest(payload: payload)

        XCTAssertEqual(try library.runs.count(), 1)
        XCTAssertEqual(try library.aggregates.cache().lifetime.runCount, 1)
    }

    // MARK: - Fixture

    /// A small synthetic run.
    ///
    /// Deliberately *not* one of the seven recorded fixtures: those are replayed exhaustively by
    /// the package suite, and reaching them here would mean the app target depending on `ORPace`'s
    /// fixture generator purely for a smoke test. What this target checks is that the platform
    /// behaves, not that the engine is right.
    private static func makeTempoEnvelope() throws -> RunEnvelope {
        let samples = (0..<600).map { index in
            RunSample(
                timestamp: Double(index),
                cumulativeDistance: Double(index) * 3.2,
                rollingPace: Pace(secondsPerMetre: 0.3125),
                heartRate: 150,
                relativeAltitude: 0,
                smoothedGrade: 0,
                gradeFactor: .identity,
                rawTarget: Pace(minutesPerMile: 8),
                effectiveTarget: Pace(minutesPerMile: 8),
                zone: .onTarget
            )
        }
        let timeline = ZoneTimeline.encode(zones: samples.map(\.zone))

        return RunEnvelope(
            runID: UUID(),
            deviceTier: .modern,
            appVersion: "1.0-test",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            runType: .tempo,
            plan: nil,
            profileSnapshot: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
            configSnapshot: .default,
            healthKitWorkoutUUID: nil,
            summary: RunSummaryBuilder.build(
                samples: samples, activeSeconds: 599, zoneTimeline: timeline
            ),
            steps: [],
            zoneTimeline: timeline,
            samples: PackedSamples(samples: samples),
            route: nil,
            degradations: []
        )
    }
}
