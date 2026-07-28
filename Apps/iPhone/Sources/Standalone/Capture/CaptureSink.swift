import Foundation
import PhoneMotion

/// The single serial destination every captured record passes through (S-056).
///
/// **Why this type exists.** The first implementation had each of the three sensor
/// callbacks hop to the main actor and write there:
///
/// ```swift
/// Task { @MainActor in
///     self?.writer?.append(motion: sample)
///     self?.motionSampleCount += 1
/// }
/// ```
///
/// At 100 Hz that is a hundred main-actor hops a second, each performing a JSON encode and
/// a `write(2)`, and each mutating an `@Published` property — so SwiftUI rebuilt the whole
/// capture screen on every frame it could manage. The screen became unresponsive, which is
/// what a runner sees as "it went black and I could not press MARK", and an app whose main
/// thread is wedged when the system asks it to suspend is an app the watchdog terminates.
///
/// Capture work does not belong on the main thread at all. It belongs on one serial queue,
/// which is also what `CaptureWriter` needs to be safe without a lock of its own — the
/// three sensor streams arrive on three different queues, so *something* has to serialise
/// them, and doing it here means the writer stays a plain synchronous class that a test can
/// drive without draining anybody's queue.
///
/// Counters live here too, for the same reason: they are read twice a second by the display
/// timer instead of being published a hundred times a second by the sensor.
final class CaptureSink: @unchecked Sendable {

    /// A consistent view of the capture, taken under the queue.
    struct Counts: Sendable {
        var motion = 0
        var location = 0
        var pedometer = 0
        /// The first write failure, if there was one. Surfaced so a capture can never again
        /// produce an empty file and no explanation.
        var failure: String?
    }

    private let queue = DispatchQueue(
        label: "com.optimalrunner.standalone.capture", qos: .userInitiated)

    /// Touched only on `queue`.
    private var writer: CaptureWriter?
    private var counts = Counts()

    // MARK: - Lifecycle

    /// Opens a capture file, or throws if it cannot be created.
    ///
    /// Synchronous on purpose: a capture that failed to open must fail *before* the sensors
    /// are started, not asynchronously afterwards while samples are already arriving.
    func begin(startedAt: Date) throws -> URL {
        try queue.sync {
            let writer = try CaptureWriter(startedAt: startedAt)
            self.writer = writer
            counts = Counts()
            return writer.workingURL
        }
    }

    func finish(header: MotionTrace.Header) throws {
        try queue.sync {
            try writer?.finish(header: header)
            writer = nil
        }
    }

    /// Drops the capture without assembling a trace.
    ///
    /// The `.ndjson` is left on disk deliberately — it is a complete record of everything
    /// that was written, and after an unexpected teardown it is the only copy of a run that
    /// cannot be repeated without going outside again.
    func abandon() {
        queue.sync { writer = nil }
    }

    // MARK: - Appending

    func append(motion sample: MotionSample) {
        queue.async {
            self.writer?.append(motion: sample)
            self.counts.motion += 1
            self.noteFailure()
        }
    }

    func append(location fix: MotionTrace.RecordedFix) {
        queue.async {
            self.writer?.append(location: fix)
            self.counts.location += 1
            self.noteFailure()
        }
    }

    func append(pedometer reading: MotionTrace.RecordedPedometerReading) {
        queue.async {
            self.writer?.append(pedometer: reading)
            self.counts.pedometer += 1
            self.noteFailure()
        }
    }

    /// Marks are written synchronously.
    ///
    /// A mark is the one record the runner cannot supply twice, so it is on disk before the
    /// button's action returns rather than queued behind whatever samples are pending.
    func append(mark: MotionTrace.Mark) {
        queue.sync {
            writer?.append(mark: mark)
            noteFailure()
        }
    }

    // MARK: - Reading

    func snapshot() -> Counts {
        queue.sync { counts }
    }

    private func noteFailure() {
        if counts.failure == nil, let failure = writer?.lastFailure {
            counts.failure = failure
        }
    }
}
