import Foundation
import ORIntervals
import ORModels
import ORStats

/// Builds the `RunEnvelope` this tier uploads — Legacy tier (T-071, FR-E-1).
///
/// **The requirement is that the phone cannot tell the difference except `deviceTier`**
/// (T-071's acceptance criterion). So this produces the identical wire structure the Modern tier
/// does, from the identical `Core` types, at the identical schema version. Nothing about the payload
/// is Legacy-shaped: the samples are `PackedSamples`, the timeline is run-length encoded, the summary
/// comes from `RunSummaryBuilder`, and the per-step table comes from `StepSummaryAccumulator` — all
/// Core, all shared.
///
/// A deliberate duplicate of the Modern tier's builder (AC-FR-K-1-4). The duplication is thin because
/// almost everything it needs already exists in Core; what is duplicated is the assembly, not the
/// content.
///
/// `deviceTier: .legacy` is the one intended difference, and it is not cosmetic — the phone records
/// it so a run's provenance is known, and `RunAnalysis` uses the degradation flags rather than the
/// tier to decide what to render. A future consumer branching on `deviceTier` to render *less* for
/// Legacy runs would be a bug; the flag is for provenance, not for capability inference.
public enum RunEnvelopeBuilder {

    /// Assembles an envelope from a completed run.
    public static func build(
        runID: UUID,
        startedAt: Date,
        endedAt: Date,
        plan: WorkoutPlan,
        profile: RunnerProfile,
        config: PaceEngineConfiguration,
        healthKitWorkoutUUID: UUID?,
        samples: [RunSample],
        zones: [PaceZone],
        steps: [StepSummary],
        activeSeconds: TimeInterval,
        route: [RoutePoint]?,
        degradations: [DegradationFlag],
        appVersion: String
    ) -> RunEnvelope {
        let timeline = ZoneTimeline.encode(zones: zones)

        return RunEnvelope(
            runID: runID,
            // The only field that differs from a Modern-produced envelope.
            deviceTier: .legacy,
            appVersion: appVersion,
            startedAt: startedAt,
            endedAt: endedAt,
            runType: plan.runType,
            plan: plan,
            profileSnapshot: profile,
            configSnapshot: config,
            healthKitWorkoutUUID: healthKitWorkoutUUID,
            summary: RunSummaryBuilder.build(
                samples: samples,
                activeSeconds: activeSeconds,
                zoneTimeline: timeline,
                config: config.stats
            ),
            steps: steps,
            zoneTimeline: timeline,
            samples: PackedSamples(samples: samples),
            route: route,
            degradations: degradations
        )
    }
}
