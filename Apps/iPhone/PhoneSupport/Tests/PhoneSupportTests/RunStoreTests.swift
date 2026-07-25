import XCTest
import ORModels
import SwiftData
@testable import PhoneSupport

/// T-053 — the store's schema, external blob storage, and the list query's cost.
final class RunStoreTests: XCTestCase {

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A record with a blob of a given size, without going through the envelope path.
    private func makeRecord(
        runID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        blobBytes: Int,
        distance: Double = 8_000,
        runType: RunType = .tempo
    ) -> RunRecord {
        RunRecord(
            runID: runID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2_400),
            runTypeRaw: runType.rawValue,
            deviceTierRaw: DeviceTier.modern.rawValue,
            distanceMetres: distance,
            activeSeconds: 2_400,
            averagePaceSecondsPerMetre: 0.3,
            averageHeartRate: 150,
            maxHeartRate: 175,
            elevationGainMetres: 40,
            timeInZoneSeconds: Array(repeating: 400, count: PaceZone.allCases.count),
            packedSamples: Data(repeating: 0x5A, count: blobBytes)
        )
    }

    // MARK: - External storage, verified on disk

    /// T-053's Done-when, taken literally: the blobs must be **out of the main store file**,
    /// checked by looking at the files rather than by trusting the attribute.
    ///
    /// The attribute is only a hint to Core Data, and whether it takes effect depends on blob
    /// size and configuration. Asserting "the app didn't crash" would prove nothing at all,
    /// and asserting the attribute is *present* would only prove the source compiles. So this
    /// measures: a store holding 20 MB of sample blobs whose own file stays small has
    /// necessarily put them somewhere else, and that somewhere is found and measured.
    func testSampleBlobsLiveOutsideTheMainStoreFile() throws {
        let directory = scratchDirectory()
        let storeURL = directory.appendingPathComponent("runs.store")

        // Blobs comfortably above any inline threshold — a real 90-minute run is ~100 KB
        // packed, so 200 KB each is realistic rather than contrived.
        let blobBytes = 200 * 1024
        let runCount = 20
        let expectedBlobTotal = blobBytes * runCount

        do {
            let container = try RunStoreContainer.make(url: storeURL)
            let context = ModelContext(container)
            for index in 0..<runCount {
                context.insert(makeRecord(
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                    blobBytes: blobBytes
                ))
            }
            try context.save()
        }

        let storeFileSize = try fileSize(storeURL)
        let externalTotal = externalStorageBytes(near: storeURL)

        // The blobs exist somewhere.
        XCTAssertGreaterThan(
            externalTotal, Int(Double(expectedBlobTotal) * 0.5),
            "expected roughly \(expectedBlobTotal) bytes of external blob data, found \(externalTotal)"
        )

        // And that somewhere is not the store file.
        XCTAssertLessThan(
            storeFileSize, expectedBlobTotal / 4,
            "the main store file is \(storeFileSize) bytes against \(expectedBlobTotal) bytes of "
                + "blobs — the blobs are being written inline, so .externalStorage is not taking effect"
        )
    }

    /// The blobs still read back correctly from external storage — external means relocated,
    /// not lossy.
    func testBlobsRoundTripThroughExternalStorage() throws {
        let directory = scratchDirectory()
        let storeURL = directory.appendingPathComponent("runs.store")
        let runID = UUID()
        let blob = Data((0..<(300 * 1024)).map { UInt8($0 % 251) })

        do {
            let container = try RunStoreContainer.make(url: storeURL)
            let context = ModelContext(container)
            let record = makeRecord(runID: runID, blobBytes: 0)
            record.packedSamples = blob
            context.insert(record)
            try context.save()
        }

        let container = try RunStoreContainer.make(url: storeURL)
        let reopened = try XCTUnwrap(
            try RunRepository(context: ModelContext(container)).record(for: runID)
        )
        XCTAssertEqual(reopened.packedSamples, blob, "the external blob came back changed")
    }

    // MARK: - The list query's cost

    /// Core Data externalises a blob only above ~128 KiB, and real runs straddle that line.
    ///
    /// Measured, not assumed: the threshold sits between 128 KiB and 160 KiB (131 072 bytes,
    /// Core Data's documented value), and a JSON-encoded `PackedSamples` reaches it at roughly
    /// 4 900 samples — about 82 minutes at 1 Hz. So a 40-minute run (64 KB encoded) is stored
    /// **inline** and a 90-minute run (144 KB encoded) is stored **externally**.
    ///
    /// This is pinned as a test because design.md §9.3 asserts `.externalStorage` is what keeps
    /// blobs out of the store file, and that is only true for the long runs. If a future change
    /// shrinks the encoding — compressing the blob, say — every run falls inline and the
    /// attribute stops doing anything, which is worth failing a test over rather than
    /// discovering from a docs claim that quietly stopped being true.
    func testTheExternalisationThresholdIsWhereTheDocsAssumeItIs() throws {
        let directory = scratchDirectory()

        func externalFileCount(blobBytes: Int) throws -> Int {
            let storeURL = directory
                .appendingPathComponent("threshold-\(blobBytes).store")
            let container = try RunStoreContainer.make(url: storeURL)
            let context = ModelContext(container)
            context.insert(makeRecord(blobBytes: blobBytes))
            try context.save()
            return countExternalBlobFiles(near: storeURL)
        }

        XCTAssertEqual(
            try externalFileCount(blobBytes: 64 * 1024), 0,
            "a 64 KB blob — a ~40-minute run — was externalised; the threshold has moved"
        )
        XCTAssertEqual(
            try externalFileCount(blobBytes: 200 * 1024), 1,
            "a 200 KB blob — a ~2-hour run — was stored inline; .externalStorage is doing nothing"
        )
    }

    /// 1 000 runs, and the list fetch must not read their sample blobs (AC-FR-F-1-3, NFR-5).
    ///
    /// **Proved by deleting the blobs, not by timing.** The first version of this test compared
    /// the list fetch against a blob-reading fetch and asserted the list was faster. It failed,
    /// reporting the list fetch as 8× *slower* — because whichever fetch ran first paid the
    /// cold-cache cost of opening the store. It was measuring filesystem cache warmth, not blob
    /// paging, and would have passed or failed essentially at random.
    ///
    /// The assertion is structural instead: every external blob file is deleted, and the list
    /// fetch must still return all 1 000 rows with correct values. It cannot have read data that
    /// no longer exists. The final assertion is what stops that being vacuous — reading
    /// `packedSamples` afterwards must come back `nil`, proving the deleted files really were
    /// where the blobs lived.
    ///
    /// Blobs are sized at 160 KB so they land above the externalisation threshold. That is not
    /// a convenience: it is the case where paging blobs would actually hurt, since a store of
    /// long runs is where a list screen could otherwise read hundreds of megabytes. For the
    /// shorter runs that stay inline the guarantee comes from never touching the property
    /// rather than from externalisation — which is `RunListItem` being a value type, so a
    /// caller cannot fault a blob in by accident.
    func testAThousandRunListFetchDoesNotReadSampleBlobs() throws {
        let directory = scratchDirectory()
        let storeURL = directory.appendingPathComponent("runs.store")

        let blobBytes = 160 * 1024
        let runCount = 1_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let container = try RunStoreContainer.make(url: storeURL)
            let context = ModelContext(container)
            for index in 0..<runCount {
                context.insert(makeRecord(
                    startedAt: base.addingTimeInterval(Double(index) * 3_600),
                    blobBytes: blobBytes,
                    distance: 8_000 + Double(index),
                    runType: RunType.allCases[index % RunType.allCases.count]
                ))
                if index % 100 == 0 { try context.save() }
            }
            try context.save()
        }

        let removed = deleteExternalBlobFiles(near: storeURL)
        XCTAssertEqual(
            removed, runCount,
            "expected one external blob file per run; found \(removed). If the blobs are inline "
                + "this test cannot prove anything about paging."
        )

        // The list fetch, against a store whose blobs no longer exist on disk.
        let listContainer = try RunStoreContainer.make(url: storeURL)
        let items = try RunRepository(context: ModelContext(listContainer)).listItems()

        XCTAssertEqual(
            items.count, runCount,
            "the list fetch could not complete without the sample blobs, so it reads them"
        )
        XCTAssertEqual(items, items.sorted { $0.startedAt > $1.startedAt }, "not newest-first")

        // Every projected value is intact — not merely the right number of rows.
        let newest = try XCTUnwrap(items.first)
        XCTAssertEqual(newest.startedAt, base.addingTimeInterval(Double(runCount - 1) * 3_600))
        XCTAssertEqual(newest.distanceMetres, 8_000 + Double(runCount - 1), accuracy: 1e-9)
        XCTAssertEqual(newest.averageHeartRate, 150)
        XCTAssertFalse(newest.isDegraded)

        // The counterpart: those files really were the blob storage.
        let blobContext = ModelContext(try RunStoreContainer.make(url: storeURL))
        let records = try blobContext.fetch(FetchDescriptor<RunRecord>())
        XCTAssertEqual(records.count, runCount)
        XCTAssertNil(
            records.first?.packedSamples,
            "the sample blob survived deletion of the external files, so it was never external"
        )
    }

    // MARK: - Filters (AC-FR-F-1-4 / F-1-5)

    func testFiltersCombineRatherThanOverride() throws {
        let container = try RunStoreContainer.inMemory()
        let context = ModelContext(container)
        let repository = RunRepository(context: context)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Two tempo runs a week apart, one easy run in between.
        context.insert(makeRecord(startedAt: base, blobBytes: 128, runType: .tempo))
        context.insert(makeRecord(
            startedAt: base.addingTimeInterval(3 * 86_400), blobBytes: 128, runType: .easy
        ))
        context.insert(makeRecord(
            startedAt: base.addingTimeInterval(7 * 86_400), blobBytes: 128, runType: .tempo
        ))
        try context.save()

        XCTAssertEqual(try repository.listItems().count, 3)
        XCTAssertEqual(try repository.listItems(filter: .init(runTypes: [.tempo])).count, 2)

        // Type *and* date range together, not either alone.
        let combined = try repository.listItems(filter: .init(
            runTypes: [.tempo],
            from: base.addingTimeInterval(86_400),
            to: base.addingTimeInterval(10 * 86_400)
        ))
        XCTAssertEqual(combined.count, 1, "the two filters did not narrow together")
        XCTAssertEqual(combined.first?.startedAt, base.addingTimeInterval(7 * 86_400))
    }

    func testMultipleRunTypesFilterAsAUnion() throws {
        let container = try RunStoreContainer.inMemory()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for (index, type) in [RunType.tempo, .easy, .long, .interval].enumerated() {
            context.insert(makeRecord(
                startedAt: base.addingTimeInterval(Double(index) * 86_400),
                blobBytes: 128, runType: type
            ))
        }
        try context.save()

        let items = try RunRepository(context: context)
            .listItems(filter: .init(runTypes: [.tempo, .long]))
        XCTAssertEqual(Set(items.map(\.runType)), [.tempo, .long])
    }

    func testAnEmptyStoreReturnsNoItemsRatherThanFailing() throws {
        let container = try RunStoreContainer.inMemory()
        let repository = RunRepository(context: ModelContext(container))
        XCTAssertTrue(try repository.listItems().isEmpty)
        XCTAssertEqual(try repository.count(), 0)
    }

    // MARK: - Deletion

    func testDeletingARunCascadesToItsSteps() throws {
        let container = try RunStoreContainer.inMemory()
        let context = ModelContext(container)
        let repository = RunRepository(context: context)

        let built = try FixtureEnvelopes.build("intervals-4x1000")
        try repository.upsert(built.envelope)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StepRecord>()), 0)

        try repository.delete(runID: built.envelope.runID)

        XCTAssertEqual(try repository.count(), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StepRecord>()), 0,
            "deleting a run orphaned its step rows"
        )
    }

    // MARK: - Helpers

    /// Counts external binary-data files beside the store.
    private func countExternalBlobFiles(near storeURL: URL) -> Int {
        externalBlobFileURLs(near: storeURL).count
    }

    private func externalBlobFileURLs(near storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            guard url.path.contains("_EXTERNAL_DATA"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            found.append(url)
        }
        return found
    }

    /// Deletes every external binary-data file beside the store, returning how many went.
    ///
    /// Core Data tolerates this: a record whose external file is missing reports the attribute
    /// as `nil` rather than trapping, which is exactly what makes it usable as a probe.
    private func deleteExternalBlobFiles(near storeURL: URL) -> Int {
        var removed = 0
        for url in externalBlobFileURLs(near: storeURL) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Sums every file Core Data wrote alongside the store.
    ///
    /// External binary data lives in a sibling `.<name>_SUPPORT/_EXTERNAL_DATA` directory. The
    /// exact path is an implementation detail, so this walks everything next to the store and
    /// excludes the store's own files rather than hard-coding the layout — the assertion is
    /// about *where the bytes are not*, which stays true however Core Data names its folders.
    private func externalStorageBytes(near storeURL: URL) -> Int {
        let directory = storeURL.deletingLastPathComponent()
        let storeName = storeURL.lastPathComponent
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            // Skip the store and its journal/WAL siblings; everything else is external data.
            if url.lastPathComponent.hasPrefix(storeName) { continue }
            total += size
        }
        return total
    }
}
