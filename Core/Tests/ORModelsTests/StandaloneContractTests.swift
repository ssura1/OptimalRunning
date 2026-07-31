import Foundation
import XCTest

@testable import ORModels

/// The sensor-contract extension the standalone tier depends on (ADR-S-02, ADR-S-01).
///
/// These types live in `Core` rather than in `PhoneMotion` for one reason — a run record has
/// to carry them, and a screen that renders one must not have to import an estimator to name
/// it. That makes them `Core`'s to test, even though the only tier that produces them is the
/// phone's. Testing them from `PhoneSupport` would be testing the consumer.
///
/// The compatibility tests here are the load-bearing ones: they are the difference between
/// "adding an optional field is safe" being a belief and being a checked property.
final class StandaloneContractTests: XCTestCase {

    // MARK: - Backward compatibility

    func testAProfileEncodedBeforeTheStandaloneFieldsExistedStillDecodes() throws {
        // The exact shape a pre-standalone build wrote. Not round-tripped through today's
        // encoder — that would defeat the point, since today's encoder writes the new keys.
        let json = """
            {
              "units": "miles",
              "palette": "standard",
              "paceHapticsEnabled": true,
              "crownAdvanceEnabled": false
            }
            """
        let profile = try JSONDecoder().decode(RunnerProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.units, .miles)
        XCTAssertNil(profile.heightMetres, "absent height is absent, not a default")
        // The documented defaults, so a runner who updates does not find their phone silent.
        XCTAssertTrue(profile.spokenCuesEnabled)
        XCTAssertTrue(profile.splitAnnouncementsEnabled)
        XCTAssertNil(
            profile.timeAnnouncementIntervalSeconds,
            "AC-FR-S-D-1-5: elapsed-time announcements are off by default")
        XCTAssertEqual(profile.speechRateScale, RunnerProfile.defaultSpeechRateScale)
        XCTAssertNil(
            profile.speechVoiceIdentifier,
            "no stored voice means best-available, which stays right after the runner "
                + "downloads a better one")
    }

    /// A rate scale arrives from a synced watch, a stored envelope, or a build that does not
    /// exist yet. `0` is a run with no spoken feedback and no indication why; `NaN` is an
    /// utterance AVFoundation declines to speak at all.
    func testAnOutOfRangeSpeechRateIsClampedRatherThanTrusted() throws {
        func rate(from literal: String) throws -> Double {
            let json = """
                {
                  "units": "miles",
                  "palette": "standard",
                  "paceHapticsEnabled": true,
                  "crownAdvanceEnabled": false,
                  "speechRateScale": \(literal)
                }
                """
            return try JSONDecoder()
                .decode(RunnerProfile.self, from: Data(json.utf8)).speechRateScale
        }

        XCTAssertEqual(try rate(from: "0"), RunnerProfile.speechRateScaleRange.lowerBound)
        XCTAssertEqual(try rate(from: "-4"), RunnerProfile.speechRateScaleRange.lowerBound)
        XCTAssertEqual(try rate(from: "99"), RunnerProfile.speechRateScaleRange.upperBound)
        XCTAssertEqual(try rate(from: "0.85"), 0.85, "a value in range is left alone")
    }

    /// `Swift.max(.nan, 0.6)` is `.nan`, so the obvious `min`/`max` clamp would let a
    /// non-finite value straight through.
    func testANonFiniteSpeechRateFallsBackToTheDefault() {
        XCTAssertEqual(
            RunnerProfile.validSpeechRateScale(.nan), RunnerProfile.defaultSpeechRateScale)
        XCTAssertEqual(
            RunnerProfile.validSpeechRateScale(.infinity),
            RunnerProfile.defaultSpeechRateScale)
    }

    func testAProfileWithEveryStandaloneFieldRoundTrips() throws {
        let profile = RunnerProfile(
            tempoPace: Pace(minutesPerMile: 8),
            units: .kilometres,
            heightMetres: 1.77,
            spokenCuesEnabled: false,
            splitAnnouncementsEnabled: false,
            timeAnnouncementIntervalSeconds: 300,
            speechRateScale: 0.8,
            speechVoiceIdentifier: "com.apple.voice.enhanced.en-US.Evan")

        let decoded = try JSONDecoder().decode(
            RunnerProfile.self, from: try JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testAnEnvelopeWithoutStandaloneFactsDecodesToNilRatherThanADefault() throws {
        // A default-constructed `StandaloneRunFacts` would claim a carry position for a
        // watch run, which is a fabrication rather than a missing value.
        let envelope = RunEnvelopeFixtures.watch()
        let data = try RunEnvelopeCoder.encode(envelope)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(
            object["standalone"],
            "a nil optional must be omitted entirely, not encoded as null")

        XCTAssertNil(try RunEnvelopeCoder.decode(data).standalone)
    }

    func testAStandaloneEnvelopeRoundTripsAndAWatchOneIsUnaffected() throws {
        let facts = StandaloneRunFacts(
            carryPosition: .handHeld,
            measuredMetres: 6800,
            estimatedMetres: 1200,
            stepCount: 4100,
            averageCadenceStepsPerMinute: 166.4,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: true, observationCount: 9,
                bandsWithEvidence: 2, metresPerStepAtTypicalCadence: 1.03),
            flags: [.distanceEstimated, .sourceDisagreement],
            estimatedSpans: [.init(startSeconds: 300, endSeconds: 420)])

        let envelope = RunEnvelopeFixtures.watch(
            deviceTier: .phoneStandalone, standalone: facts)
        let decoded = try RunEnvelopeCoder.decode(try RunEnvelopeCoder.encode(envelope))

        XCTAssertEqual(decoded.standalone, facts)
        XCTAssertEqual(decoded.deviceTier, .phoneStandalone)
    }

    // MARK: - The facts themselves

    func testMeasuredFractionIsNilOverZeroDistanceRatherThanOneHundredPercent() {
        let timedOnly = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 0, estimatedMetres: 0, stepCount: 0,
            averageCadenceStepsPerMinute: nil, calibration: .uncalibrated, flags: [],
            estimatedSpans: [])
        XCTAssertNil(
            timedOnly.measuredFraction,
            "an indoor run must show nothing, not a meaningless 100%")

        let mixed = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 750, estimatedMetres: 250,
            stepCount: 500, averageCadenceStepsPerMinute: 168, calibration: .uncalibrated,
            flags: [], estimatedSpans: [])
        XCTAssertEqual(try XCTUnwrap(mixed.measuredFraction), 0.75, accuracy: 1e-12)
    }

    func testLowerConfidenceHasTwoIndependentCauses() {
        // A run that never had a calibration to work from...
        let prior = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 5000, estimatedMetres: 3000,
            stepCount: 3900, averageCadenceStepsPerMinute: 170,
            calibration: .uncalibrated, flags: [.usingUncalibratedPrior], estimatedSpans: [])
        XCTAssertTrue(prior.isLowerConfidence)

        // ...and a run whose calibration had not settled when it was recorded.
        let unsettled = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 5000, estimatedMetres: 3000,
            stepCount: 3900, averageCadenceStepsPerMinute: 170,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: false, observationCount: 2,
                bandsWithEvidence: 0, metresPerStepAtTypicalCadence: 1.02),
            flags: [], estimatedSpans: [])
        XCTAssertTrue(unsettled.isLowerConfidence)

        // And a fully-measured run on a settled calibration is not marked, so the marking
        // carries information.
        let clean = StandaloneRunFacts(
            carryPosition: .handHeld, measuredMetres: 8000, estimatedMetres: 0,
            stepCount: 4200, averageCadenceStepsPerMinute: 168,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: true, observationCount: 12,
                bandsWithEvidence: 3, metresPerStepAtTypicalCadence: 1.01),
            flags: [], estimatedSpans: [])
        XCTAssertFalse(clean.isLowerConfidence)
    }

    func testAnEstimatedSpanReportsItsDurationAndNeverANegativeOne() {
        XCTAssertEqual(
            StandaloneRunFacts.EstimatedSpan(startSeconds: 300, endSeconds: 420)
                .durationSeconds, 120, accuracy: 1e-12)
        // A reversed span is a bug upstream; reporting a negative duration would let it
        // subtract from a total somewhere downstream.
        XCTAssertEqual(
            StandaloneRunFacts.EstimatedSpan(startSeconds: 420, endSeconds: 300)
                .durationSeconds, 0, accuracy: 1e-12)
    }

    // MARK: - Telemetry

    func testEmptyTelemetryClaimsNothing() {
        let empty = MotionTelemetry.empty
        XCTAssertNil(empty.cadenceStepsPerMinute)
        XCTAssertNil(empty.measuredFraction, "no distance means no fraction, not 100%")
        XCTAssertFalse(empty.calibration.isCalibrated)
        XCTAssertTrue(empty.flags.isEmpty)
    }

    func testTelemetryRoundTripsThroughItsCoding() throws {
        let telemetry = MotionTelemetry(
            cadenceStepsPerMinute: 168.4,
            cadenceConfidence: 0.87,
            stepCount: 4200,
            measuredMetres: 6800,
            estimatedMetres: 1200,
            calibration: CalibrationSummary(
                isCalibrated: true, isConverged: false, observationCount: 3,
                bandsWithEvidence: 1, metresPerStepAtTypicalCadence: 1.02),
            flags: [.distanceEstimated])
        let decoded = try JSONDecoder().decode(
            MotionTelemetry.self, from: try JSONEncoder().encode(telemetry))
        XCTAssertEqual(decoded, telemetry)
    }

    // MARK: - Flags

    func testEveryMotionFlagExplainsItselfToARunner() {
        // A flag with no sentence reaches the detail screen as nothing. `allCases` is what
        // keeps this true when an eighth condition is added.
        for flag in MotionFlag.allCases {
            let explanation = flag.runnerFacingExplanation
            XCTAssertGreaterThan(explanation.count, 30, "\(flag)")
            XCTAssertTrue(
                explanation.hasSuffix("."), "\(flag) — explanations are sentences")
            XCTAssertFalse(
                explanation.contains("flag"),
                "\(flag) — a runner does not know what a flag is")
        }
    }

    func testMotionFlagsAreWireStableUnderTheirRawValues() throws {
        // These are persisted inside every standalone run record. A renamed case would make
        // stored runs undecodable, so the raw values are pinned here rather than trusted to
        // the case names.
        let expected: Set<String> = [
            "sampleStarvation", "gravityEstimateSuspect", "stepLengthClamped",
            "sourceDisagreement", "distanceEstimated", "usingUncalibratedPrior",
            "carryPositionChanged",
        ]
        XCTAssertEqual(Set(MotionFlag.allCases.map(\.rawValue)), expected)
    }

    // MARK: - Capabilities

    func testTheStandaloneTierDeclaresTheCapabilitiesTheDesignSpecifies() {
        // design.md §7.2's table, as an assertion. `.builderOnly` is the one worth pinning:
        // a boolean `supportsWorkoutSession` would read `false` here and a caller reading it
        // as "can I record a workout at all" would wrongly decline to write to Health
        // (CON-S-2, ADR-S-02).
        let standalone = SensorCapabilities(
            hasAltimeter: true, hasGPS: true, hasAlwaysOnDisplay: false,
            supportsNativeActivitySegmentation: false, supportsDoubleTap: false,
            distance: .measuredWithEstimatedFallback, workoutSession: .builderOnly)
        XCTAssertEqual(standalone.distance, .measuredWithEstimatedFallback)
        XCTAssertEqual(standalone.workoutSession, .builderOnly)

        // And the watch defaults are unchanged, which is what makes the extension additive
        // (AC-FR-S-A-3-4).
        let watch = SensorCapabilities(
            hasAltimeter: true, hasGPS: true, hasAlwaysOnDisplay: true,
            supportsNativeActivitySegmentation: true, supportsDoubleTap: true)
        XCTAssertEqual(watch.distance, .measuredWithEstimatedFallback)
        XCTAssertEqual(watch.workoutSession, .localSession)
    }

    func testMotionModelDistanceIsEstimatedAndDistinctFromThePedometer() {
        // AC-FR-S-A-3-3 — the two are different claims and collapsing them would make the
        // measured/estimated display a lie. It also matters live: `RunEngine` reads
        // `.pedometer` with no fix as an indoor run, and a GPS-denied underpass is not a
        // treadmill.
        XCTAssertTrue(DistanceSource.motionModel.isEstimated)
        XCTAssertTrue(DistanceSource.pedometer.isEstimated)
        XCTAssertFalse(DistanceSource.location.isEstimated)
        XCTAssertFalse(DistanceSource.healthKit.isEstimated)
        XCTAssertNotEqual(DistanceSource.motionModel, .pedometer)
    }
}

// MARK: - Fixtures

/// A minimal envelope, so these tests are about the contract rather than about run content.
private enum RunEnvelopeFixtures {

    static func watch(
        deviceTier: DeviceTier = .modern,
        standalone: StandaloneRunFacts? = nil
    ) -> RunEnvelope {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return RunEnvelope(
            runID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            deviceTier: deviceTier,
            appVersion: "1.0-test",
            startedAt: started,
            endedAt: started.addingTimeInterval(1800),
            runType: .tempo,
            plan: nil,
            profileSnapshot: RunnerProfile(),
            configSnapshot: .default,
            healthKitWorkoutUUID: nil,
            summary: RunSummary(
                distanceMetres: 8000, activeSeconds: 1800, averagePace: nil,
                averageHeartRate: nil, maxHeartRate: nil, elevationGainMetres: 0,
                timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count)),
            steps: [],
            zoneTimeline: [],
            samples: PackedSamples(samples: [], intervalSeconds: 1),
            route: nil,
            degradations: [],
            standalone: standalone)
    }
}
