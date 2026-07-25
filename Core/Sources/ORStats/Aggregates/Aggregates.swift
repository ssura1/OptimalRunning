import Foundation
import ORModels

/// Running totals for a period (FR-F-3).
public struct AggregateTotals: Codable, Sendable, Hashable {
    public var runCount: Int
    public var distanceMetres: Double
    public var activeSeconds: TimeInterval
    public var elevationGainMetres: Double

    public static let zero = AggregateTotals(
        runCount: 0, distanceMetres: 0, activeSeconds: 0, elevationGainMetres: 0
    )

    public init(
        runCount: Int,
        distanceMetres: Double,
        activeSeconds: TimeInterval,
        elevationGainMetres: Double
    ) {
        self.runCount = runCount
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.elevationGainMetres = elevationGainMetres
    }

    public var averagePace: Pace? {
        Pace(distanceMetres: distanceMetres, seconds: activeSeconds)
    }

    public mutating func add(_ summary: RunSummary) {
        runCount += 1
        distanceMetres += summary.distanceMetres
        activeSeconds += summary.activeSeconds
        elevationGainMetres += summary.elevationGainMetres
    }

    public mutating func remove(_ summary: RunSummary) {
        runCount = max(runCount - 1, 0)
        distanceMetres = max(distanceMetres - summary.distanceMetres, 0)
        activeSeconds = max(activeSeconds - summary.activeSeconds, 0)
        elevationGainMetres = max(elevationGainMetres - summary.elevationGainMetres, 0)
    }
}

/// Identifies a calendar bucket.
public struct PeriodKey: Codable, Sendable, Hashable, Comparable {
    public let year: Int
    /// 1–12 for month buckets, 0 for year buckets.
    public let month: Int
    /// ISO week number for week buckets, 0 otherwise.
    public let week: Int

    public init(year: Int, month: Int = 0, week: Int = 0) {
        self.year = year
        self.month = month
        self.week = week
    }

    public static func < (lhs: PeriodKey, rhs: PeriodKey) -> Bool {
        (lhs.year, lhs.month, lhs.week) < (rhs.year, rhs.month, rhs.week)
    }
}

/// Incrementally maintained totals (AC-FR-F-3-5).
///
/// Recomputing lifetime totals from a thousand runs every time the statistics screen
/// opens cannot meet the 300 ms budget (NFR-5). So ingest applies a delta and the
/// screen reads a cached value. `rebuild(from:)` exists for migrations and for
/// repairing drift, and is deliberately never called from a UI path.
public struct AggregateCache: Codable, Sendable {

    public private(set) var lifetime: AggregateTotals = .zero
    public private(set) var byYear: [PeriodKey: AggregateTotals] = [:]
    public private(set) var byMonth: [PeriodKey: AggregateTotals] = [:]
    public private(set) var byWeek: [PeriodKey: AggregateTotals] = [:]
    public private(set) var bests: [BenchmarkDistance: BestEffort] = [:]

    public init() {}

    /// Applies one run. O(1) — four dictionary updates and a best-effort comparison.
    public mutating func apply(
        summary: RunSummary,
        startedAt: Date,
        bestEfforts: [BenchmarkDistance: BestEffort] = [:],
        calendar: Calendar = AggregateCache.isoCalendar
    ) {
        lifetime.add(summary)
        mutate(&byYear, key: AggregateCache.yearKey(startedAt, calendar)) { $0.add(summary) }
        mutate(&byMonth, key: AggregateCache.monthKey(startedAt, calendar)) { $0.add(summary) }
        mutate(&byWeek, key: AggregateCache.weekKey(startedAt, calendar)) { $0.add(summary) }

        for (distance, effort) in bestEfforts {
            if let existing = bests[distance], existing.seconds <= effort.seconds { continue }
            bests[distance] = effort
        }
    }

    /// Reverses one run's contribution.
    ///
    /// Personal bests are deliberately *not* reversed: recovering the previous best
    /// would need a full rescan, so a deletion leaves `bests` stale until
    /// `rebuild(from:)` runs. Callers that delete runs should schedule a rebuild.
    public mutating func remove(
        summary: RunSummary,
        startedAt: Date,
        calendar: Calendar = AggregateCache.isoCalendar
    ) {
        lifetime.remove(summary)
        mutate(&byYear, key: AggregateCache.yearKey(startedAt, calendar)) { $0.remove(summary) }
        mutate(&byMonth, key: AggregateCache.monthKey(startedAt, calendar)) { $0.remove(summary) }
        mutate(&byWeek, key: AggregateCache.weekKey(startedAt, calendar)) { $0.remove(summary) }
    }

    /// Full recomputation. The reference implementation that `apply` must agree with.
    public static func rebuild(
        from runs: [(summary: RunSummary, startedAt: Date, bests: [BenchmarkDistance: BestEffort])],
        calendar: Calendar = AggregateCache.isoCalendar
    ) -> AggregateCache {
        var cache = AggregateCache()
        for run in runs {
            cache.apply(
                summary: run.summary,
                startedAt: run.startedAt,
                bestEfforts: run.bests,
                calendar: calendar
            )
        }
        return cache
    }

    public func totals(forYear year: Int) -> AggregateTotals {
        byYear[PeriodKey(year: year)] ?? .zero
    }

    public func totals(for date: Date, granularity: Granularity, calendar: Calendar = AggregateCache.isoCalendar) -> AggregateTotals {
        switch granularity {
        case .year: return byYear[AggregateCache.yearKey(date, calendar)] ?? .zero
        case .month: return byMonth[AggregateCache.monthKey(date, calendar)] ?? .zero
        case .week: return byWeek[AggregateCache.weekKey(date, calendar)] ?? .zero
        }
    }

    public enum Granularity: Sendable { case year, month, week }

    /// Trailing weekly distances, oldest first, for the 52-week chart (AC-FR-F-3-3).
    /// Weeks with no runs are present as zeros so the chart has no gaps.
    public func weeklySeries(
        endingAt date: Date,
        weeks: Int,
        calendar: Calendar = AggregateCache.isoCalendar
    ) -> [(key: PeriodKey, totals: AggregateTotals)] {
        (0..<weeks).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .weekOfYear, value: -offset, to: date) else {
                return nil
            }
            let key = AggregateCache.weekKey(day, calendar)
            return (key, byWeek[key] ?? .zero)
        }
    }

    // MARK: Private

    private func mutate(
        _ table: inout [PeriodKey: AggregateTotals],
        key: PeriodKey,
        _ body: (inout AggregateTotals) -> Void
    ) {
        var totals = table[key] ?? .zero
        body(&totals)
        table[key] = totals
    }

    /// ISO 8601 weeks, so the week boundary does not shift with device locale and
    /// make a synced statistic disagree between two of the user's devices.
    public static let isoCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    static func yearKey(_ date: Date, _ calendar: Calendar) -> PeriodKey {
        PeriodKey(year: calendar.component(.year, from: date))
    }

    static func monthKey(_ date: Date, _ calendar: Calendar) -> PeriodKey {
        PeriodKey(
            year: calendar.component(.year, from: date),
            month: calendar.component(.month, from: date)
        )
    }

    static func weekKey(_ date: Date, _ calendar: Calendar) -> PeriodKey {
        PeriodKey(
            year: calendar.component(.yearForWeekOfYear, from: date),
            week: calendar.component(.weekOfYear, from: date)
        )
    }
}
