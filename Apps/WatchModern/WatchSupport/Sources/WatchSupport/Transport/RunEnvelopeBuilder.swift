import Foundation
import ORModels
import ORPace
import ORStats

/// Turns a finished run into the payload the phone ingests (T-048, design.md §9.1).
///
/// The composition point for everything the phone will later analyse, and therefore the
/// one place where a dropped field means a permanently incomplete history. Every
/// derivation it performs is delegated to `Core` — `RunSummaryBuilder` for the totals,
/// `ZoneTimeline.encode` for the run-length-encoded zones, `PackedSamples` for the
/// columnar blob, `StepSummaryAccumulator` for the per-rep table — so this type contains
/// no arithmetic of its own and cannot disagree with the engine that produced the run.
///
/// **The profile and configuration are snapshotted, not referenced** (design.md §9.1). A
/// run analysed six months later must be interpretable against the targets that were
/// actually in force, so the chart's shaded band redraws from the snapshot rather than
/// from today's settings.
public enum RunEnvelopeBuilder {

    /// Builds an envelope from an engine output stream.
    ///
    /// Taking `[EngineOutput]` rather than `[RunSample]` is what makes the whole pipeline
    /// testable against Wave 1's recorded fixtures: `FixtureReplay.run` produces exactly
    /// this, so a golden trace can be pushed through sync, storage, and every chart and
    /// checked against ground truth already known to be right — rather than against a
    /// synthetic envelope invented to match whatever the code happens to do.
    public static func build(
        runID: UUID = UUID(),
        outputs: [EngineOutput],
        startedAt: Date,
        runType: RunType,
        plan: WorkoutPlan?,
        profile: RunnerProfile,
        configuration: PaceEngineConfiguration = .default,
        route: [RoutePoint]? = nil,
        healthKitWorkoutUUID: UUID? = nil,
        deviceTier: DeviceTier = .modern,
        appVersion: String
    ) -> RunEnvelope {
        let samples = outputs.map(\.sample)
        let activeSeconds = outputs.last?.activeElapsed ?? 0

        let zoneTimeline = ZoneTimeline.encode(
            zones: outputs.map(\.zone),
            startSeconds: samples.first?.timestamp ?? 0,
            intervalSeconds: configuration.capture.sampleIntervalSeconds
        )

        var steps = StepSummaryAccumulator()
        for output in outputs { steps.ingest(output) }
        steps.finish(with: outputs.last)

        return RunEnvelope(
            runID: runID,
            deviceTier: deviceTier,
            appVersion: appVersion,
            startedAt: startedAt,
            // Derived from the run's own active clock rather than read from the wall
            // clock at build time: a build that happens minutes after the run ends —
            // because the app was backgrounded — must not stretch the run's duration.
            endedAt: startedAt.addingTimeInterval(samples.last?.timestamp ?? activeSeconds),
            runType: runType,
            plan: plan,
            profileSnapshot: profile,
            configSnapshot: configuration,
            healthKitWorkoutUUID: healthKitWorkoutUUID,
            summary: RunSummaryBuilder.build(
                samples: samples,
                activeSeconds: activeSeconds,
                zoneTimeline: zoneTimeline,
                config: configuration.stats
            ),
            steps: steps.completed,
            zoneTimeline: zoneTimeline,
            samples: PackedSamples(
                samples: samples,
                intervalSeconds: configuration.capture.sampleIntervalSeconds
            ),
            // An empty route is normalised to `nil` so "indoors, no route" and "outdoors
            // but the array happened to be empty" cannot be told apart downstream — the
            // map hides on `nil` (AC-FR-F-2-7), and an empty array would render a map of
            // nothing.
            route: (route?.isEmpty ?? true) ? nil : route,
            degradations: Array(outputs.last?.degradations ?? []).sorted { $0.rawValue < $1.rawValue }
        )
    }
}
