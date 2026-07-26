import Foundation
import Observation
import ORModels
import PhoneSupport
import SwiftData
import WatchConnectivity

/// The phone's `WCSession` plumbing (T-049, T-050).
///
/// **This file holds no decisions.** Validation, idempotent upsert, aggregate maintenance and the
/// acknowledgement window all live in `PhoneSupport`, where they are tested against fakes; what is
/// here is the session lifecycle and the delegate callbacks, which is the part no test can reach
/// without two paired physical devices. Keeping the split sharp is what makes the untestable
/// portion small enough to verify by hand — see the manual protocol in `Apps/iPhone/README.md`.
@MainActor
@Observable
public final class WatchSyncCoordinator: NSObject {

    /// Runs ingested this session, for a diagnostic view.
    public private(set) var ingested: [UUID] = []
    /// Payloads refused, with the message to show. Surfaced rather than swallowed (AC-FR-E-1-4).
    public private(set) var rejections: [(runID: UUID, message: String)] = []
    public private(set) var isReachable = false

    private let container: ModelContainer
    private var publisher: PhoneContextPublisher?

    public init(container: ModelContainer) {
        self.container = container
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self

        let context = ModelContext(container)
        publisher = PhoneContextPublisher(
            transport: WCSessionContextTransport(session: session),
            context: context
        )
        session.activate()
    }

    /// Publishes the current context to the watch. Safe to call whenever the profile changes.
    public func publishContext() {
        try? publisher?.publish()
    }

    // MARK: - Ingest

    /// Handles a received payload on a fresh context.
    ///
    /// A new `ModelContext` per delivery rather than a long-lived one: a transfer can arrive while
    /// the app is in the background with no UI, and sharing the view context would mean mutating a
    /// context SwiftUI is observing from a delegate callback. Idempotent ingest is what makes a
    /// separate context safe — two contexts racing the same run converge on one record, which
    /// `IngestTests` asserts directly.
    ///
    /// Takes bytes rather than a URL because the file no longer exists by the time this runs —
    /// see the delegate below.
    fileprivate func ingest(payload: Data?, declared: SyncFileMetadata?) {
        let context = ModelContext(container)
        let ingestor = EnvelopeIngestor(context: context)

        let outcome: IngestOutcome
        switch (payload, declared) {
        case let (payload?, declared):
            outcome = ingestor.ingest(payload: payload, declared: declared)
        case (nil, let declared?):
            outcome = .rejected(
                nack: SyncNack(runID: declared.runID, reason: .malformed),
                message: "A run's data could not be read from the transfer and will be sent again."
            )
        case (nil, nil):
            outcome = .rejected(
                nack: SyncNack(runID: UUID(), reason: .malformed),
                message: "A run arrived without readable identification and could not be filed."
            )
        }

        switch outcome {
        case let .accepted(runID):
            ingested.append(runID)
        case let .rejected(nack, message):
            rejections.append((nack.runID, message))
        }

        // The watch only stops retaining a payload when it hears back, so the acknowledgement is
        // published immediately rather than on a timer (AC-FR-E-1-2).
        publisher?.record(outcome)
        publishContext()
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncCoordinator: WCSessionDelegate {

    public nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // Publish on activation so a watch that has been waiting learns what the phone
            // already holds without needing a run to arrive first.
            self.publishContext()
        }
    }

    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    public nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // **Read the bytes here, synchronously.** WatchConnectivity deletes the transferred file
        // as soon as this method returns, so hopping to the main actor first and reading there
        // would race the deletion — intermittently losing runs, on a path with no error to
        // report. Reading now costs a ~30 KB copy on the delegate queue and removes the race.
        //
        // Parsing the metadata here too is the other half: `[String: Any]` is not `Sendable`, and
        // `SyncFileMetadata` is — so the value crossing to the main actor is a checked one rather
        // than an unchecked dictionary.
        let payload = try? Data(contentsOf: file.fileURL)
        let declared = file.metadata.flatMap(SyncFileMetadata.init(dictionary:))

        Task { @MainActor in self.ingest(payload: payload, declared: declared) }
    }

    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate, or the phone stops receiving transfers after a watch switch.
        WCSession.default.activate()
    }
}

/// `ContextTransporting` over a real session.
private final class WCSessionContextTransport: ContextTransporting {
    private let session: WCSession

    init(session: WCSession) {
        self.session = session
    }

    func send(context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }
}
