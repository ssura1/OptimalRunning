import Foundation
import ORModels

/// Where a queued payload has got to.
///
/// Modelled explicitly rather than as a `Bool` because eviction depends on the
/// distinction: AC-FR-E-1-5 forbids dropping an unacknowledged payload in favour of an
/// acknowledged one, which is unstatable if "has the phone got this?" is not part of the
/// record.
public enum PayloadState: String, Codable, Sendable, Hashable {
    /// Needs delivering. Either never handed to the system, or handed over and not yet
    /// acknowledged — the queue does not distinguish those two, because the system owns
    /// retry and re-handing an in-flight file is harmless (ingest is idempotent).
    case pending
    /// The phone has durably stored this run. Safe to delete.
    case acknowledged
    /// The phone refused it. Retrying cannot help until the phone changes.
    case rejected
}

/// One queued run.
public struct PendingPayload: Codable, Sendable, Hashable {
    public let runID: UUID
    public let createdAt: Date
    public let byteCount: Int
    public var state: PayloadState
    /// Set when `state == .rejected`, so the UI can say *why* a run will never sync.
    public var rejection: SyncRejection?
    /// How many times this has been handed to the transport. Diagnostic only — retry is
    /// the system's job, not ours.
    public var transferAttempts: Int

    public init(
        runID: UUID,
        createdAt: Date,
        byteCount: Int,
        state: PayloadState = .pending,
        rejection: SyncRejection? = nil,
        transferAttempts: Int = 0
    ) {
        self.runID = runID
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.state = state
        self.rejection = rejection
        self.transferAttempts = transferAttempts
    }

    /// True for anything the phone has not confirmed. The population AC-FR-E-1-5
    /// protects.
    public var isUnacknowledged: Bool { state == .pending }
}

/// The watch's durable queue of run payloads awaiting the phone (T-048).
///
/// **Durability is the whole point.** AC-FR-E-1-2 keeps a payload until the phone
/// acknowledges it, and DEG-7 expects that to survive the phone being away for *days* —
/// during which the watch will certainly be rebooted and the app certainly killed. So
/// both the bytes and the bookkeeping live on disk, and the index is written with an
/// atomic replace for the same reason `SampleStore` does: a crash mid-write must leave
/// the previous index intact rather than a truncated one, because an unreadable index
/// means a queue of files nothing knows the state of.
///
/// **The index is reconciled against the filesystem on load, not trusted.** Files and
/// index entries can diverge — a crash between writing a payload and updating the index,
/// or a file deleted by the system under storage pressure. Trusting either one alone
/// leaks: an orphaned file is bytes nothing will ever send or clean up, and an orphaned
/// entry is a run reported as pending that cannot be transferred. Load-time
/// reconciliation is what keeps "50 MB of pending payloads" an honest number.
public final class PendingPayloadQueue: @unchecked Sendable {

    private let directory: URL
    private let fileManager: FileManager
    private let configuration: SyncConfiguration
    private let lock = NSLock()

    private var entries: [UUID: PendingPayload] = [:]

    private static let indexFileName = "queue-index.json"
    private static let payloadExtension = "envelope.gz"

    public init(
        directory: URL,
        configuration: SyncConfiguration = SyncConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.configuration = configuration
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        reconcile()
    }

    // MARK: - Reading

    public var all: [PendingPayload] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Runs still needing delivery, oldest first — the order they should be handed over.
    public var pending: [PendingPayload] {
        all.filter { $0.state == .pending }
    }

    public var totalByteCount: Int {
        all.reduce(0) { $0 + $1.byteCount }
    }

    public func payload(for runID: UUID) -> PendingPayload? {
        lock.lock(); defer { lock.unlock() }
        return entries[runID]
    }

    public func fileURL(for runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).\(Self.payloadExtension)")
    }

    public func data(for runID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(for: runID))
    }

    // MARK: - Writing

    /// Stores a payload and records it as pending.
    ///
    /// The bytes are written *before* the index entry: an orphaned file is recoverable by
    /// reconciliation, whereas an index entry with no file is a run the queue believes it
    /// has and does not. Ordering the two writes this way makes the recoverable failure
    /// the likely one.
    @discardableResult
    public func enqueue(runID: UUID, payload: Data, now: Date = Date()) throws -> PendingPayload {
        let url = fileURL(for: runID)
        try payload.write(to: url, options: .atomic)

        let entry = PendingPayload(runID: runID, createdAt: now, byteCount: payload.count)

        lock.lock()
        entries[runID] = entry
        lock.unlock()

        persistIndex()
        evictIfNeeded()
        return entry
    }

    public func markTransferAttempted(_ runID: UUID) {
        lock.lock()
        entries[runID]?.transferAttempts += 1
        lock.unlock()
        persistIndex()
    }

    /// Applies the phone's verdicts (AC-FR-E-1-2).
    ///
    /// Acknowledged payloads are deleted immediately — the bytes exist only to survive
    /// until the phone has them. The index entry is dropped with the file, so an
    /// acknowledged run leaves no trace to reconcile later.
    public func apply(_ acknowledgement: SyncAcknowledgement) {
        var toDelete: [UUID] = []

        lock.lock()
        for runID in acknowledgement.acked where entries[runID] != nil {
            entries[runID]?.state = .acknowledged
            toDelete.append(runID)
        }
        for nack in acknowledgement.nacked where entries[nack.runID] != nil {
            entries[nack.runID]?.state = .rejected
            entries[nack.runID]?.rejection = nack.reason
        }
        lock.unlock()

        for runID in toDelete { remove(runID) }
        persistIndex()
    }

    /// Deletes a payload and its bookkeeping.
    public func remove(_ runID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: runID))
        lock.lock()
        entries.removeValue(forKey: runID)
        lock.unlock()
        persistIndex()
    }

    // MARK: - Eviction (AC-FR-E-1-5)

    /// Brings the queue back inside its byte and count budgets.
    ///
    /// The ordering is the requirement, not an optimisation:
    ///
    /// 1. **Acknowledged** payloads first, oldest first. The phone already has these;
    ///    the bytes are pure residue.
    /// 2. **Rejected** payloads next. A run the phone has definitively refused cannot
    ///    become deliverable by waiting, so keeping it while dropping a run that *could*
    ///    still transfer would lose recoverable data to preserve unrecoverable data. This
    ///    ordering is a judgement call the AC does not spell out — it names only the
    ///    acknowledged-versus-unacknowledged rule — and is recorded in `design.md` §10.
    /// 3. **Pending** payloads last, oldest first, and only if the budget is still
    ///    exceeded after everything above is gone.
    ///
    /// A naive FIFO-by-age policy satisfies "evict oldest first" and violates the actual
    /// requirement, because a fresh acknowledged payload would survive while an older
    /// unacknowledged one — a run that exists nowhere else — is destroyed.
    @discardableResult
    public func evictIfNeeded() -> [UUID] {
        var evicted: [UUID] = []

        while isOverBudget, let victim = nextEvictionVictim() {
            remove(victim)
            evicted.append(victim)
        }
        return evicted
    }

    public var isOverBudget: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.count > configuration.maxPendingRuns
            || entries.values.reduce(0, { $0 + $1.byteCount }) > configuration.maxPendingBytes
    }

    private func nextEvictionVictim() -> UUID? {
        lock.lock(); defer { lock.unlock() }

        /// Lower rank is evicted first.
        func rank(_ state: PayloadState) -> Int {
            switch state {
            case .acknowledged: return 0
            case .rejected: return 1
            case .pending: return 2
            }
        }

        return entries.values
            .min { lhs, rhs in
                let lhsRank = rank(lhs.state)
                let rhsRank = rank(rhs.state)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.createdAt < rhs.createdAt
            }?
            .runID
    }

    // MARK: - Durability

    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

    private func persistIndex() {
        lock.lock()
        let snapshot = Array(entries.values)
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Loads the index and reconciles it against what is actually on disk.
    private func reconcile() {
        let stored: [PendingPayload] = {
            guard let data = try? Data(contentsOf: indexURL),
                  let decoded = try? JSONDecoder().decode([PendingPayload].self, from: data)
            else { return [] }
            return decoded
        }()

        let filesOnDisk = Set(
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(Self.payloadExtension) }
                .compactMap { UUID(uuidString: String($0.lastPathComponent.prefix(36))) }
        )

        var reconciled: [UUID: PendingPayload] = [:]

        // Entries whose file still exists survive with their recorded state.
        for entry in stored where filesOnDisk.contains(entry.runID) {
            reconciled[entry.runID] = entry
        }

        // A file with no surviving entry is adopted as pending rather than deleted. It
        // was written by `enqueue` before the index update, so it is a real run — and
        // the failure that lost its entry is exactly the crash-after-write this ordering
        // was chosen to make survivable. Adopting it risks re-sending a run the phone
        // already has, which idempotent ingest (AC-FR-E-1-3) makes harmless; deleting it
        // would lose the run outright.
        for runID in filesOnDisk where reconciled[runID] == nil {
            let url = fileURL(for: runID)
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            reconciled[runID] = PendingPayload(
                runID: runID, createdAt: created, byteCount: size ?? 0
            )
        }

        lock.lock()
        entries = reconciled
        lock.unlock()

        // Index entries whose file vanished are dropped by the rebuild above; persist so
        // the on-disk index matches what this instance believes.
        persistIndex()
    }
}
