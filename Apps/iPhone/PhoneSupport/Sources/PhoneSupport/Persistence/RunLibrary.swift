import Foundation
import ORModels
import ORStats
import SwiftData

/// The single write surface for the run history (T-053, T-061).
///
/// Every mutation goes through here so the store and the aggregate cache cannot drift apart.
/// The alternative — callers using `RunRepository` and `AggregateRepository` directly — means
/// each new call site has to remember to update both, and the one that forgets produces a
/// statistics screen that quietly disagrees with the run list. That disagreement is invisible
/// until someone adds up their monthly mileage by hand.
public struct RunLibrary {

    private let context: ModelContext
    public let runs: RunRepository
    public let aggregates: AggregateRepository

    public init(context: ModelContext) {
        self.context = context
        self.runs = RunRepository(context: context)
        self.aggregates = AggregateRepository(context: context)
    }

    // MARK: - Writes

    /// Ingests a payload from the watch.
    @discardableResult
    public func ingest(payload: Data, declared: SyncFileMetadata? = nil) -> IngestOutcome {
        EnvelopeIngestor(context: context).ingest(payload: payload, declared: declared)
    }

    @discardableResult
    public func ingest(fileAt url: URL, metadata: [String: Any]) -> IngestOutcome {
        EnvelopeIngestor(context: context).ingest(fileAt: url, metadata: metadata)
    }

    /// Deletes a run and withdraws its contribution from the totals.
    ///
    /// The summary is read *before* the delete, because afterwards there is nothing to subtract.
    ///
    /// Personal bests are **not** corrected here, and cannot be: a best is a maximum over runs,
    /// so recovering the previous holder needs the others. Deleting a run that held one
    /// therefore leaves it stale until a rebuild — so this schedules one rather than leaving a
    /// deleted run claiming the user's 5 k record. It is the expensive path, which is exactly
    /// why it is on deletion (rare) rather than on ingest (every run).
    public func delete(runID: UUID) throws {
        guard let record = try runs.record(for: runID) else { return }
        let heldABest = try recordCouldHoldABest(record)

        try aggregates.remove(summary: record.summary, startedAt: record.startedAt)
        try runs.delete(runID: runID)

        if heldABest {
            try aggregates.rebuildAllIncludingBests(runs: runs)
        }
    }

    /// Whether this run is long enough to have set any benchmark best.
    ///
    /// A cheap filter so deleting a 3 km jog does not trigger a full re-sweep of every stored
    /// run's samples. Deliberately conservative: it asks only whether the run *could* hold a
    /// best, not whether it does, because checking properly would cost the sweep it is trying
    /// to avoid.
    private func recordCouldHoldABest(_ record: RunRecord) throws -> Bool {
        guard let shortest = BenchmarkDistance.allCases.map(\.metres).min() else { return false }
        return record.distanceMetres >= shortest
    }

    /// Recomputes the totals from the stored runs, and returns them.
    @discardableResult
    public func rebuildAggregates(includingBests: Bool = false) throws -> AggregateCache {
        includingBests
            ? try aggregates.rebuildAllIncludingBests(runs: runs)
            : try aggregates.rebuildAll(runs: runs)
    }
}
