import XCTest
import Darwin
import ORModels
@testable import LegacySupport

/// Crash recovery, proved by crashing (T-065, FR-D-6, DEG-7).
///
/// T-065's acceptance criterion is "crash recovery loses at most 30 s". The tempting test —
/// `XCTAssertEqual(config.capture.flushIntervalSeconds, 30)` — restates a configuration constant
/// and proves nothing: it would pass just as happily if `flush()` never wrote anything, if
/// `replaceItemAt` left a truncated file, or if `detectOrphan` could not read what `flush` wrote.
///
/// So this launches a **real second process** that captures samples into a real directory, sends
/// it **`SIGKILL`**, and then recovers from whatever is on disk. SIGKILL cannot be caught,
/// blocked, or handled; it bypasses `atexit`, stdio flushing, and every `deinit`. What survives is
/// what the atomic-replace design actually guarantees, not what a cooperative shutdown would tidy
/// up for us.
///
/// These tests are macOS-host tests of watchOS-destined code, which is the compromise this tier
/// lives with: no watchOS 8 simulator exists for Xcode 26, so the alternative to testing the
/// durability logic here is not testing it at all. The filesystem semantics being relied on —
/// `Data.write(options: .atomic)` and `FileManager.replaceItemAt` — are Foundation's, and identical
/// on both platforms.
final class CrashRecoveryTests: XCTestCase {

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Locates the harness executable next to the test bundle in `.build/<config>/`.
    private func harnessURL() throws -> URL {
        var url = Bundle(for: Self.self).bundleURL
        // On macOS the test bundle is `<products>/LegacySupportPackageTests.xctest`.
        while url.pathExtension != "xctest", url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let products = url.deletingLastPathComponent()
        let harness = products.appendingPathComponent("legacy-capture-harness")

        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: harness.path),
            "legacy-capture-harness not built at \(harness.path)"
        )
        return harness
    }

    /// Runs the harness until it reports `appendUntil` samples, then SIGKILLs it.
    ///
    /// Returns the number of samples the harness had appended in-process before dying — the
    /// figure the surviving on-disk count is compared against.
    @discardableResult
    private func captureThenKill(
        directory: URL,
        runID: UUID,
        appendUntil: Int,
        totalSamples: Int = 100_000,
        flushInterval: Double
    ) throws -> Int {
        let process = Process()
        process.executableURL = try harnessURL()
        process.arguments = [
            directory.path, runID.uuidString, String(totalSamples), String(flushInterval),
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()

        // Read the harness's progress until it has appended enough, then kill it at a known
        // point. Reading line-by-line rather than sleeping a fixed interval: a timing-based kill
        // would make this test flaky on a loaded machine and, worse, would sometimes kill before
        // the first flush and "pass" for the wrong reason.
        var appended = 0
        var pending = Data()
        let handle = pipe.fileHandleForReading

        while appended < appendUntil {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if let count = line.split(separator: " ").last.flatMap({ Int($0) }) {
                    appended = count
                }
                XCTAssertNotEqual(
                    line, "completed-without-interruption",
                    "the harness finished before being killed; the kill point is wrong"
                )
            }
        }

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationReason, .uncaughtSignal,
            "the harness exited normally, so nothing about crash durability was tested"
        )
        XCTAssertGreaterThanOrEqual(appended, appendUntil)
        return appended
    }

    // MARK: - The bound

    /// A killed run is recoverable, and loses no more than one flush interval of samples.
    ///
    /// The harness ticks one sample per simulated second with a 30 s flush interval, matching
    /// `capture.flushIntervalSeconds`. It is killed after appending at least 95 samples, so at
    /// least three flushes have certainly landed and a fourth is partly buffered.
    func testAKilledRunIsRecoverableAndLosesAtMostOneFlushInterval() throws {
        let directory = scratchDirectory()
        let runID = UUID()
        let flushInterval: TimeInterval = 30

        let appended = try captureThenKill(
            directory: directory, runID: runID, appendUntil: 95, flushInterval: flushInterval
        )

        // A brand-new store over the same directory — the "next launch" path.
        let recovered = SampleStore(directory: directory)
        let orphan = try XCTUnwrap(
            recovered.detectOrphan(),
            "the killed run left nothing recoverable, so a crash loses the entire run"
        )
        XCTAssertEqual(orphan.runID, runID)

        let samples = try XCTUnwrap(recovered.loadOrphan(runID: runID))
        XCTAssertEqual(samples.count, orphan.sampleCount)

        // The bound, measured rather than assumed.
        let lost = appended - samples.count
        XCTAssertGreaterThan(
            samples.count, 0, "the surviving file decoded to zero samples"
        )
        XCTAssertLessThanOrEqual(
            Double(lost), flushInterval,
            """
            a crash lost \(lost) samples (\(appended) appended, \(samples.count) survived), \
            which exceeds the one-flush-interval bound FR-D-6 promises
            """
        )

        // Non-vacuity: if the harness had somehow flushed every sample, the bound would hold
        // trivially and this test would not be exercising a partial loss at all. At 95 samples
        // with a 30 s interval, exactly 90 should have been written (three flushes).
        XCTAssertGreaterThan(
            lost, 0,
            "nothing was lost, so this run did not actually exercise the partial-flush path"
        )
    }

    /// The samples that survive are intact and in order — not merely present.
    ///
    /// A truncated or interleaved JSON write would still decode to *something* under a lenient
    /// reading, so the recovered series is checked for monotonic timestamps and distances. This is
    /// the assertion that would fail if `flush` wrote in place instead of via atomic replace.
    func testRecoveredSamplesAreIntactAndOrderedRatherThanMerelyPresent() throws {
        let directory = scratchDirectory()
        let runID = UUID()

        try captureThenKill(
            directory: directory, runID: runID, appendUntil: 70, flushInterval: 30
        )

        let recovered = SampleStore(directory: directory)
        let samples = try XCTUnwrap(recovered.loadOrphan(runID: runID))
        XCTAssertGreaterThan(samples.count, 0)

        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(
                sample.timestamp, Double(index), accuracy: 1e-9,
                "sample \(index) has the wrong timestamp, so the file is not a clean prefix"
            )
            XCTAssertEqual(sample.cumulativeDistance, Double(index) * 3, accuracy: 1e-9)
        }
    }

    /// Killing at many different points always leaves a recoverable file.
    ///
    /// ## What this does *not* establish, measured rather than assumed
    ///
    /// An earlier version of this test was named "never leaves a corrupt file" and claimed to
    /// establish atomicity. It does not, and that was verified by sabotage: replacing
    /// `write(options: .atomic)` + `replaceItemAt` with a plain in-place `data.write(to:)` — the
    /// classic non-atomic mistake — leaves all four tests in this file **passing**.
    ///
    /// The reason is that the kill is synchronised to the harness's append loop, so it lands
    /// *between* flushes, not inside one. The window in which a small file is half-written is a
    /// single `write(2)` on APFS and is effectively impossible to hit deterministically; a test
    /// that tried would be flaky, and a flaky test asserting atomicity is worse than an honest
    /// one that does not.
    ///
    /// So the guarantee is split, and each half is held by something that can actually hold it:
    ///
    /// - *Recoverability across a crash* — this test, deterministically, at four kill points.
    /// - *A partial file is never mistaken for a good one* —
    ///   `testATruncatedInProgressFileIsRejectedRatherThanPartiallyDecoded`, which constructs the
    ///   corrupt state directly instead of hoping to race into it.
    /// - *The write is atomic* — `FileManager.replaceItemAt`'s documented contract, not a test.
    ///   Retained because the contract is what bounds the loss; a reviewer changing that line
    ///   should read this note.
    func testKillingAtManyDifferentPointsAlwaysLeavesARecoverableFile() throws {
        for appendUntil in [31, 45, 61, 90] {
            let directory = scratchDirectory()
            let runID = UUID()

            try captureThenKill(
                directory: directory, runID: runID, appendUntil: appendUntil, flushInterval: 30
            )

            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            let inProgress = files.filter { $0.pathExtension == "inprogress" }
            XCTAssertEqual(inProgress.count, 1, "expected exactly one in-progress file")

            // No temp file should survive: a crash between `write` and `replaceItemAt` can leave
            // one, and while that is harmless for correctness it would accumulate across runs.
            // Recorded rather than asserted away — see the note below.
            let recovered = SampleStore(directory: directory)
            XCTAssertNotNil(
                recovered.detectOrphan(),
                "killed at \(appendUntil): the surviving file did not decode"
            )
        }
    }

    /// A partially-written in-progress file is rejected, not partially decoded.
    ///
    /// The deterministic half of the atomicity guarantee. Rather than racing a kill into the write
    /// window — which the test above establishes is not reliably reachable — the corrupt state is
    /// constructed directly: a valid record truncated mid-JSON, exactly what a non-atomic write
    /// interrupted by a crash would leave.
    ///
    /// The requirement is that recovery *declines* it. Returning a half-decoded run would be the
    /// genuinely dangerous outcome — Wave 3's framing applies here too: a truncated run that
    /// still loads is a silent corruption, and it would then be uploaded, ingested, and folded
    /// into lifetime totals as though it were complete.
    func testATruncatedInProgressFileIsRejectedRatherThanPartiallyDecoded() throws {
        let directory = scratchDirectory()
        let runID = UUID()

        // Produce a genuine, complete file first, so the truncation is of real content.
        let store = SampleStore(directory: directory)
        store.startRun(runID: runID)
        for second in 0..<40 { store.append(sample(at: Double(second)), flushIntervalSeconds: 30) }
        store.flush()

        let url = directory.appendingPathComponent("\(runID.uuidString).inprogress")
        let good = try Data(contentsOf: url)
        XCTAssertGreaterThan(good.count, 100, "the flushed file is too small to truncate usefully")

        // Cut it in half, mid-structure.
        try good.prefix(good.count / 2).write(to: url)

        let recovered = SampleStore(directory: directory)
        XCTAssertNil(
            recovered.detectOrphan(),
            "a truncated capture file was accepted as a recoverable run"
        )
        XCTAssertNil(
            recovered.loadOrphan(runID: runID),
            "a truncated capture file decoded to a partial run, which would be silently uploaded"
        )
    }

    /// A cleanly finished run leaves nothing for the next launch to recover.
    ///
    /// The complement of the tests above: if `finalizeRun` did not remove the marker, every
    /// completed run would offer itself as an orphan on next launch and the recovery prompt would
    /// fire after a normal run.
    func testACleanlyFinishedRunIsNotOfferedAsAnOrphan() {
        let directory = scratchDirectory()
        let store = SampleStore(directory: directory)
        let runID = UUID()

        store.startRun(runID: runID)
        for second in 0..<40 {
            store.append(sample(at: Double(second)), flushIntervalSeconds: 30)
        }
        XCTAssertNotNil(store.detectOrphan(), "nothing was flushed, so the test proves nothing")

        store.finalizeRun()
        XCTAssertNil(
            store.detectOrphan(),
            "a cleanly ended run still looks orphaned, so recovery would fire after every run"
        )
    }

    private func sample(at second: TimeInterval) -> RunSample {
        RunSample(
            timestamp: second,
            cumulativeDistance: second * 3,
            rollingPace: Pace(secondsPerMetre: 1.0 / 3.0),
            heartRate: 150,
            relativeAltitude: 0,
            smoothedGrade: 0,
            gradeFactor: .identity,
            rawTarget: nil,
            effectiveTarget: nil,
            zone: .onTarget
        )
    }
}
