import Foundation
import ORModels

/// Append-only, crash-durable capture of a run's samples — Legacy tier (T-065, FR-D-6).
///
/// Holds samples in memory and periodically writes the *entire* accumulated array to a single
/// file via atomic replace (temp file + rename). Atomic replace is what bounds loss to "since the
/// last flush" rather than "since the write started": a crash mid-write leaves the previous
/// flush's file intact, never a half-written one. That property is what
/// `CrashRecoveryTests` verifies by genuinely `SIGKILL`ing a process mid-capture.
///
/// A deliberate duplicate of the Modern tier's store (AC-FR-K-1-4). Real file I/O throughout —
/// `FileManager` and `Data` are plain Foundation, identical on every platform — which is what
/// makes it testable against a real temporary directory rather than a filesystem fake. On this
/// tier that matters more than on Modern: with no watchOS 8 simulator in existence, host-side
/// `swift test` is the only automated coverage this code will ever get.
///
/// ## Series 3 storage pressure
///
/// Series 3 shipped with 8 GB of storage, much of it consumed by the OS, and DEG-6's
/// insufficient-storage refusal is therefore a *realistic* path on this tier rather than a
/// defensive one. The threshold itself is unchanged (`capture.minimumFreeBytesToStart`, NFR-21)
/// because the sample format is identical; what differs is how often a Series 3 owner will
/// actually meet it.
public final class SampleStore: @unchecked Sendable {

    public struct OrphanedRun: Sendable {
        public let runID: UUID
        public let sampleCount: Int
        public let lastModified: Date
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    /// Free bytes on the store's volume, or `nil` when the volume cannot answer.
    ///
    /// Injectable because a full disk is not a state a test can create: the real query reports
    /// the machine's actual free space, so a test asserting a run is refused (DEG-6) would need
    /// the runner to genuinely run out of room. Faking the *measurement* keeps the decision under
    /// test.
    private let freeBytes: @Sendable (URL) -> Int64?

    private var runID: UUID?
    private var buffer: [RunSample] = []
    /// Timestamp the current flush interval is measured from — the last flush, or the run's first
    /// sample if nothing has been flushed yet. Optional rather than `-.infinity` on purpose: a
    /// sentinel "infinitely long ago" makes the very first append look permanently overdue, so
    /// every run flushes on its opening sample instead of on the documented 30 s cadence. That
    /// was a real Wave 2 bug on the Modern tier; it is not being reintroduced here.
    private var flushIntervalAnchor: TimeInterval?

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        freeBytes: @escaping @Sendable (URL) -> Int64? = SampleStore.volumeFreeBytes
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.freeBytes = freeBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The real measurement.
    ///
    /// `volumeAvailableCapacityKey`, not `…ForImportantUsageKey`: the latter reads better — it
    /// accounts for purgeable space the OS would reclaim — but it does not exist on watchOS, and
    /// watchOS is this package's only real deployment target. Using it compiles for the macOS
    /// test host and fails the watch build, which is how it was found on the Modern tier. The
    /// plain key exists everywhere and under-reports rather than over-reports, which is the safe
    /// direction for a gate that refuses runs.
    public static let volumeFreeBytes: @Sendable (URL) -> Int64? = { url in
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let available = values.volumeAvailableCapacity
        else { return nil }
        return Int64(available)
    }

    // MARK: - Orphan detection

    /// Scans for a run left over from a previous launch that was never cleanly ended — the file
    /// this store's own `flush` leaves behind with no matching `finalizeRun`. Called once at
    /// launch, before any new run starts.
    public func detectOrphan() -> OrphanedRun? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "inprogress" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(StoredRun.self, from: data)
            else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            return OrphanedRun(
                runID: record.runID, sampleCount: record.samples.count, lastModified: modified
            )
        }
        return nil
    }

    /// Reads back an orphaned run's samples, for the save path.
    public func loadOrphan(runID: UUID) -> [RunSample]? {
        let url = inProgressURL(for: runID)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(StoredRun.self, from: data)
        else { return nil }
        return record.samples
    }

    /// Deletes an orphaned run's file — the discard path.
    public func discardOrphan(runID: UUID) {
        try? fileManager.removeItem(at: inProgressURL(for: runID))
    }

    // MARK: - Capture

    public func startRun(runID: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.runID = runID
        buffer.removeAll(keepingCapacity: true)
        flushIntervalAnchor = nil
    }

    /// Appends a sample and flushes if `flushIntervalSeconds` have elapsed since the last flush.
    ///
    /// Flushing is tick-driven, not timer-driven: the 1 Hz run loop already ticks reliably, and a
    /// real `Timer` would be a second clock the cadence could drift against. On Series 3 that
    /// argument is stronger still — it is the slowest device the product supports (NFR-1), so a
    /// second timer is a second thing to fall behind.
    public func append(_ sample: RunSample, flushIntervalSeconds: TimeInterval) {
        lock.lock()
        buffer.append(sample)
        // The first sample of a run starts the clock rather than triggering a flush, so the first
        // write lands one full interval in.
        let anchor = flushIntervalAnchor ?? sample.timestamp
        flushIntervalAnchor = anchor
        let shouldFlush = sample.timestamp - anchor >= flushIntervalSeconds
        lock.unlock()

        if shouldFlush { flush() }
    }

    /// Writes the full buffer atomically. Public so callers can force a flush on pause or
    /// backgrounding, not only on the interval.
    public func flush() {
        lock.lock()
        guard let runID else { lock.unlock(); return }
        let record = StoredRun(runID: runID, samples: buffer)
        let timestamp = buffer.last?.timestamp
        lock.unlock()

        guard let data = try? JSONEncoder().encode(record) else { return }

        let destination = inProgressURL(for: runID)
        let temp = directory.appendingPathComponent("\(runID.uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            return
        }

        // An empty buffer leaves the anchor alone — a forced flush with nothing to write must not
        // reset the interval clock to an unrelated timestamp.
        if let timestamp {
            lock.lock(); flushIntervalAnchor = timestamp; lock.unlock()
        }
    }

    /// Marks the run cleanly ended: flushes once more, then removes the in-progress marker so a
    /// future launch does not treat this run as orphaned.
    public func finalizeRun() {
        flush()
        lock.lock(); let id = runID; lock.unlock()
        guard let id else { return }
        try? fileManager.removeItem(at: inProgressURL(for: id))
    }

    public var bufferedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Storage precondition (DEG-6)

    /// Whether the volume holding the store has at least `minimumBytes` free. AC-FR-D-6 / DEG-6:
    /// a run is refused *before* it starts rather than failing partway through with data lost.
    public func hasSufficientStorage(minimumBytes: Int64) -> Bool {
        guard let available = freeBytes(directory) else {
            // Unable to determine free space: fail open rather than blocking every run on a
            // query that can legitimately be unsupported on some volumes.
            return true
        }
        return available >= minimumBytes
    }

    // MARK: - Private

    private func inProgressURL(for runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).inprogress")
    }

    private struct StoredRun: Codable {
        let runID: UUID
        let samples: [RunSample]
    }
}
