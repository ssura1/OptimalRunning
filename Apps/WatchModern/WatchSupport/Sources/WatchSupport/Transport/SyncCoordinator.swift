import Foundation
import Observation
import ORModels

/// The transport the coordinator hands files to.
///
/// **Injectable on purpose, and this is load-bearing rather than tidiness.** The
/// Simulator's WatchConnectivity does not reliably reproduce real reachability
/// transitions — a paired-device behaviour it cannot model — so a test that drove the
/// real `WCSession` would pass while proving nothing about the case that actually
/// matters: a run enqueued with the phone away, transferring when it returns. Everything
/// about *when* to transfer is therefore decided here, against a fake that can be made
/// unreachable at will, and the real `WCSession` conformer holds no logic worth testing.
@MainActor
public protocol FileTransporting: AnyObject {
    var isReachable: Bool { get }
    /// Hands a file to the system for background transfer. The system owns retry and
    /// delivery; this returns as soon as the transfer is queued, not when it completes.
    func transfer(fileAt url: URL, metadata: [String: String]) throws
}

/// Drives the watch side of sync (T-048).
///
/// Two responsibilities, both of which are about *timing* rather than content:
/// enqueueing a finished run so it survives until the phone confirms it, and handing
/// pending payloads over whenever the phone becomes reachable.
///
/// It deliberately does not track individual transfer completions. `WCSession` retries
/// file transfers itself across launches, and a payload is only ever removed on the
/// phone's acknowledgement — so "did this particular transfer succeed?" is not a question
/// the correctness of the queue depends on. Re-handing a file the system is already
/// carrying is harmless because ingest is idempotent (AC-FR-E-1-3, NFR-13); that
/// idempotency is what lets this layer stay simple instead of maintaining a second,
/// subtly different retry state machine alongside the system's.
@MainActor
@Observable
public final class SyncCoordinator {

    /// Pending runs, for the UI to show a sync state.
    public private(set) var pendingCount: Int = 0
    /// Runs the phone refused, with reasons — surfaced rather than silently retried
    /// forever (AC-FR-E-1-4).
    public private(set) var rejections: [SyncNack] = []
    /// Highest `PhoneContext.sequence` applied, so an out-of-order redelivery cannot roll
    /// state backwards.
    public private(set) var lastAppliedSequence: Int = -1

    private let queue: PendingPayloadQueue
    private let transport: FileTransporting

    public init(queue: PendingPayloadQueue, transport: FileTransporting) {
        self.queue = queue
        self.transport = transport
        self.pendingCount = queue.pending.count
    }

    // MARK: - Uplink

    /// Enqueues a finished run and attempts delivery.
    ///
    /// AC-FR-E-1-1: enqueueing must not require the phone to be reachable. The write to
    /// disk happens unconditionally and *first*; reachability only decides whether a
    /// transfer is attempted now or on the next reconnect.
    @discardableResult
    public func enqueue(_ envelope: RunEnvelope, now: Date = Date()) throws -> PendingPayload {
        let payload = try SyncPayloadCodec.encode(envelope)
        let entry = try queue.enqueue(runID: envelope.runID, payload: payload, now: now)
        refresh()
        flush()
        return entry
    }

    /// Hands every pending payload to the transport, if the phone is reachable.
    ///
    /// A no-op when unreachable — not an error and not a queued retry of our own. The
    /// payloads are already durable, and `flush()` is called again on the next
    /// reachability change.
    public func flush() {
        guard transport.isReachable else { return }

        for entry in queue.pending {
            let url = queue.fileURL(for: entry.runID)
            let metadata = SyncFileMetadata(runID: entry.runID).dictionary
            do {
                try transport.transfer(fileAt: url, metadata: metadata)
                queue.markTransferAttempted(entry.runID)
            } catch {
                // The system refused the hand-off. Leave the payload pending; the next
                // reachability change retries it. Nothing is lost, so nothing is thrown.
                continue
            }
        }
    }

    /// Called when the transport's reachability changes (AC-FR-E-1-2, DEG-7).
    public func reachabilityChanged() {
        flush()
        refresh()
    }

    /// Retries whatever is already on disk. Called at launch, so a run enqueued before a
    /// crash or a battery death is handed over on the next start rather than waiting for a
    /// reachability change that may not come.
    public func resume() {
        flush()
        refresh()
    }

    // MARK: - Downlink

    /// Applies a context from the phone: acknowledgements, and whatever else it carries.
    ///
    /// Returns the context if it was applied, or `nil` if it was ignored as stale. The
    /// sequence guard matters because `updateApplicationContext` is latest-value-wins but
    /// *not* ordered on receipt — a context delivered late could otherwise resurrect an
    /// older profile or re-add an acknowledgement the watch has already acted on.
    @discardableResult
    public func apply(_ context: PhoneContext) -> PhoneContext? {
        guard context.sequence > lastAppliedSequence else { return nil }
        lastAppliedSequence = context.sequence

        queue.apply(context.acknowledgement)

        if !context.acknowledgement.nacked.isEmpty {
            // Replace rather than append: the context carries the phone's current view,
            // so accumulating would show the same rejection repeatedly.
            rejections = context.acknowledgement.nacked
        }

        refresh()
        return context
    }

    // MARK: - State

    private func refresh() {
        pendingCount = queue.pending.count
    }
}

// MARK: - Finished runs

/// The watch's finished-run destination (T-106).
///
/// `enqueue` writes to disk first and only then attempts a transfer, which is exactly the
/// contract `FinishedRunSink` needs: returning without throwing means *durable*, not
/// *delivered*. A run finished with the phone at home is safe the moment this returns.
extension SyncCoordinator: FinishedRunSink {
    public func accept(_ envelope: RunEnvelope) throws {
        try enqueue(envelope)
    }
}
