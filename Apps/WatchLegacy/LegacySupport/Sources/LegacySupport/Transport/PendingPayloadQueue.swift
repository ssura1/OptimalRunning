import Foundation
import ORModels

/// A durable outbound queue for run payloads — Legacy tier (T-071, FR-E-1, AC-FR-E-1-2).
///
/// A deliberate duplicate of the Modern tier's queue (AC-FR-K-1-4). The requirement it exists for is
/// blunt: a run that reached this queue must not be lost, including across a relaunch, because a
/// dropped run is data nobody notices is gone until they go looking for it.
///
/// ## Eviction is by acknowledgement state, not by age
///
/// When the queue is full, the oldest *acknowledged* payload goes first, then the oldest *rejected*
/// one, and only then the oldest *pending* one. FIFO-by-age would be simpler and wrong: the oldest
/// entry is the one that has been waiting longest to be delivered, so age-ordered eviction discards
/// precisely the run least likely to have made it to the phone. Acknowledged payloads, by contrast,
/// are already safe on the phone and are kept only so a duplicate delivery can be answered cheaply.
public final class PendingPayloadQueue: @unchecked Sendable {

    public enum PayloadState: String, Codable, Sendable {
        case pending
        case acknowledged
        case rejected
    }

    public struct Entry: Codable, Sendable, Hashable {
        public let runID: UUID
        public let queuedAt: Date
        public var state: PayloadState
        /// Filename of the payload body, kept beside the index rather than inside it so the index
        /// stays small enough to rewrite atomically on every change.
        public let fileName: String
    }

    private let directory: URL
    private let fileManager: FileManager
    private let capacity: Int
    private let lock = NSLock()

    public init(directory: URL, capacity: Int = 32, fileManager: FileManager = .default) {
        self.directory = directory
        self.capacity = capacity
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// The queue as it stands on disk. Read fresh each time rather than cached in memory, because the
    /// durability requirement is about what survives a relaunch — an in-memory cache would let the
    /// two disagree, and the disk copy is the one that matters.
    public func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadIndex()
    }

    /// Enqueues a payload, evicting by state if the queue is at capacity.
    @discardableResult
    public func enqueue(runID: UUID, payload: Data, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }

        var index = loadIndex()

        // Re-enqueueing the same run replaces its body rather than adding a second entry: runID is
        // the idempotency key (AC-FR-E-1-3), so two entries for one run could only ever be duplicate
        // work.
        if let existing = index.firstIndex(where: { $0.runID == runID }) {
            let entry = index[existing]
            try? payload.write(to: directory.appendingPathComponent(entry.fileName), options: .atomic)
            index[existing].state = .pending
            writeIndex(index)
            return true
        }

        while index.count >= capacity {
            guard let victim = evictionCandidate(in: index) else { return false }
            try? fileManager.removeItem(at: directory.appendingPathComponent(index[victim].fileName))
            index.remove(at: victim)
        }

        let fileName = "\(runID.uuidString).payload"
        do {
            try payload.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return false
        }
        index.append(Entry(runID: runID, queuedAt: now, state: .pending, fileName: fileName))
        writeIndex(index)
        return true
    }

    /// The next payload to attempt, oldest pending first.
    public func nextPending() -> (entry: Entry, payload: Data)? {
        lock.lock(); defer { lock.unlock() }

        let index = loadIndex()
        guard let entry = index
            .filter({ $0.state == .pending })
            .min(by: { $0.queuedAt < $1.queuedAt })
        else { return nil }

        guard let payload = try? Data(
            contentsOf: directory.appendingPathComponent(entry.fileName)
        ) else {
            // The index references a body that is gone. Drop the entry rather than retrying forever.
            var repaired = index
            repaired.removeAll { $0.runID == entry.runID }
            writeIndex(repaired)
            return nil
        }
        return (entry, payload)
    }

    public func mark(runID: UUID, as state: PayloadState) {
        lock.lock(); defer { lock.unlock() }

        var index = loadIndex()
        guard let position = index.firstIndex(where: { $0.runID == runID }) else { return }
        index[position].state = state
        writeIndex(index)
    }

    public func remove(runID: UUID) {
        lock.lock(); defer { lock.unlock() }

        var index = loadIndex()
        guard let position = index.firstIndex(where: { $0.runID == runID }) else { return }
        try? fileManager.removeItem(at: directory.appendingPathComponent(index[position].fileName))
        index.remove(at: position)
        writeIndex(index)
    }

    public var count: Int { entries().count }

    // MARK: - Private

    /// Lower rank is evicted first. See the note on the type.
    private func rank(_ state: PayloadState) -> Int {
        switch state {
        case .acknowledged: return 0
        case .rejected: return 1
        case .pending: return 2
        }
    }

    private func evictionCandidate(in index: [Entry]) -> Int? {
        index.indices.min { left, right in
            let leftRank = rank(index[left].state)
            let rightRank = rank(index[right].state)
            if leftRank != rightRank { return leftRank < rightRank }
            return index[left].queuedAt < index[right].queuedAt
        }
    }

    private func loadIndex() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    /// Atomic replace, for the same reason `SampleStore.flush` uses it: a half-written index is a
    /// queue that cannot be read at all, which would lose every run in it rather than one.
    private func writeIndex(_ index: [Entry]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
