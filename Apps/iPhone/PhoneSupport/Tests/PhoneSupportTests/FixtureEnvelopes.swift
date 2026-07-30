import Foundation
import ORModels
import ORPace
import ORStats
import XCTest

@testable import PhoneSupport

/// Builds real `RunEnvelope`s by replaying Wave 1's recorded fixtures.
///
/// **Why not hand-written envelopes.** A synthetic envelope encodes whatever the author
/// believed the code should produce, so a chart fed by one can only ever confirm the author's
/// belief. The seven committed fixtures are known-good traces whose engine output is pinned by
/// golden files — they already caught real bugs in Waves 1 and 2 — so pushing them through
/// sync, storage, and analysis checks each screen against ground truth that exists
/// independently of this wave's code.
///
/// This deliberately duplicates `WatchSupport.RunEnvelopeBuilder`'s composition rather than
/// importing it: `PhoneSupport` must not depend on the watch tier (ADR-002 keeps the two
/// app tiers apart), and the derivations being composed all live in `Core`, so both sides
/// call the same `RunSummaryBuilder`, `ZoneTimeline`, and `PackedSamples`. What differs is
/// only the argument plumbing.
enum FixtureEnvelopes {

    /// A fixture replayed into an envelope.
    struct Built {
        let envelope: RunEnvelope
        let outputs: [EngineOutput]
    }

    static let allNames = [
        "tempo-5mi-rolling",
        "intervals-4x1000",
        "hilly-10k",
        "gps-dropout-tunnel",
        "treadmill-indoor",
        "stop-start-traffic",
        "boundary-oscillation",
    ]

    /// Replays a named fixture. Throws rather than returning `nil` so a missing fixture fails
    /// the test loudly instead of silently reducing coverage.
    static func build(
        _ name: String,
        runID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        route: [RoutePoint]? = nil,
        healthKitWorkoutUUID: UUID? = nil
    ) throws -> Built {
        let fixture = try XCTUnwrap(
            FixtureGenerator.fixture(named: name), "unknown fixture \(name)"
        )
        let replay = FixtureReplay.run(fixture)
        let configuration = PaceEngineConfiguration.default
        let samples = replay.outputs.map(\.sample)

        let zoneTimeline = ZoneTimeline.encode(
            zones: replay.outputs.map(\.zone),
            startSeconds: samples.first?.timestamp ?? 0,
            intervalSeconds: configuration.capture.sampleIntervalSeconds
        )

        var steps = StepSummaryAccumulator()
        for output in replay.outputs { steps.ingest(output) }
        steps.finish(with: replay.outputs.last)

        let activeSeconds = replay.outputs.last?.activeElapsed ?? 0

        let envelope = RunEnvelope(
            runID: runID,
            deviceTier: .modern,
            appVersion: "1.0-test",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(samples.last?.timestamp ?? activeSeconds),
            runType: fixture.runType,
            plan: fixture.plan,
            profileSnapshot: fixture.profile,
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
            route: route,
            degradations: Array(replay.outputs.last?.degradations ?? [])
                .sorted { $0.rawValue < $1.rawValue }
        )

        return Built(envelope: envelope, outputs: replay.outputs)
    }

    /// The compressed bytes a transfer would carry.
    static func payload(_ name: String, runID: UUID = UUID()) throws -> Data {
        try SyncPayloadCodec.encode(build(name, runID: runID).envelope)
    }

    // MARK: - Standalone (S-034)

    /// The same fixture, composed as a **standalone** run.
    ///
    /// Deliberately built by replaying one of Wave 1's recorded fixtures and handing the
    /// result to `StandaloneWorkoutComposer` — the production composer, not a test one — so
    /// that "a standalone run looks the same in the list as a watch run" is checked against
    /// a run whose engine output is already pinned by a golden file. Writing a bespoke
    /// standalone envelope instead would only ever confirm what its author believed a
    /// standalone envelope looks like.
    ///
    /// The telemetry is supplied rather than derived because there is no motion trace
    /// behind these fixtures: they are engine fixtures. What is being tested here is the
    /// *hub* path — ingest, list, detail, aggregates — which takes the facts as given. The
    /// facts themselves are produced by `MotionPipeline` and are tested against real
    /// recorded motion in the app target, where both sides of the boundary are visible.
    static func standalone(
        _ name: String,
        runID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        telemetry: MotionTelemetry = .measuredThroughout,
        route: [RoutePoint]? = nil,
        healthKitWorkoutUUID: UUID? = nil,
        estimatedSpans: [StandaloneRunFacts.EstimatedSpan] = []
    ) throws -> Built {
        let fixture = try XCTUnwrap(
            FixtureGenerator.fixture(named: name), "unknown fixture \(name)")
        let replay = FixtureReplay.run(fixture)

        let envelope = StandaloneWorkoutComposer.build(
            runID: runID,
            outputs: replay.outputs,
            telemetry: telemetry,
            startedAt: startedAt,
            runType: fixture.runType,
            plan: fixture.plan,
            profile: fixture.profile,
            configuration: .default,
            activity: .outdoorRun,
            route: route,
            healthKitWorkoutUUID: healthKitWorkoutUUID,
            carryPosition: .handHeld,
            averageCadenceStepsPerMinute: 168,
            estimatedSpans: estimatedSpans,
            appVersion: "1.0-test")

        return Built(envelope: envelope, outputs: replay.outputs)
    }
}

extension MotionTelemetry {

    /// A converged calibration and no estimated metres — the ordinary good-GPS case.
    static let measuredThroughout = MotionTelemetry(
        cadenceStepsPerMinute: 168,
        cadenceConfidence: 0.9,
        stepCount: 4200,
        measuredMetres: 8046,
        estimatedMetres: 0,
        calibration: CalibrationSummary(
            isCalibrated: true,
            isConverged: true,
            observationCount: 12,
            bandsWithEvidence: 3,
            metresPerStepAtTypicalCadence: 1.01),
        flags: [])

    /// A run that lost GPS for a stretch and carried it on the motion model (DEG-S-1).
    static let partlyEstimated = MotionTelemetry(
        cadenceStepsPerMinute: 166,
        cadenceConfidence: 0.85,
        stepCount: 4100,
        measuredMetres: 6800,
        estimatedMetres: 1200,
        calibration: CalibrationSummary(
            isCalibrated: true,
            isConverged: true,
            observationCount: 9,
            bandsWithEvidence: 2,
            metresPerStepAtTypicalCadence: 1.03),
        flags: [.distanceEstimated])

    /// A first-ever run: nothing learned yet, so the published prior carried it (DEG-S-2,
    /// DEG-S-5).
    static let uncalibrated = MotionTelemetry(
        cadenceStepsPerMinute: 170,
        cadenceConfidence: 0.7,
        stepCount: 3900,
        measuredMetres: 5000,
        estimatedMetres: 3000,
        calibration: .uncalibrated,
        flags: [.distanceEstimated, .usingUncalibratedPrior])
}

extension FixtureEnvelopes {

    /// A synthetic route along a straight line, for the map tests. Real fixtures carry
    /// location samples but no separate route array.
    static func syntheticRoute(pointCount: Int) -> [RoutePoint] {
        (0..<pointCount).map { index in
            RoutePoint(
                timestamp: Double(index),
                latitude: 51.5 + Double(index) * 0.0001,
                longitude: -0.12,
                altitudeMetres: 0
            )
        }
    }
}
