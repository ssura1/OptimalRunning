import Foundation
import ORModels
import WatchConnectivity
import WatchSupport

/// The watch's `WCSession` plumbing (T-106).
///
/// **This file did not exist, and that was the whole bug.** `SyncCoordinator`,
/// `PendingPayloadQueue`, `RunEnvelopeBuilder` and `DownlinkApplier` were all written,
/// tested and correct — and nothing in the app ever constructed any of them, because there
/// was no transport for them to sit on. `RunEnvelopeBuilder` was referenced nowhere outside
/// its own tests. A finished run therefore went nowhere, and the phone's fully-wired
/// receiving half sat waiting for files that were never sent.
///
/// It holds no decisions, deliberately, and mirrors `Apps/iPhone`'s coordinator: session
/// lifecycle and delegate callbacks only. When to transfer, what a stale context means, and
/// which payloads may be dropped are all decided in `WatchSupport` against fakes, because
/// the Simulator cannot reproduce real reachability transitions between paired devices.
@MainActor
final class WatchConnectivityTransport: NSObject, FileTransporting {

    /// `WCSession.isReachable` is *live* reachability — the phone awake and in range. File
    /// transfers do not need it; the system queues and retries them itself. But
    /// `SyncCoordinator` uses it to decide whether handing over now is worth attempting,
    /// and a session that has not finished activating cannot accept a transfer at all.
    var isReachable: Bool {
        guard WCSession.isSupported() else { return false }
        return WCSession.default.activationState == .activated
    }

    /// Wired after construction rather than injected, because `SyncCoordinator` takes the
    /// transport in *its* initialiser — the two reference each other and one of them has to
    /// be built first. `weak` on both sides so the cycle does not leak; `AppCoordinator`
    /// owns all three for the app's lifetime.
    private weak var sync: SyncCoordinator?
    private weak var downlink: DownlinkApplier?

    func connect(sync: SyncCoordinator, downlink: DownlinkApplier) {
        self.sync = sync
        self.downlink = downlink
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Hands a file to the system. Returns as soon as the transfer is *queued* — `WCSession`
    /// owns retry and delivery across launches from here, which is why the coordinator does
    /// not track individual completions.
    func transfer(fileAt url: URL, metadata: [String: String]) throws {
        guard WCSession.isSupported() else { throw TransportError.unsupported }
        WCSession.default.transferFile(url, metadata: metadata)
    }

    enum TransportError: Error {
        case unsupported
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityTransport: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            // Anything queued before this launch goes now. A run finished on a dead phone,
            // or before a crash, otherwise waits for a reachability change that may never
            // arrive — the watch would hold a synced-looking run forever.
            self.sync?.resume()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.sync?.reachabilityChanged() }
    }

    /// The phone's acknowledgements, profile and plan arrive on one channel.
    ///
    /// Parsed here rather than passed on as `[String: Any]`, which is not `Sendable`;
    /// `PhoneContext` is. Both halves are applied — `SyncCoordinator` owns acknowledgements
    /// (which is what lets a payload finally be dropped) and `DownlinkApplier` owns the
    /// profile and plan.
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let context = PhoneContext(context: applicationContext) else { return }
        Task { @MainActor in
            self.sync?.apply(context)
            self.downlink?.apply(context)
        }
    }
}
