import Foundation
import ORModels
import SwiftData

/// What happened to a delivered payload.
public enum IngestOutcome: Sendable, Hashable {
    case accepted(runID: UUID)
    /// Refused, with the reason to send back and a message fit to show a person.
    case rejected(nack: SyncNack, message: String)

    public var runID: UUID {
        switch self {
        case let .accepted(runID): return runID
        case let .rejected(nack, _): return nack.runID
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Receives, validates, and stores payloads from the watch (T-049).
///
/// **Nothing here is allowed to crash on bad input.** A payload is untrusted: it was
/// produced by a different build, possibly a *newer* one, and arrived over a channel that
/// can truncate it. AC-FR-E-1-4 requires a clear message rather than a crash, so every
/// failure path returns a `SyncNack` and a sentence — including the paths that "cannot
/// happen", because a phone that crashes on receipt cannot even report why.
///
/// Order matters and is not arbitrary:
///
/// 1. **Version, from the metadata, before touching the file.** A future-schema payload
///    must be refused without decoding types this build has never heard of.
/// 2. **Decompress and decode**, which also validates the configuration snapshot.
/// 3. **Upsert by `runID`**, so re-delivery converges instead of duplicating (NFR-13).
/// 4. **Update aggregates**, in the same pass, so the statistics screen never disagrees
///    with the run list about what exists.
public struct EnvelopeIngestor {

    private let runs: RunRepository
    private let aggregates: AggregateRepository
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
        self.runs = RunRepository(context: context)
        self.aggregates = AggregateRepository(context: context)
    }

    // MARK: - Entry points

    /// Ingests a file handed over by the transport.
    public func ingest(fileAt url: URL, metadata: [String: Any]) -> IngestOutcome {
        guard let declared = SyncFileMetadata(dictionary: metadata) else {
            // No usable metadata means no `runID` to key on. A random ID would be worse
            // than a refusal: it would store an unreachable duplicate that no
            // acknowledgement could ever clear from the watch's queue.
            return .rejected(
                nack: SyncNack(runID: UUID(), reason: .malformed),
                message: "A run arrived without readable identification and could not be filed."
            )
        }

        guard let payload = try? Data(contentsOf: url) else {
            return .rejected(
                nack: SyncNack(runID: declared.runID, reason: .malformed),
                message: "A run's data could not be read from the transfer and will be sent again."
            )
        }

        return ingest(payload: payload, declared: declared)
    }

    /// Ingests raw payload bytes. `declared` is the transfer metadata, when available.
    public func ingest(payload: Data, declared: SyncFileMetadata? = nil) -> IngestOutcome {
        // Step 1 — the version gate, before any decoding.
        if let declared, declared.schemaVersion != RunEnvelope.currentSchemaVersion {
            return .rejected(
                nack: SyncNack(runID: declared.runID, reason: .unsupportedSchema),
                message: Self.unsupportedSchemaMessage(
                    found: declared.schemaVersion, supported: RunEnvelope.currentSchemaVersion
                )
            )
        }

        // Step 2 — decompress, decode, validate.
        let envelope: RunEnvelope
        do {
            envelope = try SyncPayloadCodec.decode(payload)
        } catch let error as EnvelopeError {
            // The metadata may have been absent or may have lied; the decoder checks the
            // version again from the bytes themselves, which is the authoritative reading.
            let runID = declared?.runID ?? UUID()
            switch error {
            case let .unsupportedSchema(found, supported):
                return .rejected(
                    nack: SyncNack(runID: runID, reason: .unsupportedSchema),
                    message: Self.unsupportedSchemaMessage(found: found, supported: supported)
                )
            case .malformed:
                return .rejected(
                    nack: SyncNack(runID: runID, reason: .malformed),
                    message: "A run's data was incomplete or damaged in transfer."
                )
            case let .invalidConfiguration(configurationError):
                return .rejected(
                    nack: SyncNack(runID: runID, reason: .invalidConfiguration),
                    message: "A run arrived with settings this version cannot interpret "
                        + "(\(configurationError)). The run was not saved."
                )
            }
        } catch {
            return .rejected(
                nack: SyncNack(runID: declared?.runID ?? UUID(), reason: .malformed),
                message: "A run's data could not be read (\(error))."
            )
        }

        // A `runID` in the metadata that disagrees with the payload is a routing bug, and
        // the payload wins: it is the thing actually being stored. Refusing outright would
        // lose a recoverable run over a metadata mistake.
        return store(envelope)
    }

    // MARK: - Storage

    private func store(_ envelope: RunEnvelope) -> IngestOutcome {
        do {
            // The previous state has to be read *before* the upsert overwrites it: undoing
            // a re-delivered run's earlier contribution needs the totals as they were, and
            // after the upsert they are gone.
            let previous = try runs.record(for: envelope.runID)
                .map { (summary: $0.summary, startedAt: $0.startedAt) }

            try runs.upsert(envelope)

            // Re-delivery must not double-count. Removing the previous contribution and
            // applying the new one is correct whether the payload is identical (a retry) or
            // revised (a sidecar replacing a degraded backfill).
            if let previous {
                try aggregates.remove(summary: previous.summary, startedAt: previous.startedAt)
            }
            try aggregates.apply(
                summary: envelope.summary,
                startedAt: envelope.startedAt,
                samples: envelope.samples.unpack()
            )

            return .accepted(runID: envelope.runID)
        } catch {
            return .rejected(
                nack: SyncNack(runID: envelope.runID, reason: .malformed),
                message: "A run could not be saved (\(error)). It will be sent again."
            )
        }
    }

    // MARK: - Messages

    /// Deliberately explains the *situation* rather than the error.
    ///
    /// "Unsupported schema version 2" tells the user nothing they can act on. The actionable
    /// fact is that their phone app is older than their watch app, and updating it fixes
    /// this — and, importantly, that the run is not lost in the meantime.
    static func unsupportedSchemaMessage(found: Int, supported: Int) -> String {
        found > supported
            ? "This run was recorded by a newer version of OptimalRunner on your watch. "
                + "Update the iPhone app to import it — the run is kept on your watch until then."
            : "This run was recorded by a version of OptimalRunner too old to import "
                + "(format \(found); this app reads \(supported))."
    }
}
