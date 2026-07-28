import PhoneMotion
import XCTest

@testable import OptimalRunner

/// S-056 — the serial capture destination.
///
/// The failure these guard against is not a wrong number, it is a lost run: three sensor
/// streams arrive on three different queues, and `CaptureWriter` has mutable state and no
/// lock of its own. If the sink ever stopped serialising them the corruption would appear
/// only under load, on a device, during a run that cannot be repeated.
final class CaptureSinkTests: XCTestCase {

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    private func sample(at t: TimeInterval) -> MotionSample {
        MotionSample(
            timestamp: t,
            userAcceleration: Vector3(x: 0.1, y: -0.2, z: 9.7),
            gravity: Vector3(x: 0, y: 0, z: -9.80665))
    }

    /// Concurrent producers must not lose or interleave records.
    ///
    /// Driven from several queues at once because that is the real shape of the problem —
    /// motion at 100 Hz, location at ~1 Hz and the pedometer all deliver on their own
    /// queues, and a single-threaded test would prove nothing about the case that matters.
    func testConcurrentStreamsProduceOneWellFormedRecordPerAppend() throws {
        let sink = CaptureSink()
        let url = try sink.begin(startedAt: Date())
        written.append(url)

        let motionCount = 600
        let locationCount = 40
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            for i in 0..<motionCount { sink.append(motion: self.sample(at: Double(i) / 100)) }
        }
        DispatchQueue.global().async(group: group) {
            for i in 0..<locationCount {
                sink.append(location: MotionTrace.RecordedFix(
                    timestamp: Double(i),
                    latitude: 51.5, longitude: -0.1,
                    altitudeMetres: 10,
                    horizontalAccuracy: 5, verticalAccuracy: 5,
                    speedMetresPerSecond: 3.2,
                    cumulativeDistanceMetres: Double(i) * 3.2))
            }
        }
        group.wait()

        // `snapshot` is synchronous on the sink's queue, so it cannot return before every
        // append enqueued above has run.
        let counts = sink.snapshot()
        XCTAssertEqual(counts.motion, motionCount)
        XCTAssertEqual(counts.location, locationCount)
        XCTAssertNil(counts.failure)

        // Every line must be independently decodable: interleaved writes would corrupt the
        // stream without changing the counts.
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, motionCount + locationCount, "records were lost")
        for line in lines {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                "a record was interleaved with another and is not valid JSON")
        }
    }

    /// A mark must be on disk by the time the button's action returns.
    func testMarkIsDurableBeforeItReturns() throws {
        let sink = CaptureSink()
        let url = try sink.begin(startedAt: Date())
        written.append(url)

        // Queue a backlog first: an asynchronous mark would land behind all of it.
        for i in 0..<500 { sink.append(motion: sample(at: Double(i) / 100)) }
        sink.append(mark: MotionTrace.Mark(timestamp: 5, index: 1, note: "mile 1"))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("mile 1"),
            "the mark had not reached disk when the call returned")
    }

    /// Abandoning keeps the raw stream — it is the only copy of an unrepeatable run.
    func testAbandonKeepsWhateverWasWritten() throws {
        let sink = CaptureSink()
        let url = try sink.begin(startedAt: Date())
        written.append(url)
        for i in 0..<10 { sink.append(motion: sample(at: Double(i) / 100)) }
        _ = sink.snapshot()

        sink.abandon()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 10, "an abandoned capture lost records it had written")
    }
}
