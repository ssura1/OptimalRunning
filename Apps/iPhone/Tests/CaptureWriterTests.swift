import PhoneMotion
import XCTest

@testable import OptimalRunner

/// S-006 — the capture writer, which had no tests at all until a field session produced
/// five consecutive **zero-byte** captures (S-056).
///
/// The tool this exercises is the only source of ground truth the standalone track can
/// ever have (CON-S-1), which makes "it is only a developer tool" precisely the wrong
/// reason to leave it unverified: a bug here is not a bug in a feature, it is the silent
/// loss of a run that cannot be re-recorded without going outside again.
///
/// These tests deliberately assert on **bytes on disk**, not on a return value. The
/// failure being chased wrote nothing while reporting nothing, so any assertion that
/// could pass without the file growing would reproduce the original blind spot.
final class CaptureWriterTests: XCTestCase {

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    private func track(_ writer: CaptureWriter) {
        written.append(writer.workingURL)
    }

    private func sample(at t: TimeInterval) -> MotionSample {
        MotionSample(
            timestamp: t,
            userAcceleration: Vector3(x: 0.1, y: -0.2, z: 9.7),
            gravity: Vector3(x: 0, y: 0, z: -9.80665),
            rotationRate: Vector3(x: 0.01, y: 0.02, z: 0.03))
    }

    /// Via `FileManager`, deliberately, and not `URL.resourceValues`.
    ///
    /// `URL` caches resource values behind its `NSURL`, so reading the size before an
    /// append and again afterwards returns the *first* answer both times — which reads
    /// exactly like the product failing to write. Measured this way the same call reports
    /// what is actually on disk.
    private func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? -1
    }

    // MARK: - The thing that actually failed in the field

    /// A single appended sample must reach the filesystem.
    ///
    /// `FileHandle.write` is an unbuffered `write(2)`, so the file grows on the first
    /// record whether or not a flush has happened. A zero-byte file after an append
    /// therefore means the record never reached the handle at all — which is exactly what
    /// five field captures showed.
    func testAppendingOneSampleGrowsTheFileImmediately() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        XCTAssertEqual(size(of: writer.workingURL), 0, "precondition: a new capture is empty")

        writer.append(motion: sample(at: 0))

        XCTAssertGreaterThan(
            size(of: writer.workingURL), 0,
            "one appended sample wrote nothing to disk — this is the field failure")
    }

    func testEverySampleIsWrittenAndNoneAreDropped() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        for i in 0..<250 { writer.append(motion: sample(at: Double(i) / 100)) }

        let lines = try String(contentsOf: writer.workingURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 250, "records were silently dropped")
    }

    /// The encode step must not be able to fail quietly.
    ///
    /// The original `write` was `guard let data = try? encode(...) else { return }`, which
    /// turns any encoding failure into a zero-byte capture with no error anywhere — which
    /// is indistinguishable, from the outside, from a sensor that delivered nothing.
    /// `JSONEncoder` rejects non-finite doubles by default, and a sensor stream is a
    /// realistic place for one to appear.
    func testNonFiniteSampleIsReportedRatherThanSilentlyDropped() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        writer.append(motion: MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(x: .nan, y: 0, z: 0),
            gravity: Vector3(x: 0, y: 0, z: -9.80665)))

        XCTAssertEqual(size(of: writer.workingURL), 0, "precondition: nothing encodable")
        XCTAssertNotNil(
            writer.lastFailure,
            "a record that cannot be encoded must surface, not vanish")
    }

    /// A bad record must not take the rest of the capture down with it.
    func testAGoodSampleStillWritesAfterABadOne() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        writer.append(motion: MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(x: .infinity, y: 0, z: 0),
            gravity: .zero))
        writer.append(motion: sample(at: 0.01))

        let lines = try String(contentsOf: writer.workingURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "the capture stopped at the first bad record")
    }

    // MARK: - Durability

    func testMarksAreOnDiskImmediately() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        writer.append(mark: MotionTrace.Mark(timestamp: 1.5, index: 1, note: "mile 1"))

        // Read through a separate handle: this asserts the bytes are visible outside the
        // writer's own file descriptor, which is the property a crash actually needs.
        let contents = try String(contentsOf: writer.workingURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("mile 1"), "a mark was not durable when written")
    }

    func testAssemblyRecoversATruncatedStream() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        for i in 0..<10 { writer.append(motion: sample(at: Double(i) / 100)) }
        writer.append(mark: MotionTrace.Mark(timestamp: 0.05, index: 1, note: nil))

        // Simulate a kill mid-write by appending a partial line.
        let handle = try FileHandle(forWritingTo: writer.workingURL)
        try handle.seekToEnd()
        handle.write(Data(#"{"kind":"m","payl"#.utf8))
        try handle.close()

        let trace = try CaptureWriter.assemble(from: writer.workingURL, header: header())
        XCTAssertEqual(trace.motion.count, 10, "complete records were lost")
        XCTAssertEqual(trace.marks.count, 1, "the mark did not survive truncation")
    }

    func testFinishProducesAnAssembledTraceAndKeepsTheRawStream() throws {
        let writer = try CaptureWriter(startedAt: Date())
        track(writer)
        for i in 0..<20 { writer.append(motion: sample(at: Double(i) / 100)) }

        try writer.finish(header: header())

        let assembled = CaptureWriter.directory
            .appendingPathComponent("capture-under-test.motion.json")
        written.append(assembled)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: assembled.path),
            "finish produced no assembled trace")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: writer.workingURL.path),
            "the raw stream must be kept — it is the only copy of an unrepeatable run")
    }

    private func header() -> MotionTrace.Header {
        MotionTrace.Header(
            name: "capture-under-test",
            describes: "unit test",
            recordedAt: Date(),
            deviceModel: "test",
            systemVersion: "test",
            appVersion: "test",
            nominalSampleRateHz: 100,
            carryPosition: .handHeld,
            runnerHeightMetres: 1.78,
            references: [])
    }
}
