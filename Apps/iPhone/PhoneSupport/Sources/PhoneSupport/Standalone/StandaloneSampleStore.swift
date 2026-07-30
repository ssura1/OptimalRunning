import Foundation
import ORModels

/// Append-only, crash-durable capture of a standalone run (S-032, NFR-S-13,
/// AC-FR-S-A-2-4).
///
/// The same shape as the watch's `SampleStore` — hold samples in memory, periodically
/// write the whole accumulated array via atomic replace, leave an `.inprogress` marker that
/// a later launch can find — and **not** the same type, which is worth being explicit
/// about because the duplication would otherwise look like laziness.
///
/// What differs is what has to survive. A watch run's samples are the whole record. A
/// standalone run's are not: its cadence, its measured/estimated split, its calibration
/// state and its estimated spans are facts no `RunSample` carries (they live in
/// `StandaloneRunFacts`), and a recovered orphan that lost them would come back as a run
/// claiming a distance with nothing to say about where the distance came from. Sharing the
/// watch's type would mean widening it with fields the watch has no use for, on a package
/// the phone must not import anyway.
///
/// Real file I/O throughout, deliberately: `FileManager` and `Data` are plain Foundation,
/// so this is testable against a real temporary directory rather than a filesystem fake.
public final class StandaloneSampleStore: @unchecked Sendable {

    public struct OrphanedRun: Sendable {
        public let runID: UUID
        public let sampleCount: Int
        public let lastModified: Date
        public let facts: StandaloneRunFacts?
    }

    /// What a recovered run comes back as.
    public struct RecoveredRun: Sendable {
        public let runID: UUID
        public let samples: [RunSample]
        public let facts: StandaloneRunFacts?
        public let route: [RoutePoint]
        public let startedAt: Date
        public let runType: RunType
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let freeBytes: @Sendable (URL) -> Int64?

    private var runID: UUID?
    private var header: Header?
    private var buffer: [RunSample] = []
    private var route: [RoutePoint] = []
    private var facts: StandaloneRunFacts?
    private var flushIntervalAnchor: TimeInterval?

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        freeBytes: @escaping @Sendable (URL) -> Int64? = StandaloneSampleStore.volumeFreeBytes
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.freeBytes = freeBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static let volumeFreeBytes: @Sendable (URL) -> Int64? = { url in
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
            let available = values.volumeAvailableCapacity
        else { return nil }
        return Int64(available)
    }

    // MARK: - Orphan recovery

    /// A run left over from a launch that never ended cleanly (AC-FR-S-A-2-4).
    ///
    /// On this tier an orphan is more likely than on the watch, not less: iOS terminates
    /// backgrounded apps for memory pressure without warning, and a standalone run spends
    /// most of its life backgrounded by design (CON-S-4). The recovery path is therefore a
    /// normal case, not an edge one.
    public func detectOrphan() -> OrphanedRun? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        for file in files where file.pathExtension == "inprogress" {
            guard let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(StoredRun.self, from: data)
            else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            return OrphanedRun(
                runID: record.header.runID,
                sampleCount: record.samples.count,
                lastModified: modified,
                facts: record.facts)
        }
        return nil
    }

    public func loadOrphan(runID: UUID) -> RecoveredRun? {
        guard let data = try? Data(contentsOf: inProgressURL(for: runID)),
            let record = try? JSONDecoder().decode(StoredRun.self, from: data)
        else { return nil }
        return RecoveredRun(
            runID: record.header.runID,
            samples: record.samples,
            facts: record.facts,
            route: record.route,
            startedAt: record.header.startedAt,
            runType: record.header.runType)
    }

    public func discardOrphan(runID: UUID) {
        try? fileManager.removeItem(at: inProgressURL(for: runID))
    }

    // MARK: - Capture

    public func startRun(runID: UUID, startedAt: Date, runType: RunType) {
        lock.lock(); defer { lock.unlock() }
        self.runID = runID
        self.header = Header(runID: runID, startedAt: startedAt, runType: runType)
        buffer.removeAll(keepingCapacity: true)
        route.removeAll(keepingCapacity: true)
        facts = nil
        flushIntervalAnchor = nil
    }

    /// Appends a sample and flushes if the interval has elapsed.
    ///
    /// Tick-driven rather than timer-driven, for the reason the watch's store gives: the
    /// 1 Hz run loop already ticks reliably, and a real `Timer` would be a second clock the
    /// flush cadence could drift against. It matters more here — a backgrounded app's
    /// timers are at the system's discretion, and the tick is the thing that is definitely
    /// still happening because it is what the location updates are keeping alive.
    public func append(
        _ sample: RunSample,
        routePoint: RoutePoint?,
        facts: StandaloneRunFacts?,
        flushIntervalSeconds: TimeInterval
    ) {
        lock.lock()
        buffer.append(sample)
        if let routePoint { route.append(routePoint) }
        if let facts { self.facts = facts }
        let anchor = flushIntervalAnchor ?? sample.timestamp
        flushIntervalAnchor = anchor
        let shouldFlush = sample.timestamp - anchor >= flushIntervalSeconds
        lock.unlock()

        if shouldFlush { flush() }
    }

    /// Writes the full buffer atomically. Public so a caller can force a flush on pause or
    /// on backgrounding rather than only on the interval — and the backgrounding case is
    /// the one that earns it, because that is the moment iOS is most likely to terminate
    /// the process.
    public func flush() {
        lock.lock()
        guard let runID, let header else { lock.unlock(); return }
        let record = StoredRun(header: header, samples: buffer, route: route, facts: facts)
        let timestamp = buffer.last?.timestamp
        lock.unlock()

        guard let data = try? JSONEncoder().encode(record) else { return }

        let destination = inProgressURL(for: runID)
        let temp = directory.appendingPathComponent("\(runID.uuidString).tmp")
        do {
            // Atomic replace — temp file then rename — is what bounds the loss to "since
            // the last flush" rather than "since the write started". A crash mid-write
            // leaves the previous flush intact, never a half-written file.
            try data.write(to: temp, options: .atomic)
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            return
        }

        if let timestamp {
            lock.lock(); flushIntervalAnchor = timestamp; lock.unlock()
        }
    }

    /// Marks the run cleanly ended, so a future launch does not offer it as an orphan.
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

    /// DEG-6, applied to this tier: a doomed run must never begin. Failing at minute forty
    /// with a full disk loses the run; refusing at second zero loses nothing.
    public func hasSufficientStorage(minimumBytes: Int64) -> Bool {
        guard let available = freeBytes(directory) else { return true }
        return available >= minimumBytes
    }

    // MARK: - Private

    private func inProgressURL(for runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).inprogress")
    }

    private struct Header: Codable {
        let runID: UUID
        let startedAt: Date
        let runType: RunType
    }

    private struct StoredRun: Codable {
        let header: Header
        let samples: [RunSample]
        let route: [RoutePoint]
        let facts: StandaloneRunFacts?
    }
}
