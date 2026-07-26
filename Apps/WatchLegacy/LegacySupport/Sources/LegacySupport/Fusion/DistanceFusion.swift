import Foundation
import ORModels

/// One source's raw distance reading at a tick — Legacy tier.
///
/// `nil`-versus-zero matters here for the same reason it does on Modern: a `CMPedometer` that
/// has not started and one reporting no movement are indistinguishable if both are modelled as
/// `0`, and the fusion layer would then switch to a source that is silently flat.
public struct DistanceReading: Sendable, Hashable {
    public let source: DistanceSource
    /// Raw cumulative distance from this source alone, in metres.
    public let cumulativeDistance: Double
    /// Whether this source currently has a usable value at all — `false` means "no fix" or
    /// "sensor absent", never "reads zero".
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

/// Fuses up to three distance sources into one monotonic figure — Legacy tier (T-063,
/// design.md §8.2).
///
/// **This is a deliberate duplicate of the Modern tier's `DistanceFusion`, not a shared file**
/// (AC-FR-K-1-4, ADR-002). The algorithm is intentionally identical, arithmetic included,
/// because AC-FR-K-1-2 requires both tiers to produce output matching the *same* committed
/// goldens — and a fused distance computed by a different sequence of operations would not
/// merely be approximately equal, it would drift, and the drift would surface exactly as the
/// failure mode this wave exists to prevent: two watches disagreeing about the same run.
///
/// The operation order below is therefore load-bearing and must not be "cleaned up":
/// `raw + offset`, then a `max` floor, then a refresh of every available source's offset. Any
/// reassociation changes the last bits of the result and breaks exact golden equality.
///
/// ## The algorithm, and the two bugs it exists to avoid
///
/// Priority order — HealthKit, then CoreLocation, then the pedometer — is fixed by design.md
/// §8.2. Each source carries an offset such that `fused = raw + offset`, and **every** offset
/// is refreshed on every tick its source is available, not only on ticks where it is active.
///
/// Two failure modes were found on the Modern tier in Wave 2 and are avoided here by
/// construction rather than rediscovered:
///
/// - Re-anchoring the *first* source to acquire would set an offset of `0 - raw`, forcing the
///   run's opening reading to 0 m and permanently discarding distance already accumulated
///   before the first fix. A first acquisition is a baseline, not a switch.
/// - Refreshing only the active source's offset freezes cumulative distance for an entire run
///   when a source alternates availability every tick — which is precisely what HealthKit's
///   live builder does, since it publishes on its own irregular schedule.
///
/// ## Series 3 specifics
///
/// Series 3 has no always-on display, which does not affect fusion, and its GPS is
/// meaningfully less accurate than Series 6+. That makes the pedometer fallback *more* load
/// bearing here than on Modern, not less — but it changes no logic: the accuracy threshold is
/// applied upstream by the adapter, and arrives here as `isAvailable`.
public struct DistanceFusion: Sendable {

    /// Fixed by design.md §8.2 — a documented product decision, not a tunable.
    private static let priorityOrder: [DistanceSource] = [.healthKit, .location, .pedometer]

    /// The switch-jump budget. Fixed at 5 m by specification, deliberately *not* routed
    /// through `PaceEngineConfiguration`: NFR-21 governs tunables — values a runner or
    /// deployment might legitimately vary — and this is a correctness bound, in the same
    /// category as `priorityOrder`. Exposed only so tests can name it rather than restate it.
    public static let maxSwitchJumpMetres: Double = 5

    private var offsets: [DistanceSource: Double] = [:]
    private var lastFused: Double = 0
    private var lastActiveSource: DistanceSource?

    public init() {}

    /// Selects the highest-priority available reading and folds it into the running total.
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
            // Nothing usable this tick. Hold the last value rather than inventing one —
            // whether prolonged unavailability counts as degraded is RunEngine's call, made
            // from the distance source it is told about, not this type's.
            return FusedDistance(
                cumulativeDistance: lastFused,
                activeSource: lastActiveSource ?? .location
            )
        }

        let raw = candidate.cumulativeDistance
        var fused: Double

        if let previousSource = lastActiveSource {
            // A missing offset means a source never yet seen available, so there is no basis
            // for a delta and a 0 m jump is the safe reading.
            fused = raw + (offsets[candidate.source] ?? (lastFused - raw))

            // A stale offset — from a source that was away while the total moved on — can
            // compute an arbitrarily large jump. Refuse it and re-anchor to the settled total.
            if previousSource != candidate.source,
               abs(fused - lastFused) > DistanceFusion.maxSwitchJumpMetres {
                fused = lastFused
            }
        } else {
            // First acquisition establishes the baseline. See the class note above.
            fused = raw
        }

        // The floor makes monotonicity unconditional: a source that regresses internally (a
        // GPS correction snapping backwards) cannot pull the fused output down. Core never
        // learns which source produced a sample, so a regression would read as running
        // backwards.
        lastFused = max(fused, lastFused)
        lastActiveSource = candidate.source

        // Re-anchor every available source against the settled total, so any of them can take
        // over next tick without losing that tick's movement. Unavailable sources are skipped:
        // their reading means "no fix", and anchoring to it would bake in a fictional position.
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
