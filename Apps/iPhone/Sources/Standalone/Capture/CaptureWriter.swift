import Foundation
import PhoneMotion

/// Writes a capture incrementally, so a crash costs seconds rather than the session
/// (AC-FR-S-F-1-6).
///
/// **Append-only newline-delimited records while recording, columnar `MotionTrace` at the
/// end.** The two formats exist for different jobs and neither can do the other's:
///
/// - A 60-minute capture at 100 Hz is 360 000 samples. Re-encoding a growing columnar
///   document every 30 s would be quadratic and would stall the capture — on the one
///   device where stalling loses data that cannot be re-recorded without going for
///   another run.
/// - Newline-delimited records survive truncation by construction: a file killed
///   mid-write loses its last line, and every line before it is still valid. There is no
///   header to be missing and no length prefix to disagree with reality.
///
/// So the run-time format is the durable one and the committed format is the analysable
/// one, with the conversion at `finish` — which is also the only place that needs the
/// header the trace cannot know until the session is over.
/// ## Thread confinement
///
/// Every instance method here is **confined to its owner's serial capture queue** and must
/// never be called from two queues at once. That is what makes the `@unchecked Sendable`
/// below honest rather than a silencer: the type has mutable state and no internal lock,
/// and it is safe only because `MotionCaptureRecorder` funnels motion, location, pedometer
/// and mark records onto one serial queue before they arrive.
///
/// The alternative — an internal queue inside the writer — was rejected because it makes
/// `append` asynchronous, and a test that appends and then reads the file would have to
/// drain a queue it does not own to assert anything. Keeping the writer synchronous is
/// what lets `CaptureWriterTests` assert on bytes without a single expectation.
final class CaptureWriter: @unchecked Sendable {

    let workingURL: URL
    private let handle: FileHandle
    private var pendingBytes = 0
    private var lastFlush = Date()

    /// One encoder for the life of the capture rather than one per record.
    ///
    /// At 100 Hz the previous code built and tore down a `JSONEncoder` a hundred times a
    /// second for the entire run.
    private let encoder = JSONEncoder()

    /// Why the last record could not be written, if one could not be.
    ///
    /// This exists because its absence made a field failure undiagnosable: `write` used to
    /// be `guard let data = try? encoder.encode(record) else { return }`, so an encoding
    /// failure produced a zero-byte capture, no error, and no way to tell that apart from
    /// "the sensor delivered nothing". JSONEncoder rejects non-finite doubles by default,
    /// which is a realistic thing for a sensor stream to contain, so this was not a
    /// theoretical hole. Set once and kept: the first failure is the informative one.
    private(set) var lastFailure: String?

    /// Flush at least this often. FR-D-6's 30 s bound, applied to capture.
    private static let flushInterval: TimeInterval = 5
    private static let flushByteThreshold = 64 * 1024

    // MARK: - Directory

    /// Captures live in Documents so the Files app and the share sheet can reach them
    /// without a debugger (AC-FR-S-F-1-7). Retrieval that needs Xcode is retrieval that
    /// does not happen on a Sunday morning after a long run.
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("MotionCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func existingCaptures() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents
            .filter { $0.lastPathComponent.hasSuffix(".motion.json")
                || $0.lastPathComponent.hasSuffix(".ndjson") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
    }

    // MARK: - Lifecycle

    init(startedAt: Date) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        workingURL = Self.directory
            .appendingPathComponent("capture-\(formatter.string(from: startedAt)).ndjson")
        FileManager.default.createFile(atPath: workingURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: workingURL)
    }

    // MARK: - Appending

    private enum Record: Encodable {
        case motion(MotionSample)
        case location(MotionTrace.RecordedFix)
        case pedometer(MotionTrace.RecordedPedometerReading)
        case mark(MotionTrace.Mark)

        enum CodingKeys: String, CodingKey { case kind, payload }

        /// Names the stream a record came from, so a write failure can say which one.
        var kind: String {
            switch self {
            case .motion: "motion"
            case .location: "location"
            case .pedometer: "pedometer"
            case .mark: "mark"
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .motion(value):
                try container.encode("m", forKey: .kind)
                try container.encode(value, forKey: .payload)
            case let .location(value):
                try container.encode("l", forKey: .kind)
                try container.encode(value, forKey: .payload)
            case let .pedometer(value):
                try container.encode("p", forKey: .kind)
                try container.encode(value, forKey: .payload)
            case let .mark(value):
                try container.encode("k", forKey: .kind)
                try container.encode(value, forKey: .payload)
            }
        }
    }

    private struct DecodedRecord: Decodable {
        let kind: String
        let motion: MotionSample?
        let location: MotionTrace.RecordedFix?
        let pedometer: MotionTrace.RecordedPedometerReading?
        let mark: MotionTrace.Mark?

        enum CodingKeys: String, CodingKey { case kind, payload }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            motion = kind == "m"
                ? try container.decode(MotionSample.self, forKey: .payload) : nil
            location = kind == "l"
                ? try container.decode(MotionTrace.RecordedFix.self, forKey: .payload) : nil
            pedometer = kind == "p"
                ? try container.decode(
                    MotionTrace.RecordedPedometerReading.self, forKey: .payload) : nil
            mark = kind == "k"
                ? try container.decode(MotionTrace.Mark.self, forKey: .payload) : nil
        }
    }

    func append(motion sample: MotionSample) { write(.motion(sample)) }
    func append(location fix: MotionTrace.RecordedFix) { write(.location(fix)) }
    func append(pedometer reading: MotionTrace.RecordedPedometerReading) {
        write(.pedometer(reading))
    }
    func append(mark: MotionTrace.Mark) {
        write(.mark(mark))
        // A mark is the runner telling us something they cannot tell us twice, so it is
        // flushed immediately rather than waiting for the interval.
        flush()
    }

    private func write(_ record: Record) {
        var data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            // Recorded rather than swallowed. A capture that writes nothing must say why.
            if lastFailure == nil {
                lastFailure = "could not encode a \(record.kind) record: \(error)"
            }
            return
        }
        data.append(0x0A)
        handle.write(data)
        pendingBytes += data.count
        if pendingBytes >= Self.flushByteThreshold
            || Date().timeIntervalSince(lastFlush) >= Self.flushInterval
        {
            flush()
        }
    }

    private func flush() {
        try? handle.synchronize()
        pendingBytes = 0
        lastFlush = Date()
    }

    // MARK: - Finishing

    /// Converts the durable stream into the analysable trace.
    func finish(header: MotionTrace.Header) throws {
        flush()
        try handle.close()
        let trace = try Self.assemble(from: workingURL, header: header)
        let finalURL = Self.directory
            .appendingPathComponent("\(header.name).motion.json")
        try trace.encoded().write(to: finalURL, options: .atomic)
        // The working file is kept, not deleted. If assembly ever produces something
        // wrong, the raw stream is the only copy of a run that cannot be repeated.
    }

    /// Rebuilds a trace from a record stream — including a truncated one.
    ///
    /// Also the recovery path for a capture whose app was killed: the `.ndjson` is still
    /// on disk, and everything up to the last complete line is intact.
    static func assemble(from url: URL, header: MotionTrace.Header) throws -> MotionTrace {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var samples: [MotionSample] = []
        var fixes: [MotionTrace.RecordedFix] = []
        var pedometer: [MotionTrace.RecordedPedometerReading] = []
        var marks: [MotionTrace.Mark] = []

        let decoder = JSONDecoder()
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            // A partial final line is expected after a kill and is skipped rather than
            // failing the whole assembly. This is the entire reason for the format.
            guard let record = try? decoder.decode(DecodedRecord.self, from: data) else {
                continue
            }
            if let value = record.motion { samples.append(value) }
            if let value = record.location { fixes.append(value) }
            if let value = record.pedometer { pedometer.append(value) }
            if let value = record.mark { marks.append(value) }
        }

        // Motion timestamps come from CoreMotion's own uptime clock; location and mark
        // timestamps are already relative. Rebasing motion onto the same origin here is
        // what puts every stream on one timeline, which the replay depends on.
        if let first = samples.first?.timestamp, first != 0 {
            samples = samples.map {
                MotionSample(
                    timestamp: $0.timestamp - first,
                    userAcceleration: $0.userAcceleration,
                    gravity: $0.gravity,
                    rotationRate: $0.rotationRate)
            }
        }

        return MotionTrace(
            header: header,
            motion: MotionTrace.MotionColumns(samples: samples),
            locations: fixes,
            pedometer: pedometer,
            marks: marks)
    }
}
