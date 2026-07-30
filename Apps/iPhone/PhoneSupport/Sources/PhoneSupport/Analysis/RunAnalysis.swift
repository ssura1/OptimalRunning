import Foundation
import ORColor
import ORIntervals
import ORModels
import ORStats

/// Everything the run detail screen renders, derived once from a stored run
/// (T-056 … T-060).
///
/// A value type built off the store, so every chart, table and overlay is checkable without a
/// view. The screens are then thin enough that "does the elevation overlay hide itself when
/// there is no altimeter data?" is a unit test rather than a visual inspection.
///
/// **The target band comes from the run's own configuration snapshot, never today's settings.**
/// A runner who tightens their tempo band next month must not find last month's runs redrawn as
/// though they had missed a target they were never given (design.md §9.1).
public struct RunAnalysis: Sendable {

    public let runID: UUID
    public let runType: RunType
    public let startedAt: Date
    public let isDegraded: Bool
    public let degradations: [DegradationFlag]

    public let samples: [RunSample]
    public let zoneTimeline: [ZoneSpan]
    public let summary: RunSummary
    public let steps: [StepSummary]
    public let route: [RoutePoint]
    public let plan: WorkoutPlan?
    /// The configuration in force when the run happened. `nil` for a degraded record, which
    /// is why every chart has to tolerate its absence rather than force-unwrap.
    public let configuration: PaceEngineConfiguration?
    public let profile: RunnerProfile?
    public let deviceTier: DeviceTier
    /// Present only for a standalone run (FR-S-E-2). Every standalone-specific section of
    /// the detail screen asks for this first, so a watch run renders exactly as it did.
    public let standalone: StandaloneRunFacts?

    // MARK: - Construction

    public init(record: RunRecord) throws {
        runID = record.runID
        runType = record.runType
        deviceTier = record.deviceTier
        standalone = try record.standaloneFacts()
        startedAt = record.startedAt
        isDegraded = record.isDegraded
        degradations = record.degradationFlags.compactMap(DegradationFlag.init(rawValue:))
        samples = try record.samples() ?? []
        zoneTimeline = try record.zoneTimeline()
        summary = record.summary
        steps = record.stepSummaries
        route = try record.route() ?? []
        plan = try record.plan()
        configuration = try record.configSnapshot()
        profile = try record.profileSnapshot()
    }

    // MARK: - Availability (what the screen may show at all)

    /// Whether there is a sample series to chart. False for a degraded record, and the reason
    /// the detail view says what is missing rather than rendering an empty axis (T-051).
    public var hasSamples: Bool { !samples.isEmpty }

    /// Whether an elevation profile can be drawn (AC-FR-F-2-3).
    ///
    /// Keyed on whether an altimeter was *present*, not on whether the ground varied. Those
    /// are different facts and conflating them is wrong in both directions: a genuinely flat
    /// outdoor run has real altitude data and deserves its (flat) profile, while a treadmill
    /// run has none and must hide the chart rather than draw a line at zero that reads as
    /// "level ground". The engine's `altimeterUnavailable` flag is the signal; an earlier
    /// version tested for variation instead and hid the chart for flat outdoor runs.
    public var hasElevationData: Bool {
        guard !degradations.contains(.altimeterUnavailable) else { return false }
        return samples.contains { $0.relativeAltitude?.isFinite == true }
    }

    /// Whether the grade-adjusted target diverged from the raw target anywhere (AC-FR-A-4-8).
    /// Drives the second overlay on the elevation chart.
    public var hasGradeAdjustment: Bool {
        // Read from the grade factor rather than by differencing the two target columns.
        //
        // Both targets are stored as Float32 in `PackedSamples`, so after a store round-trip
        // two values that were bit-identical differ by quantisation noise of order 1e-8 s/m.
        // An earlier version differenced them against a 1e-9 tolerance and therefore reported
        // grade adjustment on every run, including a treadmill. The grade factor has a
        // *documented* resolution, which makes "meaningfully different from 1.0" a question
        // with an exact answer.
        samples.contains { abs($0.gradeFactor.value - 1.0) > PackedSamples.gradeFactorResolution }
    }

    public var hasRoute: Bool { route.count >= 2 }

    // MARK: - Standalone provenance (FR-S-E-2)

    /// Whether the provenance panel should be shown at all. Only a standalone run has a
    /// measured/estimated split to show — a watch run's distance comes from HealthKit's own
    /// fused estimate, and inventing a split for it would be a fabrication.
    public var showsDistanceProvenance: Bool {
        standalone?.measuredFraction != nil
    }

    /// AC-FR-S-E-2-1, as a sentence.
    public var distanceProvenanceText: String? {
        guard let fraction = standalone?.measuredFraction else { return nil }
        return StandaloneStrings.provenance(measuredFraction: fraction)
    }

    /// AC-FR-S-E-2-2 — cadence is first-class on this tier because it is directly measured.
    public var averageCadenceText: String? {
        guard let spm = standalone?.averageCadenceStepsPerMinute, spm.isFinite, spm > 0 else {
            return nil
        }
        return "\(Int(spm.rounded())) spm"
    }

    /// AC-FR-S-E-2-4 — why this run's distance is lower-confidence, or `nil` when it is
    /// not.
    ///
    /// **Read from what was stored, never recomputed.** AC-FR-S-E-2-5 forbids retroactively
    /// rewriting a run when calibration later improves, and the way that rule gets broken is
    /// by deriving this from today's calibration instead of the run's own.
    public var lowerConfidenceReason: String? {
        guard let standalone, standalone.isLowerConfidence else { return nil }
        return StandaloneStrings.lowerConfidenceReason(standalone.calibration)
    }

    /// The conditions worth explaining after the fact, in a stable order so the same run
    /// always reads the same way.
    public var motionNotices: [String] {
        guard let standalone else { return [] }
        return MotionFlag.allCases
            .filter { standalone.flags.contains($0) }
            // `distanceEstimated` is already said, better, by the provenance sentence —
            // repeating "part of this run was estimated" under it would read as two
            // different problems.
            .filter { $0 != .distanceEstimated }
            .map(\.runnerFacingExplanation)
    }

    /// True when the run carries a per-rep table worth showing (AC-FR-F-2-6).
    public var isStructured: Bool { runType.isStructured && !steps.isEmpty }

    // MARK: - Charts (T-056, T-057)

    /// What the x-axis measures. AC-FR-F-2-9 requires both.
    public enum ChartAxis: String, Sendable, CaseIterable {
        case distance
        case time
    }

    public struct ChartPoint: Sendable, Hashable {
        /// Metres or seconds, per the axis.
        public let x: Double
        public let y: Double
    }

    /// A pace series plus the target band around it, ready to plot.
    public struct PaceSeries: Sendable {
        public let axis: ChartAxis
        /// Rolling pace, in seconds per the runner's preferred unit.
        public let pace: [ChartPoint]
        /// The effective (grade-adjusted) target over the same axis.
        public let target: [ChartPoint]
        /// The on-target band, as the fast and slow edges around the target.
        public let bandFast: [ChartPoint]
        public let bandSlow: [ChartPoint]
        public let heartRate: [ChartPoint]
    }

    /// Builds the pace chart's series, downsampled to at most `maxPoints` (AC-FR-F-2-8).
    ///
    /// Every series is downsampled against the **same x-axis indices**, not independently.
    /// Downsampling each series on its own would pick different representative points for
    /// pace and for heart rate, and the two curves would then disagree about what happened at
    /// a given distance — a chart that lies subtly at every crossing.
    public func paceSeries(
        axis: ChartAxis = .distance,
        unit: UnitPreference,
        maxPoints: Int = 1_000
    ) -> PaceSeries {
        let judged = samples.enumerated().filter { $0.element.rollingPace != nil }
        let indices = downsampledIndices(
            of: judged.map(\.offset), axis: axis, maxPoints: maxPoints
        )

        let band = configuration?.band(for: runType) ?? PaceBand.standard(for: runType)

        func point(_ index: Int, _ value: Double?) -> ChartPoint? {
            guard let value, value.isFinite else { return nil }
            return ChartPoint(x: x(at: index, axis: axis), y: value)
        }

        return PaceSeries(
            axis: axis,
            pace: indices.compactMap { point($0, secondsPerUnit(samples[$0].rollingPace, unit)) },
            target: indices.compactMap {
                point($0, secondsPerUnit(samples[$0].effectiveTarget, unit))
            },
            // The band is a *percentage* of the target (ADR-003), so its edges track the
            // target curve rather than being parallel lines at a fixed offset.
            bandFast: indices.compactMap { index in
                guard let target = samples[index].effectiveTarget else { return nil }
                return point(
                    index,
                    secondsPerUnit(
                        Pace(secondsPerMetre: target.secondsPerMetre * (1 - band.fastNear)), unit
                    )
                )
            },
            bandSlow: indices.compactMap { index in
                guard let target = samples[index].effectiveTarget else { return nil }
                return point(
                    index,
                    secondsPerUnit(
                        Pace(secondsPerMetre: target.secondsPerMetre * (1 + band.slowNear)), unit
                    )
                )
            },
            heartRate: indices.compactMap { point($0, samples[$0].heartRate) }
        )
    }

    /// Elevation, with the raw and grade-adjusted targets where adjustment applied (T-057).
    public struct ElevationSeries: Sendable {
        public let elevation: [ChartPoint]
        /// The target before grade adjustment.
        public let rawTarget: [ChartPoint]
        /// The target actually judged against. Diverges from `rawTarget` on hills.
        public let adjustedTarget: [ChartPoint]
        /// False when there is nothing honest to draw — the overlay hides rather than
        /// rendering a flat line at zero.
        public let isAvailable: Bool
    }

    public func elevationSeries(
        axis: ChartAxis = .distance,
        unit: UnitPreference,
        maxPoints: Int = 1_000
    ) -> ElevationSeries {
        guard hasElevationData else {
            return ElevationSeries(
                elevation: [], rawTarget: [], adjustedTarget: [], isAvailable: false
            )
        }

        let withAltitude = samples.enumerated()
            .filter { $0.element.relativeAltitude?.isFinite == true }
        let indices = downsampledIndices(
            of: withAltitude.map(\.offset), axis: axis, maxPoints: maxPoints
        )

        return ElevationSeries(
            elevation: indices.compactMap { index in
                guard let altitude = samples[index].relativeAltitude else { return nil }
                return ChartPoint(x: x(at: index, axis: axis), y: altitude)
            },
            rawTarget: indices.compactMap { index in
                guard let value = secondsPerUnit(samples[index].rawTarget, unit) else { return nil }
                return ChartPoint(x: x(at: index, axis: axis), y: value)
            },
            adjustedTarget: indices.compactMap { index in
                guard let value = secondsPerUnit(samples[index].effectiveTarget, unit)
                else { return nil }
                return ChartPoint(x: x(at: index, axis: axis), y: value)
            },
            isAvailable: true
        )
    }

    // MARK: - Time in zone (T-058)

    public struct ZoneShare: Sendable, Hashable {
        public let zone: PaceZone
        public let seconds: TimeInterval
        /// 0…100.
        public let percentage: Double
    }

    /// Seconds and percentage per zone (AC-FR-F-2-4).
    ///
    /// Percentages are computed against the **sum of the spans**, not against `activeSeconds`.
    /// The two differ — the timeline covers every recorded tick including paused ones, which
    /// read as neutral — and dividing by `activeSeconds` would produce a column that sums to
    /// something other than 100%. Sharing one denominator with the numerators is what makes
    /// the total exact rather than approximately right.
    public func zoneShares() -> [ZoneShare] {
        let seconds = ZoneTimeline.timeInZone(zoneTimeline)
        let total = seconds.reduce(0, +)

        return PaceZone.allCases.map { zone in
            let value = zone.rawValue < seconds.count ? seconds[zone.rawValue] : 0
            return ZoneShare(
                zone: zone,
                seconds: value,
                percentage: total > 0 ? value / total * 100 : 0
            )
        }
    }

    // MARK: - Splits (T-059)

    public struct Split: Sendable, Hashable {
        /// 1-based, as displayed.
        public let number: Int
        public let distanceMetres: Double
        public let activeSeconds: TimeInterval
        public let averagePace: Pace?
        public let averageHeartRate: Double?
        public let elevationChangeMetres: Double
        /// True when the split is shorter than a full unit — the last one, usually
        /// (AC-FR-F-2-5).
        public let isPartial: Bool
    }

    /// Per-mile or per-kilometre splits, honouring the unit preference (AC-FR-F-2-5).
    ///
    /// Boundaries are crossed *between* samples, so each split's time is interpolated to the
    /// exact distance rather than snapped to the nearest 1 Hz sample. Snapping would put up to
    /// a second of error on every split and let the splits sum to something other than the
    /// run's total.
    public func splits(unit: UnitPreference) -> [Split] {
        guard samples.count >= 2 else { return [] }

        let unitMetres = unit.metresPerUnit
        let origin = samples[0].cumulativeDistance
        let totalDistance = (samples.last?.cumulativeDistance ?? origin) - origin
        guard totalDistance > 0 else { return [] }

        var result: [Split] = []
        var splitStartIndex = 0
        var splitStartTime = samples[0].timestamp
        var splitStartDistance = origin
        var boundary = unitMetres

        for index in 1..<samples.count {
            let travelled = samples[index].cumulativeDistance - origin
            guard travelled >= boundary else { continue }

            let previous = samples[index - 1]
            let current = samples[index]
            let previousTravelled = previous.cumulativeDistance - origin

            // Linear interpolation to the exact boundary.
            let span = travelled - previousTravelled
            let fraction = span > 0 ? (boundary - previousTravelled) / span : 0
            let crossingTime = previous.timestamp
                + (current.timestamp - previous.timestamp) * fraction

            result.append(makeSplit(
                number: result.count + 1,
                fromIndex: splitStartIndex,
                toIndex: index,
                distance: boundary - (splitStartDistance - origin),
                seconds: crossingTime - splitStartTime,
                isPartial: false
            ))

            splitStartIndex = index
            splitStartTime = crossingTime
            splitStartDistance = origin + boundary
            boundary += unitMetres
        }

        // Whatever is left over is a partial split, labelled as such rather than presented as
        // a suspiciously fast or slow full one.
        let remaining = totalDistance - (splitStartDistance - origin)
        if remaining > 1 {
            result.append(makeSplit(
                number: result.count + 1,
                fromIndex: splitStartIndex,
                toIndex: samples.count - 1,
                distance: remaining,
                seconds: (samples.last?.timestamp ?? splitStartTime) - splitStartTime,
                isPartial: true
            ))
        }
        return result
    }

    private func makeSplit(
        number: Int,
        fromIndex: Int,
        toIndex: Int,
        distance: Double,
        seconds: TimeInterval,
        isPartial: Bool
    ) -> Split {
        let slice = samples[fromIndex...min(toIndex, samples.count - 1)]
        let heartRates = slice.compactMap(\.heartRate).filter { $0.isFinite && $0 > 0 }
        let altitudes = slice.compactMap(\.relativeAltitude).filter(\.isFinite)

        return Split(
            number: number,
            distanceMetres: distance,
            activeSeconds: seconds,
            averagePace: Pace(distanceMetres: distance, seconds: seconds),
            averageHeartRate: heartRates.isEmpty
                ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
            elevationChangeMetres: (altitudes.last ?? 0) - (altitudes.first ?? 0),
            isPartial: isPartial
        )
    }

    /// The per-rep table for a structured workout (AC-FR-F-2-6).
    ///
    /// Reads the stored `StepSummary` rows rather than re-segmenting the sample series. Those
    /// were recorded live, boundary by boundary, including any manual advance or undo — a
    /// re-segmentation here would be a second opinion about where a rep started.
    public struct RepRow: Sendable, Hashable {
        public let step: StepSummary
        /// `WORK 3/4`, or `WARM UP` for an unrepeated step.
        public let label: String
        /// True when the step did not reach its prescribed goal — the run ended mid-rep.
        public let isPartial: Bool
    }

    public func repRows() -> [RepRow] {
        let resolved = plan?.resolvedSteps() ?? []

        return steps.map { step in
            let goalDistance = resolved.first { $0.index == step.index }?.goal.distanceMetres
            return RepRow(
                step: step,
                // `repIndex` is one-based already (`WorkoutPlan.flatten` numbers from 1), so
                // nothing is added to it. Adding 1 here produced "WORK 5/4" for a four-rep
                // workout — and the same mistake was live in the watch's interval header.
                label: step.repCount > 1
                    ? "\(Self.stepKindLabel(step.kind)) \(step.repIndex)/\(step.repCount)"
                    : Self.stepKindLabel(step.kind),
                // 1 % tolerance: a closed rep ends on the first tick at or past its goal, so
                // it overshoots slightly rather than landing exactly. Only a step that fell
                // meaningfully *short* was cut off.
                isPartial: goalDistance.map { step.distanceMetres < $0 * 0.99 } ?? false
            )
        }
    }

    /// Display names for step kinds.
    ///
    /// `rawValue.uppercased()` is not good enough — it renders `warmup` as "WARMUP". `Core`
    /// ships no strings (NFR-23), so each tier owns its own wording; this mirrors the watch's
    /// `RunStrings.stepKind`.
    static func stepKindLabel(_ kind: StepKind) -> String {
        switch kind {
        case .warmup: return "WARM UP"
        case .work: return "WORK"
        case .recovery: return "RECOVERY"
        case .cooldown: return "COOL DOWN"
        }
    }

    // MARK: - Route (T-060)

    public struct RouteSegment: Sendable, Hashable {
        public let from: RoutePoint
        public let to: RoutePoint
        public let zone: PaceZone
    }

    /// The route split into zone-coloured segments (AC-FR-F-2-7).
    ///
    /// Zone comes from the timeline by timestamp rather than from the nearest sample: the
    /// timeline is run-length encoded and authoritative, and a route point's timestamp may
    /// fall between samples.
    public func routeSegments() -> [RouteSegment] {
        guard hasRoute else { return [] }

        return zip(route, route.dropFirst()).map { from, to in
            RouteSegment(from: from, to: to, zone: zone(atSeconds: from.timestamp))
        }
    }

    func zone(atSeconds seconds: TimeInterval) -> PaceZone {
        zoneTimeline.first { seconds >= $0.startSeconds && seconds < $0.endSeconds }?.zone
            ?? .neutral
    }

    // MARK: - Private helpers

    /// Chooses which sample indices to plot, via LTTB over the chosen axis.
    private func downsampledIndices(
        of candidates: [Int],
        axis: ChartAxis,
        maxPoints: Int
    ) -> [Int] {
        guard candidates.count > maxPoints else { return candidates }

        let xs = candidates.map { x(at: $0, axis: axis) }
        // Downsampled on pace, because that is the series whose peaks a runner reads. The
        // other series follow the same indices so the curves stay mutually consistent.
        let ys = candidates.map { samples[$0].rollingPace?.secondsPerMetre ?? 0 }

        return Downsample.largestTriangleThreeBuckets(x: xs, y: ys, threshold: maxPoints)
            .map { candidates[$0] }
    }

    private func x(at index: Int, axis: ChartAxis) -> Double {
        switch axis {
        case .distance:
            return samples[index].cumulativeDistance - (samples.first?.cumulativeDistance ?? 0)
        case .time:
            return samples[index].timestamp - (samples.first?.timestamp ?? 0)
        }
    }

    /// Pace expressed as seconds per preferred unit — what a chart axis shows.
    private func secondsPerUnit(_ pace: Pace?, _ unit: UnitPreference) -> Double? {
        guard let pace, pace.isValid else { return nil }
        return pace.secondsPerMetre * unit.metresPerUnit
    }
}
