import XCTest
import ORModels
@testable import WatchSupport

final class SampleStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func sample(at t: TimeInterval) -> RunSample {
        RunSample(
            timestamp: t, cumulativeDistance: t * 3, rollingPace: nil, heartRate: 150,
            relativeAltitude: 0, smoothedGrade: 0, gradeFactor: PaceRatio.identity,
            rawTarget: nil, effectiveTarget: nil, zone: .onTarget
        )
    }

    func testFlushWritesRecoverableData() {
        let store = SampleStore(directory: tempDirectory)
        let runID = UUID()
        store.startRun(runID: runID)
        for t in 0..<5 { store.append(sample(at: Double(t)), flushIntervalSeconds: 1000) }
        store.flush()

        let orphan = store.detectOrphan()
        XCTAssertEqual(orphan?.runID, runID)
        XCTAssertEqual(orphan?.sampleCount, 5)
    }

    func testFlushesAutomaticallyOnceTheIntervalElapses() {
        let store = SampleStore(directory: tempDirectory)
        store.startRun(runID: UUID())

        store.append(sample(at: 0), flushIntervalSeconds: 30)
        XCTAssertNil(store.detectOrphan(), "must not flush before the interval elapses")

        for t in 1..<30 { store.append(sample(at: Double(t)), flushIntervalSeconds: 30) }
        XCTAssertNil(store.detectOrphan(), "29 s in, still under the 30 s interval")

        store.append(sample(at: 30), flushIntervalSeconds: 30)
        XCTAssertNotNil(store.detectOrphan(), "30 s in, the interval has elapsed")
    }

    /// The T-038 Done-when scenario, stated directly: simulate a crash by never
    /// calling `finalizeRun()`, and confirm at most 30 s of samples were lost.
    func testSimulatedCrashLosesAtMostTheFlushInterval() {
        let store = SampleStore(directory: tempDirectory)
        let runID = UUID()
        store.startRun(runID: runID)

        // 100 samples, flushing every 30.
        for t in 0..<100 { store.append(sample(at: Double(t)), flushIntervalSeconds: 30) }
        // No finalizeRun() — this is the crash.

        let orphan = store.detectOrphan()
        XCTAssertNotNil(orphan)
        // The last flush happens at or after t=90 (three full 30 s intervals from
        // t=0), so at most the trailing ~10 samples (< 30 s) are missing.
        XCTAssertGreaterThanOrEqual(orphan!.sampleCount, 70, "lost more than 30 s of samples")
    }

    func testLoadOrphanReturnsTheFlushedSamples() {
        let store = SampleStore(directory: tempDirectory)
        let runID = UUID()
        store.startRun(runID: runID)
        for t in 0..<10 { store.append(sample(at: Double(t)), flushIntervalSeconds: 1000) }
        store.flush()

        let loaded = store.loadOrphan(runID: runID)
        XCTAssertEqual(loaded?.count, 10)
        XCTAssertEqual(loaded?.first?.timestamp, 0)
        XCTAssertEqual(loaded?.last?.timestamp, 9)
    }

    func testDiscardOrphanRemovesIt() {
        let store = SampleStore(directory: tempDirectory)
        let runID = UUID()
        store.startRun(runID: runID)
        store.append(sample(at: 0), flushIntervalSeconds: 1000)
        store.flush()
        XCTAssertNotNil(store.detectOrphan())

        store.discardOrphan(runID: runID)
        XCTAssertNil(store.detectOrphan())
    }

    func testFinalizeRunRemovesTheInProgressMarkerSoItIsNotTreatedAsOrphaned() {
        let store = SampleStore(directory: tempDirectory)
        let runID = UUID()
        store.startRun(runID: runID)
        store.append(sample(at: 0), flushIntervalSeconds: 1000)

        store.finalizeRun()

        // A fresh store instance, as a new launch would create, must not see an
        // orphan from a run that ended cleanly.
        let freshStore = SampleStore(directory: tempDirectory)
        XCTAssertNil(freshStore.detectOrphan())
    }

    func testNoOrphanWhenNothingWasEverStarted() {
        let store = SampleStore(directory: tempDirectory)
        XCTAssertNil(store.detectOrphan())
    }

    func testHasSufficientStorageForATinyThresholdIsTrue() {
        let store = SampleStore(directory: tempDirectory)
        XCTAssertTrue(store.hasSufficientStorage(minimumBytes: 1))
    }

    func testHasSufficientStorageForAnAbsurdThresholdIsFalse() {
        let store = SampleStore(directory: tempDirectory)
        XCTAssertFalse(store.hasSufficientStorage(minimumBytes: Int64.max))
    }

    func testBufferedSampleCountTracksAppends() {
        let store = SampleStore(directory: tempDirectory)
        store.startRun(runID: UUID())
        XCTAssertEqual(store.bufferedSampleCount, 0)
        store.append(sample(at: 0), flushIntervalSeconds: 1000)
        store.append(sample(at: 1), flushIntervalSeconds: 1000)
        XCTAssertEqual(store.bufferedSampleCount, 2)
    }

    func testStartingANewRunClearsThePreviousBuffer() {
        let store = SampleStore(directory: tempDirectory)
        store.startRun(runID: UUID())
        store.append(sample(at: 0), flushIntervalSeconds: 1000)
        store.append(sample(at: 1), flushIntervalSeconds: 1000)

        store.startRun(runID: UUID())
        XCTAssertEqual(store.bufferedSampleCount, 0)
    }
}
