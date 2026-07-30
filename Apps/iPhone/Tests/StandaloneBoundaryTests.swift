import Foundation
import ORModels
import ORPace
import PhoneMotion
import PhoneSupport
import SwiftData
import XCTest

@testable import OptimalRunner

/// The acceptance test for ADR-S-01's isolation claim (S-031).
///
/// **This is the test the boundary exists for.** `Tools/check-phonemotion-isolation.sh`
/// proves that nothing outside the sensor-feed adapter *can* import the estimator; that is a
/// statement about what is absent. This proves the thing that matters positively: that
/// changing the estimator's configuration changes the numbers reaching the run list, the
/// statistics and the live screen, **with no other code touched**.
///
/// The distinction matters because "the UI only depends on Core" is satisfiable trivially —
/// by a UI that ignores the estimator entirely and shows nothing. What has to be true is
/// that the pipe is connected end to end *and* has exactly one valve. So each test here
/// runs the same recorded trace twice through the same production types, changing one field
/// of `MotionEstimationConfiguration` between the runs, and asserts the far end moved.
///
/// **The signal is real.** `capture-2026-07-28-1918.motion.json` is 40.8 minutes of recorded
/// hand-held motion from a 4.3 mi tempo run (CON-S-7 — no synthetic signal backs anything
/// here). No accuracy figure is claimed by any assertion below: what is asserted is
/// *responsiveness to configuration*, which is a structural property and needs no reference
/// distance.
///
/// This test lives in the app target rather than in a package because it is the only place
/// both sides of the boundary are visible at once — `PhoneMotion` and `PhoneSupport` are
/// deliberately unable to see each other, which is the whole arrangement under test.
final class StandaloneBoundaryTests: XCTestCase {

    // MARK: - Loading the trace

    /// The primary validation set: 40.8 min, six laps of one neighbourhood loop.
    private static let traceName = "capture-2026-07-28-1918"

    /// Reads a committed trace. Walks up from this file rather than using a test bundle
    /// resource, so the fixture stays the single copy every other suite reads too.
    private func loadTrace(_ name: String) throws -> MotionTrace {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url = url
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("motion")
            .appendingPathComponent("\(name).motion.json")

        // `MotionTrace.decode` rather than a bare `JSONDecoder`: it sets the ISO-8601 date
        // strategy the format is written with, and it version-probes first so an
        // unreadable trace fails with a typed error rather than a decoding one.
        return try MotionTrace.decode(from: try Data(contentsOf: url))
    }

    /// How much of the trace to replay, seconds.
    ///
    /// The full 40.8 minutes is 245 000 motion samples and takes about three minutes per
    /// replay in a debug simulator build; six replays would put ten minutes on every CI
    /// run for a claim that is *structural* rather than statistical. Twelve minutes of real
    /// running is more than enough to fit a calibration, exercise a GNSS outage and see a
    /// configuration change propagate — and it is the same recorded signal, just less of
    /// it, so nothing about the honesty of the assertions changes.
    private static let replaySeconds: TimeInterval = 720

    /// Replays a trace through the **production** adapter and run controller, and returns
    /// everything the hub and the screen would end up showing.
    ///
    /// Everything in the chain is the shipping type: `MotionPipeline` (the adapter),
    /// `StandaloneWorkoutComposer` (the envelope), `RunLibrary` (the hub's one write
    /// surface), `RunAnalysis` (the detail screen's facts) and
    /// `StandaloneMetricsScreen` (the live screen). Nothing is stubbed except the clock.
    ///
    /// - Parameter suppressGNSSAfter: stop feeding position fixes after this many seconds,
    ///   simulating the outage of DEG-S-1 over real motion data. Legitimate for the same
    ///   reason `motionreplay --suppress-gnss-after` is (S-024): the motion underneath is
    ///   recorded, and withholding a fix is the opposite of synthesising one.
    @MainActor
    private func replay(
        _ trace: MotionTrace,
        configuration: MotionEstimationConfiguration,
        suppressGNSSAfter: TimeInterval? = nil
    ) throws -> Surfaced {
        var pipeline = MotionPipeline(
            configuration: configuration,
            activity: .outdoorRun,
            carryPosition: trace.header.carryPosition,
            runnerHeightMetres: trace.header.runnerHeightMetres,
            calibration: nil)

        let motionSamples = trace.motion.samples()
        let fixes = trace.locations
        var fixIndex = 0
        var sampleIndex = 0

        var engine = RunEngine(
            configuration: .default,
            plan: WorkoutPlan(
                runType: .tempo,
                elements: [.step(WorkoutStep(kind: .work, goal: .open))]),
            profile: Self.profile)

        var outputs: [EngineOutput] = []
        var lastTelemetry = MotionTelemetry.empty
        var lastScreen: StandaloneMetricsScreen?

        let endSeconds = min(motionSamples.last?.timestamp ?? 0, Self.replaySeconds)
        var now = 1.0
        while now <= endSeconds {
            while sampleIndex < motionSamples.count,
                motionSamples[sampleIndex].timestamp <= now
            {
                pipeline.ingest(motion: motionSamples[sampleIndex])
                sampleIndex += 1
            }
            while fixIndex < fixes.count, fixes[fixIndex].timestamp <= now {
                let fix = fixes[fixIndex]
                if let cutoff = suppressGNSSAfter, fix.timestamp > cutoff {
                    fixIndex += 1
                    continue
                }
                // Every committed trace is scrubbed, so the planar entry point is the only
                // one that applies. A trace that still carried coordinates would fail
                // `check-motion-fixtures.sh` long before it got here.
                if let east = fix.eastMetres, let north = fix.northMetres {
                    pipeline.ingest(planarFix: PlanarFix(
                        timestamp: fix.timestamp,
                        eastMetres: east,
                        northMetres: north,
                        horizontalAccuracy: fix.horizontalAccuracy,
                        speedMetresPerSecond: fix.speedMetresPerSecond))
                }
                fixIndex += 1
            }

            // No `LocationSample` is passed: a scrubbed trace has no coordinates, so there
            // is no route to reconstruct and none is claimed. The pace engine reads the
            // fix only for its accuracy, and the fusion layer has already seen it.
            let tick = pipeline.tick(at: now, location: nil, relativeAltitude: nil)
            outputs.append(engine.tick(tick.input))
            lastTelemetry = tick.telemetry
            now += 1
        }

        let last = try XCTUnwrap(outputs.last)
        lastScreen = StandaloneMetricsScreen.make(
            output: last,
            telemetry: lastTelemetry,
            runType: .tempo,
            profile: Self.profile,
            activity: .outdoorRun)

        let envelope = StandaloneWorkoutComposer.build(
            runID: UUID(),
            outputs: outputs,
            telemetry: lastTelemetry,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            runType: .tempo,
            plan: nil,
            profile: Self.profile,
            configuration: .default,
            activity: .outdoorRun,
            route: nil,
            healthKitWorkoutUUID: nil,
            carryPosition: trace.header.carryPosition,
            averageCadenceStepsPerMinute: pipeline.averageCadenceStepsPerMinute,
            estimatedSpans: pipeline.estimatedSpans,
            appVersion: "1.0-test")

        // Through the hub's real write surface, into the store, and back out as the
        // screens read it.
        let container = try RunStoreContainer.inMemory()
        let context = ModelContext(container)
        let library = RunLibrary(context: context)
        let outcome = library.ingest(payload: try SyncPayloadCodec.encode(envelope))
        XCTAssertTrue(outcome.isAccepted, "the boundary test's own ingest must succeed")

        let record = try XCTUnwrap(library.runs.record(for: envelope.runID))
        let listItem = try XCTUnwrap(try library.runs.listItems().first)
        let cache = try XCTUnwrap(try library.aggregates.cache())

        return Surfaced(
            listDistanceMetres: listItem.distanceMetres,
            statisticsDistanceMetres: cache.lifetime.distanceMetres,
            analysis: try RunAnalysis(record: record),
            screen: try XCTUnwrap(lastScreen),
            motionLegMetres: lastTelemetry.measuredMetres + lastTelemetry.estimatedMetres)
    }

    /// Everything a runner would end up seeing, gathered from the four surfaces that
    /// matter.
    private struct Surfaced {
        let listDistanceMetres: Double
        let statisticsDistanceMetres: Double
        let analysis: RunAnalysis
        let screen: StandaloneMetricsScreen
        let motionLegMetres: Double
    }

    private static let profile = RunnerProfile(
        tempoPace: Pace(minutesPerMile: 9),
        easyPace: Pace(minutesPerMile: 11),
        longPace: Pace(minutesPerMile: 10),
        units: .miles,
        heightMetres: 1.77)

    // MARK: - The acceptance criterion

    /// Swapping the amplitude exponent moves the numbers on every surface, and no file
    /// outside `PhoneMotion` changes to make it happen.
    ///
    /// The exponent is the specific knob S-063 is waiting to turn: the pace ladder measured
    /// **0.670** against the shipped **0.25**. This test does not assert which is right —
    /// that is S-063's job and it is blocked on S-064 — it asserts that when the day comes,
    /// the change is one line in one package.
    ///
    /// **GNSS is suppressed after the tenth minute, and that is load-bearing.** The first
    /// attempt at this test left GNSS on throughout and the exponent barely reached the
    /// far end: over 7 km of good fixes the calibrator re-fits its scale against the same
    /// GNSS reference, so a change in the unscaled model is very nearly cancelled by an
    /// equal and opposite change in `C`. That is the calibrator working correctly, and it
    /// is the same compensating-errors structure S-064 records from the other direction.
    /// The exponent's effect is visible where it *matters* — while the motion leg is
    /// carrying the run on a scale learned earlier (DEG-S-1), which is what this arranges.
    @MainActor
    func testSwappingTheAmplitudeExponentChangesWhatEverySurfaceShows() throws {
        let trace = try loadTrace(Self.traceName)

        let shipped = MotionEstimationConfiguration.default
        var refitted = shipped
        refitted.stepLength.amplitudeExponent = 0.670
        XCTAssertNotEqual(
            shipped.stepLength.amplitudeExponent, refitted.stepLength.amplitudeExponent)

        let outageBegins = Self.replaySeconds * 0.5
        let before = try replay(
            trace, configuration: shipped, suppressGNSSAfter: outageBegins)
        let after = try replay(
            trace, configuration: refitted, suppressGNSSAfter: outageBegins)

        // The outage actually happened, or this test proves nothing.
        XCTAssertGreaterThan(
            try XCTUnwrap(before.analysis.standalone).estimatedMetres, 100,
            "the motion leg must have carried a real stretch of the run")

        // 1. The run list.
        XCTAssertNotEqual(
            before.listDistanceMetres, after.listDistanceMetres, accuracy: 0,
            "the run list's distance must follow the estimator")
        XCTAssertGreaterThan(before.listDistanceMetres, 0)

        // 2. Global statistics.
        XCTAssertNotEqual(
            before.statisticsDistanceMetres, after.statisticsDistanceMetres, accuracy: 0,
            "lifetime totals must follow the estimator")

        // 3. The run detail screen.
        XCTAssertNotEqual(
            before.analysis.summary.distanceMetres,
            after.analysis.summary.distanceMetres, accuracy: 0)

        // 4. The live screen. Asserted on the rendered *text*, because that is what a
        //    runner sees — and it is a stricter claim than the raw number moving, since it
        //    only holds once the difference exceeds the display's own resolution.
        XCTAssertNotEqual(
            before.screen.distanceText, after.screen.distanceText,
            "the live screen's distance must follow the estimator")

        // The change is *material* rather than float noise — but its **direction is
        // deliberately not asserted**, and that is a finding rather than a hedge.
        //
        // In the model alone a larger exponent raises step length, because running puts the
        // amplitude group `A/(h·f²)` above 1. In the calibrated system it need not: the
        // calibrator fits `C` against GNSS over the first half of this replay, so a larger
        // exponent produces a *smaller* `C`, and which way the outage half moves depends on
        // how its amplitudes compare with the calibration half's. Measured here it moved
        // **down** 2.6%, and an earlier version of this test asserted "up" from the model in
        // isolation and failed.
        //
        // That is the same compensating-errors structure S-064 records from the other
        // direction, arrived at independently — and it is the reason S-063's exponent cannot
        // ship until S-064 is resolved.
        let change = abs(after.motionLegMetres - before.motionLegMetres)
        XCTAssertGreaterThan(
            change / before.motionLegMetres, 0.005,
            "the exponent must move the motion leg by more than rounding")
    }

    /// The same, for a knob on a completely different part of the estimator.
    ///
    /// One tunable moving the far end could be a coincidence of where that tunable happens
    /// to be wired. Step *detection* is a different subsystem from step *length* — a
    /// different filter band, a different threshold, a different output — and it reaches
    /// the hub by a different route: through the stored step count and the cadence rather
    /// than through the distance formula.
    ///
    /// The per-cadence-band gain was tried here first and is *not* what this test uses,
    /// because on this trace it does nothing: the run holds 154–165 spm throughout, so
    /// every window lands in the same band whether bands are 5 spm or 40 spm wide, and the
    /// distances came out bit-identical. That is a true fact about the recording rather
    /// than a broken boundary, and a test tuned until it passed would have hidden it. The
    /// band gain needs the pace ladder's speed range to be observable at all.
    @MainActor
    func testSwappingTheStepDetectionThresholdChangesWhatTheHubStores() throws {
        let trace = try loadTrace(Self.traceName)

        let shipped = MotionEstimationConfiguration.default
        var strict = shipped
        // A higher sigma factor makes the adaptive threshold harder to cross, so fewer
        // impacts are located and more steps are phase-locked fill-ins.
        strict.steps.thresholdSigmaFactor = 1.6

        let a = try replay(trace, configuration: shipped)
        let b = try replay(trace, configuration: strict)

        let stepsA = try XCTUnwrap(a.analysis.standalone).stepCount
        let stepsB = try XCTUnwrap(b.analysis.standalone).stepCount
        XCTAssertNotEqual(
            stepsA, stepsB,
            "the stored step count must follow the detector's configuration")
        XCTAssertGreaterThan(stepsA, 0)
    }

    /// A knob reaches the surface it governs, and does not silently rewrite one it does
    /// not.
    ///
    /// Without this, the two tests above are also passed by an estimator that is simply
    /// chaotic — one where every configuration change moves every number a little because
    /// the pipeline is unstable, and "the UI follows the estimator" would be true in the
    /// uninteresting sense that the UI follows noise.
    ///
    /// The bound is relative rather than absolute, and it is set from what the data
    /// actually does: widening the correlation window moved the stored distance by 1.36 m
    /// over 7 km — 0.02% — because the trace contains four real GNSS dropouts, and during
    /// those the motion leg is carrying, so cadence genuinely does touch distance. An
    /// assertion of *no* movement would have been asserting against the design.
    @MainActor
    func testAConfigurationChangeReachesTheSurfaceItGovernsAndNotOthersByAccident() throws {
        let trace = try loadTrace(Self.traceName)

        let shipped = MotionEstimationConfiguration.default
        var longerWindow = shipped
        longerWindow.cadence.windowSeconds = 7.5

        let a = try replay(trace, configuration: shipped)
        let b = try replay(trace, configuration: longerWindow)

        // Cadence is what this knob governs, and it reaches the detail screen.
        XCTAssertNotNil(a.analysis.averageCadenceText)
        XCTAssertNotNil(b.analysis.averageCadenceText)

        // Distance is overwhelmingly the measured leg on this trace, and stays that way.
        let relative = abs(a.listDistanceMetres - b.listDistanceMetres) / a.listDistanceMetres
        XCTAssertLessThan(
            relative, 0.001,
            "a cadence-window change must not rewrite GNSS-measured distance "
                + "(moved \(relative * 100)%)")
    }

    // MARK: - The boundary is real in the other direction too

    /// Calibration crosses the boundary as opaque bytes and comes back intact.
    ///
    /// This is what lets `CalibrationStoring` be declared over `Data` in `ORModels`: the
    /// encoded shape is the estimator's business and will change when S-064 lands, and
    /// nothing outside the adapter is in a position to care.
    @MainActor
    func testACalibrationSurvivesAnOpaqueRoundTripThroughAStoreThatCannotReadIt() throws {
        let trace = try loadTrace("capture-2026-07-28-2010")

        var configuration = MotionEstimationConfiguration.default
        configuration.fusion.gnssDropoutSeconds = 1

        var first = MotionPipeline(
            configuration: configuration, activity: .outdoorRun,
            carryPosition: .handHeld, runnerHeightMetres: 1.77, calibration: nil)
        drive(&first, trace: trace)

        let payload = try XCTUnwrap(
            first.calibrationPayload, "the run must have learned something to persist")

        // A store that only moves bytes.
        let store = OpaqueCalibrationStore()
        store.saveCalibration(payload, for: .handHeld)
        let reloaded = try XCTUnwrap(store.loadCalibration(for: .handHeld))

        // The summary is legible on the far side without decoding anything estimator-shaped.
        let summary = CalibrationBridge.summary(of: reloaded, configuration: configuration)
        XCTAssertTrue(summary.isCalibrated)
        XCTAssertGreaterThan(summary.observationCount, 0)
        XCTAssertNotNil(
            summary.metresPerStepAtTypicalCadence,
            "the runner-facing figure must survive the round trip")

        // And a second run started from it begins calibrated rather than relearning.
        var second = MotionPipeline(
            configuration: configuration, activity: .outdoorRun,
            carryPosition: .handHeld, runnerHeightMetres: 1.77, calibration: reloaded)
        let opening = second.tick(at: 0, location: nil, relativeAltitude: nil)
        XCTAssertTrue(
            opening.telemetry.calibration.isCalibrated,
            "AC-FR-S-C-2-2: the second run starts calibrated")
    }

    /// A corrupt calibration is treated as absent rather than as an error.
    ///
    /// ADR-S-06's fallback already is "report no motion distance until one is learned",
    /// which is the right behaviour for unreadable bytes too — and refusing to start a run
    /// over it would be a worse answer than relearning in the first hundred metres.
    @MainActor
    func testACorruptCalibrationDegradesToUncalibratedRatherThanFailing() throws {
        var pipeline = MotionPipeline(
            configuration: .default, activity: .outdoorRun, carryPosition: .handHeld,
            runnerHeightMetres: 1.77, calibration: Data("not a calibration".utf8))
        let tick = pipeline.tick(at: 0, location: nil, relativeAltitude: nil)
        XCTAssertFalse(tick.telemetry.calibration.isCalibrated)
    }

    // MARK: - Helpers

    @MainActor
    private func drive(_ pipeline: inout MotionPipeline, trace: MotionTrace) {
        let samples = trace.motion.samples()
        let fixes = trace.locations
        var fixIndex = 0
        var sampleIndex = 0
        var now = 1.0
        let end = samples.last?.timestamp ?? 0

        while now <= end {
            while sampleIndex < samples.count, samples[sampleIndex].timestamp <= now {
                pipeline.ingest(motion: samples[sampleIndex])
                sampleIndex += 1
            }
            while fixIndex < fixes.count, fixes[fixIndex].timestamp <= now {
                let fix = fixes[fixIndex]
                if let east = fix.eastMetres, let north = fix.northMetres {
                    pipeline.ingest(planarFix: PlanarFix(
                        timestamp: fix.timestamp,
                        eastMetres: east, northMetres: north,
                        horizontalAccuracy: fix.horizontalAccuracy,
                        speedMetresPerSecond: fix.speedMetresPerSecond))
                }
                fixIndex += 1
            }
            _ = pipeline.tick(at: now, location: nil, relativeAltitude: nil)
            now += 1
        }
    }
}

/// A calibration store that can only move bytes — which is the entire contract.
private final class OpaqueCalibrationStore: CalibrationStoring, @unchecked Sendable {
    private var storage: [CarryPosition: Data] = [:]
    func loadCalibration(for position: CarryPosition) -> Data? { storage[position] }
    func saveCalibration(_ payload: Data?, for position: CarryPosition) {
        storage[position] = payload
    }
}
