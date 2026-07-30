import Foundation
import ORModels
import XCTest

@testable import PhoneMotion

/// DEG-S-7 — the phone leaving the hand mid-run.
///
/// This was the one degraded mode with a defined flag and no code raising it: `MotionFlag`
/// declared `carryPositionChanged`, `DistanceFusion` exposed `insert(flag:)` and
/// `disqualifyCurrentWindow()` for it, and nothing called either. It was found by writing
/// the S-051 coverage table and asking, per mode, which test proves it.
///
/// The detector is deliberately a *contradiction between two sources* rather than a
/// threshold on one, and these tests are arranged around that: cadence confidence collapsing
/// on its own is a traffic light (DEG-S-8), and only cadence collapsing while GNSS says the
/// runner is still moving is a pocketed phone.
final class CarryPositionTests: XCTestCase {

    /// A signal loud and periodic enough that cadence is confidently estimated — the
    /// hand-held case.
    ///
    /// Synthetic, and legitimately so: the label here *is* the ground truth by construction
    /// (CON-S-7, AC-FR-S-F-3-2). No accuracy figure is asserted anywhere in this file — what
    /// is asserted is that a flag fires under one condition and not another, which is a
    /// structural property.
    private func coherentSamples(
        from start: TimeInterval, to end: TimeInterval, rateHz: Double = 100
    ) -> [MotionSample] {
        SyntheticGaitSignal.make(
            stepsPerMinute: 168,
            duration: end - start,
            sampleRateHz: rateHz,
            armSwingAmplitude: 8,
            impactAmplitude: 6
        ).samples.map { sample in
            MotionSample(
                timestamp: sample.timestamp + start,
                userAcceleration: sample.userAcceleration,
                gravity: sample.gravity,
                rotationRate: sample.rotationRate)
        }
    }

    /// Near-silence: the runner is moving but the phone is not swinging with them.
    private func incoherentSamples(
        from start: TimeInterval, to end: TimeInterval, rateHz: Double = 100
    ) -> [MotionSample] {
        let count = Int((end - start) * rateHz)
        return (0..<count).map { index in
            let t = start + Double(index) / rateHz
            // A small non-periodic wobble. Not zero — a perfectly still signal would be
            // caught by the stationary threshold instead, which is a different mode.
            let jitter = 0.35 * sin(t * 1.7) + 0.2 * sin(t * 4.3)
            return MotionSample(
                timestamp: t,
                userAcceleration: Vector3(x: jitter, y: -jitter * 0.4, z: jitter * 0.2),
                gravity: Vector3(x: 0, y: 0, z: -9.80665))
        }
    }

    private func run(
        samples: [MotionSample],
        speed: (TimeInterval) -> Double?,
        configuration: MotionEstimationConfiguration = .default
    ) -> MotionEstimate {
        var estimator = MotionEstimator(
            configuration: configuration, carryPosition: .handHeld, runnerHeightMetres: 1.77,
            calibration: CalibrationState(scale: 0.52, observationCount: 8))

        var index = 0
        var distance = 0.0
        var estimate = estimator.tick(at: 0)
        let end = samples.last?.timestamp ?? 0
        var now = 1.0

        while now <= end {
            while index < samples.count, samples[index].timestamp <= now {
                estimator.ingest(samples[index])
                index += 1
            }
            if let metresPerSecond = speed(now) {
                distance += metresPerSecond
                estimator.ingest(LocationFix(
                    timestamp: now,
                    cumulativeDistanceMetres: distance,
                    horizontalAccuracy: 5,
                    speedMetresPerSecond: metresPerSecond))
            }
            estimate = estimator.tick(at: now)
            now += 1
        }
        return estimate
    }

    func testTheFlagFiresWhenSwingVanishesWhileGNSSSaysTheRunnerIsStillMoving() {
        // Sixty seconds hand-held, then sixty seconds pocketed — GNSS reporting a steady
        // 3 m/s throughout, so the only thing that changed is the carry position.
        let samples = coherentSamples(from: 0, to: 60) + incoherentSamples(from: 60, to: 140)
        let estimate = run(samples: samples, speed: { _ in 3.0 })

        XCTAssertTrue(
            estimate.flags.contains(.carryPositionChanged),
            "a pocketed phone on a moving runner must be detected (DEG-S-7): "
                + "\(estimate.flags)")
    }

    func testTheFlagDoesNotFireAtATrafficLight() {
        // The same collapse in the signal, but GNSS agrees the runner has stopped. This is
        // DEG-S-8, which the stationary threshold already handles, and reporting a carry
        // change here would make the flag mean "the runner stood still" — which is most
        // runs.
        let samples = coherentSamples(from: 0, to: 60) + incoherentSamples(from: 60, to: 140)
        let estimate = run(samples: samples, speed: { now in now < 60 ? 3.0 : 0.05 })

        XCTAssertFalse(
            estimate.flags.contains(.carryPositionChanged),
            "a stationary runner is DEG-S-8, not a carry-position change: \(estimate.flags)")
    }

    func testTheFlagDoesNotFireDuringAGNSSOutage() {
        // With no fix there is no witness, and the honest answer is to make no claim. An
        // outage is already flagged as an outage; adding a carry-position flag to every
        // underpass would be inventing a second reason for the same event.
        let samples = coherentSamples(from: 0, to: 60) + incoherentSamples(from: 60, to: 140)
        let estimate = run(samples: samples, speed: { now in now < 60 ? 3.0 : nil })

        XCTAssertFalse(
            estimate.flags.contains(.carryPositionChanged),
            "no GNSS means no witness: \(estimate.flags)")
    }

    func testAMomentaryLossOfSwingDoesNotTripTheDetector() {
        // Ten seconds — an arm raised to check a watch, a road crossing, a bottle switched
        // between hands. Below `incoherentSwingSeconds`, so nothing fires.
        let samples = coherentSamples(from: 0, to: 60)
            + incoherentSamples(from: 60, to: 70)
            + coherentSamples(from: 70, to: 140)
        let estimate = run(samples: samples, speed: { _ in 3.0 })

        XCTAssertFalse(
            estimate.flags.contains(.carryPositionChanged),
            "a brief interruption must not trip it: \(estimate.flags)")
    }

    func testACleanHandHeldRunNeverRaisesIt() {
        let samples = coherentSamples(from: 0, to: 180)
        let estimate = run(samples: samples, speed: { _ in 3.0 })
        XCTAssertFalse(estimate.flags.contains(.carryPositionChanged))
    }

    func testTheThresholdIsRejectedBelowWhatWouldSurviveOneBadWindow() throws {
        // The floor exists because the correlator's own window is 5.12 s: a detector that
        // fired after less than that would be reacting to a single unstable estimate.
        var configuration = MotionEstimationConfiguration.default
        configuration.carry.incoherentSwingSeconds = 2
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                (error as? MotionConfigurationError)?.field, "carry.incoherentSwingSeconds")
        }

        configuration.carry.incoherentSwingSeconds = 20
        configuration.carry.movingSpeedMetresPerSecond = 0
        XCTAssertThrowsError(try configuration.validate())
    }
}
