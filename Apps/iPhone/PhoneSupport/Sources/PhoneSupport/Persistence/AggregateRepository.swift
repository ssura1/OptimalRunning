import Foundation
import ORModels
import ORStats
import SwiftData

/// Maintains the statistics cache (T-061, NFR-5).
///
/// The cache is `Core`'s `AggregateCache`, applied incrementally as runs arrive and removed
/// as they are deleted, stored as one encoded blob. `rebuildAll()` recomputes it from every
/// stored run and exists as more than a repair tool: it is the *oracle* the incremental path
/// is tested against, because an incremental total that has silently drifted is precisely the
/// failure nobody notices.
public struct AggregateRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: Reading

    public func cache() throws -> AggregateCache {
        guard let record = try record(), let decoded = try? decoder.decode(AggregateCache.self, from: record.cacheData)
        else { return AggregateCache() }
        return decoded
    }

    private func record() throws -> AggregateCacheRecord? {
        let id = AggregateCacheRecord.singletonID
        var descriptor = FetchDescriptor<AggregateCacheRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Writing

    /// Folds one run into the cache.
    ///
    /// `samples` is optional because the best-effort sweep needs the series and the
    /// additive totals do not. Passing them computes in-run bests (AC-FR-F-3-4); omitting
    /// them updates distance and duration only.
    public func apply(summary: RunSummary, startedAt: Date, samples: [RunSample]?) throws {
        var cache = try cache()
        cache.apply(
            summary: summary,
            startedAt: startedAt,
            bestEfforts: Self.bestEfforts(from: samples)
        )
        try write(cache)
    }

    /// Removes one run from the cache.
    ///
    /// Note the asymmetry, which `Core` documents and this inherits: a personal best is a
    /// maximum over runs, so reversing one run cannot restore the previous best without
    /// rescanning the others. `remove` corrects the additive totals only, leaving `bests`
    /// stale until a rebuild. Callers that delete a run must schedule one — otherwise a run
    /// the user deleted keeps claiming their 5 k record.
    public func remove(summary: RunSummary, startedAt: Date) throws {
        var cache = try cache()
        cache.remove(summary: summary, startedAt: startedAt)
        try write(cache)
    }

    /// Recomputes the additive totals from every stored run. The oracle, and the repair path.
    ///
    /// Samples are deliberately not loaded: rebuilding over 1 000 runs' sample series would
    /// page in every external blob, which is the cost `.externalStorage` exists to avoid.
    /// Bests are rebuilt by `rebuildAllIncludingBests` when they are actually needed.
    @discardableResult
    public func rebuildAll(runs: RunRepository) throws -> AggregateCache {
        var cache = AggregateCache()
        for entry in try runs.allSummaries() {
            cache.apply(summary: entry.summary, startedAt: entry.startedAt)
        }
        try write(cache)
        return cache
    }

    /// Recomputes including the in-run best-effort sweep (AC-FR-F-3-4).
    ///
    /// Separate from `rebuildAll` because it is expensive by nature — it unpacks every run's
    /// samples — and because the two answer different questions. A caller that needs only
    /// totals should not pay for the sweep.
    @discardableResult
    public func rebuildAllIncludingBests(runs: RunRepository) throws -> AggregateCache {
        var cache = AggregateCache()
        let descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )

        for record in try context.fetch(descriptor) {
            cache.apply(
                summary: record.summary,
                startedAt: record.startedAt,
                bestEfforts: Self.bestEfforts(from: try record.samples())
            )
        }
        try write(cache)
        return cache
    }

    /// Sweeps a run's samples for in-run bests.
    ///
    /// Timestamps come from the sample series, which is session-relative rather than
    /// active-elapsed. For a best effort that distinction only matters if the runner paused
    /// mid-segment, in which case the segment's elapsed time legitimately includes the
    /// pause — a 5 k with a two-minute stop in it is not a 5 k PB, and counting it as one
    /// would be the wrong answer.
    static func bestEfforts(from samples: [RunSample]?) -> [BenchmarkDistance: BestEffort] {
        guard let samples, samples.count >= 2 else { return [:] }
        return PersonalBestSweep.allBestEfforts(
            cumulativeDistance: samples.map(\.cumulativeDistance),
            timestamps: samples.map(\.timestamp)
        )
    }

    private func write(_ cache: AggregateCache) throws {
        let data = try RunEnvelopeCoder.makeEncoder().encode(cache)
        if let record = try record() {
            record.cacheData = data
            record.updatedAt = Date()
        } else {
            context.insert(AggregateCacheRecord(cacheData: data))
        }
        try context.save()
    }

    private var decoder: JSONDecoder { RunEnvelopeCoder.makeDecoder() }
}
