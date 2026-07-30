import Foundation
import ORModels
import ORPace
import ORStats

/// Turns a finished standalone run into the envelope the hub ingests (S-033, S-034).
///
/// The phone's analogue of `WatchSupport.RunEnvelopeBuilder`, and it delegates the same
/// way: `RunSummaryBuilder` for the totals, `ZoneTimeline.encode` for the zones,
/// `PackedSamples` for the blob, `StepSummaryAccumulator` for the per-rep table. No
/// arithmetic of its own, so a standalone run's numbers are derived by exactly the code a
/// watch run's are and the two cannot disagree.
///
/// The only thing it adds is `StandaloneRunFacts`, which is the whole of what makes a
/// standalone run distinguishable in the store — and the reason FR-S-E-1's "no new store,
/// no new ingest" is achievable: the run goes through `RunLibrary.ingest` unchanged.
public enum StandaloneWorkoutComposer {

    public static func build(
        runID: UUID,
        outputs: [EngineOutput],
        telemetry: MotionTelemetry,
        startedAt: Date,
        runType: RunType,
        plan: WorkoutPlan?,
        profile: RunnerProfile,
        configuration: PaceEngineConfiguration = .default,
        activity: RunActivityKind,
        route: [RoutePoint]?,
        healthKitWorkoutUUID: UUID?,
        carryPosition: CarryPosition,
        averageCadenceStepsPerMinute: Double?,
        estimatedSpans: [StandaloneRunFacts.EstimatedSpan],
        appVersion: String
    ) -> RunEnvelope {
        // DEG-S-4 enforced here rather than trusted upstream. This tier has no heart-rate
        // sensor, the feed always reports `nil`, and AC-FR-S-A-4-3 forbids writing or
        // synthesising a reading — so a heart rate arriving in an `EngineOutput` on this
        // path is a bug somewhere, and the safe response is to drop it rather than to
        // persist a number whose origin nobody can account for.
        //
        // It is not hypothetical. Wave 1's recorded fixtures carry heart rate, because
        // they were recorded on a watch, and composing one of them as a standalone run
        // produced a phone-only run with a full HR series before this line existed. The
        // day this tier gains a real sensor — a paired chest strap, say — this is the one
        // place that changes.
        let outputs = outputs.map(Self.withoutHeartRate)
        let samples = outputs.map(\.sample)
        let activeSeconds = outputs.last?.activeElapsed ?? 0

        let zoneTimeline = ZoneTimeline.encode(
            zones: outputs.map(\.zone),
            startSeconds: samples.first?.timestamp ?? 0,
            intervalSeconds: configuration.capture.sampleIntervalSeconds)

        var steps = StepSummaryAccumulator()
        for output in outputs { steps.ingest(output) }
        steps.finish(with: outputs.last)

        let facts = StandaloneRunFacts(
            carryPosition: carryPosition,
            measuredMetres: telemetry.measuredMetres,
            estimatedMetres: telemetry.estimatedMetres,
            stepCount: telemetry.stepCount,
            averageCadenceStepsPerMinute: averageCadenceStepsPerMinute,
            calibration: telemetry.calibration,
            flags: telemetry.flags,
            estimatedSpans: estimatedSpans)

        return RunEnvelope(
            runID: runID,
            deviceTier: .phoneStandalone,
            appVersion: appVersion,
            startedAt: startedAt,
            // From the run's own clock, not the wall clock at build time: an envelope
            // composed minutes after the run ended — because the app was backgrounded when
            // the runner pressed End — must not stretch the run's duration.
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
                config: configuration.stats),
            steps: steps.completed,
            zoneTimeline: zoneTimeline,
            samples: PackedSamples(
                samples: samples,
                intervalSeconds: configuration.capture.sampleIntervalSeconds),
            route: (route?.isEmpty ?? true) ? nil : route,
            degradations: degradations(
                outputs: outputs, telemetry: telemetry, activity: activity),
            standalone: facts)
    }

    /// One output with every heart-rate field cleared, including the one inside its sample.
    ///
    /// Both have to be cleared: `RunSummaryBuilder` reads the sample series and
    /// `StepSummaryAccumulator` reads the output, so clearing either alone leaves a
    /// standalone run with a heart rate in half its tables.
    private static func withoutHeartRate(_ output: EngineOutput) -> EngineOutput {
        guard output.heartRate != nil || output.sample.heartRate != nil else { return output }
        let sample = output.sample
        return EngineOutput(
            zone: output.zone,
            rollingPace: output.rollingPace,
            averagePace: output.averagePace,
            rawTarget: output.rawTarget,
            effectiveTarget: output.effectiveTarget,
            gradeFactor: output.gradeFactor,
            smoothedGrade: output.smoothedGrade,
            isGradeSignificant: output.isGradeSignificant,
            isGradeAvailable: output.isGradeAvailable,
            isGPSDegraded: output.isGPSDegraded,
            isStationary: output.isStationary,
            isSettling: output.isSettling,
            progress: output.progress,
            activeElapsed: output.activeElapsed,
            cumulativeDistance: output.cumulativeDistance,
            heartRate: nil,
            step: output.step,
            stepTransition: output.stepTransition,
            alert: output.alert,
            degradations: output.degradations,
            sample: RunSample(
                timestamp: sample.timestamp,
                cumulativeDistance: sample.cumulativeDistance,
                rollingPace: sample.rollingPace,
                heartRate: nil,
                relativeAltitude: sample.relativeAltitude,
                smoothedGrade: sample.smoothedGrade,
                gradeFactor: sample.gradeFactor,
                rawTarget: sample.rawTarget,
                effectiveTarget: sample.effectiveTarget,
                zone: sample.zone))
    }

    /// The engine's own degradations, plus the ones only this tier can observe.
    ///
    /// `DegradationFlag` is `Core`'s vocabulary and is deliberately not extended for the
    /// standalone-specific conditions — those are `MotionFlag`s and travel in
    /// `StandaloneRunFacts`, where they keep their own wording. What is mapped here is the
    /// one overlap: a run that fell back to the motion model *is* a GPS-degraded run in
    /// Core's sense, and the run list's existing degraded-run treatment should say so
    /// without knowing what a step-length model is.
    private static func degradations(
        outputs: [EngineOutput], telemetry: MotionTelemetry, activity: RunActivityKind
    ) -> [DegradationFlag] {
        var flags = outputs.last?.degradations ?? []
        if telemetry.flags.contains(.distanceEstimated) { flags.insert(.gpsDegraded) }
        // DEG-S-6 / CON-S-8. `RunEngine` infers `.indoorRun` from `.pedometer` distance
        // with no fix, which this tier never reports — it does not use CMPedometer at all
        // (ADR-S-06 amendment 1). So the flag is added here, where the activity is known,
        // rather than by misreporting the source to trigger an inference.
        if activity == .indoorRun { flags.insert(.indoorRun) }
        return Array(flags).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - HealthKit seam

/// A step boundary worth recording in the saved workout (AC-FR-S-A-4-2).
public struct WorkoutEventMark: Sendable, Hashable {
    /// Session-relative seconds.
    public let atSeconds: TimeInterval
    public let kind: StepKind
    public let repIndex: Int
    public let repCount: Int

    public init(atSeconds: TimeInterval, kind: StepKind, repIndex: Int, repCount: Int) {
        self.atSeconds = atSeconds
        self.kind = kind
        self.repIndex = repIndex
        self.repCount = repCount
    }
}

/// Everything the run controller needs to write a workout to HealthKit.
///
/// Abstracted for the same reason `WorkoutBackend` is on the watch: the orchestration is
/// testable and the framework call is not. It is a *smaller* surface than the watch's
/// because there is no live session to start, pause or resume at this deployment floor
/// (CON-S-2, ADR-S-07) — the whole interaction is "here is a finished run, save it", which
/// is exactly what `HKWorkoutBuilder` offers and is why the capability contract calls this
/// `.builderOnly` rather than reporting no workout support at all.
public protocol StandaloneWorkoutWriting: Sendable {
    /// Requests write authorization. AC-FR-S-A-4-4: denial is a handled state, not an
    /// error — the run is still recorded locally and the app says Health is not being
    /// written.
    func requestAuthorization() async -> AuthorizationOutcome

    /// Saves the workout and returns its identifier, or `nil` when authorization was
    /// denied.
    ///
    /// - Note: no heart-rate parameter exists, anywhere, on purpose. AC-FR-S-A-4-3 forbids
    ///   writing a heart-rate sample this tier does not have and forbids synthesising one
    ///   from pace. A protocol with no way to express one cannot be made to (DEG-S-4).
    func save(
        startedAt: Date,
        endedAt: Date,
        distanceMetres: Double,
        activeSeconds: TimeInterval,
        route: [RoutePoint],
        events: [WorkoutEventMark]
    ) async throws -> UUID?
}

/// Whether HealthKit authorization was granted, and what that means for this run.
///
/// Declared here rather than shared with the watch's identical enum because that one lives
/// in `WatchSupport` and this package must not reach into another tier — the same
/// duplication ADR-002 sanctions between the watch tiers, for the same reason.
public enum AuthorizationOutcome: Sendable, Hashable {
    case authorized
    /// The run proceeds, recorded locally, with no HealthKit write.
    case denied
}
