import Foundation
import ORModels

/// One source's raw distance reading at a tick.
///
/// Each source is independently monotonic within itself — a real GPS track,
/// HealthKit's fused estimate, and a pedometer's step-based distance each only
/// increase over time. What is not guaranteed is agreement *between* sources, or
/// even continuous availability of any one of them.
public struct DistanceReading: Sendable, Hashable {
    public let source: DistanceSource
    /// Raw cumulative distance from this source alone, in metres.
    public let cumulativeDistance: Double
    /// Whether this source currently has a usable value at all — `false` means
    /// "no fix" or "sensor absent", not "reads zero".
    public let isAvailable: Bool

    public init(source: DistanceSource, cumulativeDistance: Double, isAvailable: Bool) {
        self.source = source
        self.cumulativeDistance = cumulativeDistance
        self.isAvailable = isAvailable
    }
}

/// The fused result for one tick.
public struct FusedDistance: Sendable, Hashable {
    public let cumulativeDistance: Double
    public let activeSource: DistanceSource
}

/// Fuses up to three distance sources into one monotonic figure (T-035,
/// design.md §8.2).
///
/// Priority order — HealthKit, then CoreLocation, then the pedometer — matches
/// design.md exactly: HealthKit's live workout builder is Apple's own fused
/// estimate and the best available; CoreLocation is required for the route and
/// used when HealthKit lags; the pedometer is the fallback for GPS loss (DEG-1)
/// and the only source indoors (DEG-10).
///
/// Each source carries an **offset** such that `fused = raw + offset`, and every
/// offset is refreshed on every tick the source is available — not only on the ticks
/// where it happens to be the active one. That last detail is the whole design.
///
/// The obvious implementation, re-anchoring only the source being switched *to*, has
/// a failure mode that looks fine in a single-switch test and is catastrophic in
/// practice: anchoring the new source to the previous fused value discards the
/// distance covered during the very tick of the switch. One switch loses a metre or
/// two. A source that alternates availability every tick — which is exactly what
/// HealthKit's builder does, since it publishes on its own irregular schedule —
/// re-anchors on every tick and freezes cumulative distance at its opening value for
/// the entire run. Keeping every offset fresh means whichever source becomes active
/// continues from where the fused total actually is.
///
/// Two invariants then hold unconditionally, not just in the common case:
///
/// - **Monotonic non-decreasing.** `Core` never learns which source produced a
///   sample, so a fused distance that ever regresses would read as the runner
///   running backwards. Enforced with a hard floor at the previous output.
/// - **No jump greater than `maxSwitchJumpMetres` on a source switch.** A source
///   whose offset is stale — it has been unavailable for a while, so the fused total
///   moved on without it — can compute a large jump. When it would exceed the
///   budget, the switch re-anchors to the current fused value instead, taking a 0 m
///   jump rather than a wrong one.
///
/// **What fusion cannot do.** Exact tracking requires at least one tick on which two
/// sources are both readable — otherwise nothing observes how far the runner moved
/// between one source's last reading and a different source's next one, and any figure
/// claiming otherwise is double-counting. Given a choice, this under-reports rather
/// than over-reports: an inflated distance inflates every pace the runner is judged
/// against, which is the worse error. In practice the case never arises, because
/// `CMPedometer` keeps reporting through GPS loss and through HealthKit's gaps.
///
/// The first source to become active is the one case deliberately outside the bound:
/// with no previous fused value to stay continuous with, its own cumulative reading
/// *is* the fused total. A run whose first usable fix arrives late, with distance
/// already accumulated, starts from that distance rather than from 0 — an initial
/// baseline, not a switch.
///
/// Pure and framework-free: it never touches HealthKit, CoreLocation, or
/// CoreMotion directly, which is what makes it testable with `swift test` alone.
public struct DistanceFusion: Sendable {

    /// Fixed by design.md §8.2. Not configurable — this is a documented product
    /// decision, not a tunable.
    private static let priorityOrder: [DistanceSource] = [.healthKit, .location, .pedometer]

    /// The switch-jump budget from T-035's acceptance criterion.
    ///
    /// Not routed through `PaceEngineConfiguration` deliberately, and this is the
    /// judgement worth recording: NFR-21 governs *tunables* — values a runner, a
    /// profile, or a deployment might legitimately vary. This is a correctness bound
    /// the specification fixes at 5 m, in the same category as `priorityOrder`.
    /// Making it configurable would imply a supported 50 m setting, which there is
    /// not. Exposed rather than private only so the test can name it instead of
    /// restating the number.
    public static let maxSwitchJumpMetres: Double = 5

    private var offsets: [DistanceSource: Double] = [:]
    private var lastFused: Double = 0
    private var lastActiveSource: DistanceSource?

    public init() {}

    /// Selects the highest-priority available reading and folds it into the
    /// running fused total.
    public mutating func fuse(
        healthKit: DistanceReading?,
        location: DistanceReading?,
        pedometer: DistanceReading?
    ) -> FusedDistance {
        let readings: [DistanceSource: DistanceReading] = [
            .healthKit: healthKit, .location: location, .pedometer: pedometer,
        ].compactMapValues { $0 }

        guard let candidate = DistanceFusion.priorityOrder
            .compactMap({ readings[$0] })
            .first(where: { $0.isAvailable && $0.cumulativeDistance.isFinite })
        else {
            // Nothing usable this tick. Hold the last fused value rather than
            // inventing one — the caller (RunEngine, via EngineInput) is what
            // decides whether prolonged unavailability counts as degraded.
            return FusedDistance(
                cumulativeDistance: lastFused,
                activeSource: lastActiveSource ?? .location
            )
        }

        let raw = candidate.cumulativeDistance
        var fused: Double

        if let previousSource = lastActiveSource {
            // An offset is missing only for a source never yet seen available, in
            // which case there is no basis for a delta and a 0 m jump is the safe
            // reading.
            fused = raw + (offsets[candidate.source] ?? (lastFused - raw))

            // A stale offset — from a source that was away while the total moved on —
            // can compute an arbitrarily large jump. Refuse it and re-anchor.
            if previousSource != candidate.source,
               abs(fused - lastFused) > DistanceFusion.maxSwitchJumpMetres {
                fused = lastFused
            }
        } else {
            // First source ever to go active establishes the baseline instead of
            // being re-anchored to it. Anchoring here would set an offset of
            // `0 - raw`, forcing the run's opening fused reading to 0 m and
            // permanently discarding whatever distance that source had already
            // accumulated. A source acquired for the first time reports distance
            // covered since the run began, so its raw value *is* the fused total.
            fused = raw
        }

        // The floor is what makes monotonicity unconditional: even a source that
        // regresses internally (a GPS correction snapping backwards, say) cannot
        // pull the fused output down.
        lastFused = max(fused, lastFused)
        lastActiveSource = candidate.source

        // Re-anchor *every* available source against the settled total, so any of
        // them can take over on the next tick without losing that tick's movement.
        // Sources flagged unavailable are skipped: their reading means "no fix", and
        // anchoring to it would bake a fictional position into the offset.
        for (source, reading) in readings
        where reading.isAvailable && reading.cumulativeDistance.isFinite {
            offsets[source] = lastFused - reading.cumulativeDistance
        }

        return FusedDistance(cumulativeDistance: lastFused, activeSource: candidate.source)
    }

    public mutating func reset() {
        offsets.removeAll(keepingCapacity: true)
        lastFused = 0
        lastActiveSource = nil
    }
}
