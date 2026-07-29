import Foundation
import XCTest

@testable import PhoneMotion

/// S-062 — a cadence below the configured floor must not be doubled.
///
/// The disjoint-interval rule of design.md §4.3 is exact *provided the true cadence is
/// inside* `[minStepsPerMinute, maxStepsPerMinute]`. Outside it the rule does not
/// degrade, it reinterprets: a 104 spm walk has a 0.577 s step period, which is not in
/// the step interval `[0.25, 0.5]`, so it lands in the stride interval and is reported as
/// 120/0.577 = 208 spm. The two committed walk traces showed exactly that — 207.8 against
/// a spectrally-measured 103.7, and 211.2 against 106.1, ratios of 2.005 and 1.991.
///
/// **Both directions are verified on the recorded walks**, not on a generator, because the
/// first attempt at this fix passed a synthetic test and still halved real running: an
/// impulse train is harmonic-rich in a way a recorded walk is not, so the synthetic never
/// reached the code path it was meant to prove. The generator appears below only where its
/// label is the ground truth by construction (CON-S-7).
final class SlowGaitCadenceTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default

    /// A walk: slow, and far quieter than running.
    ///
    /// Amplitudes are the measured ones — gait-band RMS is 2.3-3.2 m/s² over the two walk
    /// traces, against 8.1-12.2 running — so this sits where a real walk sits rather than
    /// wherever the test happens to pass.
    ///
    /// **This is not the shape a real walk has**, and the difference is the point. The
    /// generator lays impulses at the step rate, and an impulse train is harmonic-rich, so
    /// there is real periodicity at half the step period and the harmonic check correctly
    /// *confirms* a stride. A recorded walk's vertical channel is nearly a pure sinusoid at
    /// the step rate — 1.73 Hz at relative power 1.00 with 0.03 at the 0.87 Hz subharmonic —
    /// with no such structure. So the walking half of S-062 is verified against the recorded
    /// traces below, and this generator is used only where its label is the ground truth.
    private func walkSignal(stepsPerMinute: Double) -> SyntheticGaitSignal {
        SyntheticGaitSignal.make(
            stepsPerMinute: stepsPerMinute, duration: 30,
            armSwingAmplitude: 3.5, impactAmplitude: 1.2, seed: 0x5107)
    }

    /// The two committed walk traces, with the step rate their own `CMPedometer` channel
    /// recorded over the same seconds.
    ///
    /// That channel is a *recorded reference*, not a synthetic label and not an accuracy
    /// bound: these assertions ask whether the estimator picked the right multiple of the
    /// gait period, which is a factor-of-two question, not a question of percent error.
    /// CMPedometer is not trusted here for anything finer — on the slow-mile trace its own
    /// counted rate sits 20.7% under an independent spectral measurement.
    private static let walkTraces = [
        "capture-2026-07-28-1959",
        "capture-2026-07-28-2023",
    ]

    /// The trace's own pedometer cadence, taken from the trace rather than pasted in as a
    /// constant, so the assertion cannot drift away from the file it describes.
    private func pedometerMedianCadence(_ trace: MotionTrace) throws -> Double {
        let values = trace.pedometer.compactMap { $0.currentCadenceStepsPerSecond }.map {
            $0 * 60
        }.sorted()
        return try XCTUnwrap(values.isEmpty ? nil : values[values.count / 2])
    }

    private func loadTrace(_ name: String) throws -> MotionTrace {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhoneMotionTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PhoneMotion
            .deletingLastPathComponent()  // iPhone
            .deletingLastPathComponent()  // Apps
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Fixtures/motion/\(name).motion.json")
        return try MotionTrace.decode(from: Data(contentsOf: url))
    }

    /// Setting the re-read floor to the range floor disables the S-062 path exactly, and
    /// nothing else: `60/lag` for a lag in the stride interval is always below 120, so the
    /// admissibility test can never pass. This is the pre-fix estimator.
    private var withoutTheFix: MotionEstimationConfiguration {
        var c = config
        c.cadence.slowGaitFloorStepsPerMinute = c.cadence.minStepsPerMinute
        return c
    }

    /// Both directions at once, on the data that found the bug.
    ///
    /// The before/after ratio is asserted rather than either figure against a reference:
    /// the defect is *exactly a factor of two*, so that ratio is the claim, and stating it
    /// this way needs no external constant to be right. The pedometer comparison then fixes
    /// which of the two readings is the correct one.
    func testTheRecordedWalksAreDoubledWithoutTheFixAndCorrectWithIt() throws {
        for name in Self.walkTraces {
            let trace = try loadTrace(name)
            let before = try XCTUnwrap(
                TraceReplay.run(trace: trace, configuration: withoutTheFix)
                    .medianCadenceStepsPerMinute)
            let after = try XCTUnwrap(
                TraceReplay.run(trace: trace, configuration: config)
                    .medianCadenceStepsPerMinute)

            XCTAssertEqual(
                before / after, 2.0, accuracy: 0.05,
                "\(name): the defect is a doubling — before \(before), after \(after)")

            let pedometer = try pedometerMedianCadence(trace)
            XCTAssertEqual(
                after / pedometer, 1.0, accuracy: 0.15,
                "\(name): \(after) spm against the trace's own pedometer \(pedometer)")
            XCTAssertEqual(
                before / pedometer, 2.0, accuracy: 0.2,
                "\(name): precondition — the pre-fix reading should be the doubled one")
        }
    }

    /// And the runs are materially untouched — the direction that matters most, since the
    /// tempo trace is what the tier's distance figures rest on.
    ///
    /// **Not bit-identical, and it should not be.** Both running traces contain stops — four
    /// GNSS dropouts and the crossings that caused them — and during a stop or a few walking
    /// steps the S-062 path is *supposed* to engage. It moves the tempo trace's median
    /// cadence by 0.005 spm and its fused distance by 1 mm over 7 km, which is the signature
    /// of a path that fires a handful of times in 41 minutes and never during running.
    func testTheRecordedRunsAreMateriallyUnchangedByTheFix() throws {
        for name in ["capture-2026-07-28-1918", "capture-2026-07-28-2010"] {
            let trace = try loadTrace(name)
            let before = TraceReplay.run(trace: trace, configuration: withoutTheFix)
            let after = TraceReplay.run(trace: trace, configuration: config)
            XCTAssertEqual(
                try XCTUnwrap(after.medianCadenceStepsPerMinute),
                try XCTUnwrap(before.medianCadenceStepsPerMinute), accuracy: 0.05,
                "\(name): the S-062 path moved a running trace's cadence")
            XCTAssertEqual(
                Double(after.stepCount), Double(before.stepCount), accuracy: 2,
                "\(name): step count moved")
            XCTAssertEqual(
                after.fusedDistanceMetres, before.fusedDistanceMetres, accuracy: 0.05,
                "\(name): fused distance moved")
        }
    }

    private func cadences(
        _ signal: SyntheticGaitSignal, configuration: MotionEstimationConfiguration
    ) -> [CadenceEstimate] {
        let rate = configuration.sampling.nominalHz
        var resampler = UniformResampler(sampleRateHz: rate)
        var gait = BandPassFilter(
            lowCutoffHz: configuration.filters.gaitLowHz,
            highCutoffHz: configuration.filters.gaitHighHz,
            sampleRateHz: rate)
        var estimator = CadenceEstimator(
            configuration: configuration.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: configuration.steps.stationaryRMSThreshold)
        let orientation = OrientationResolver()
        var out: [CadenceEstimate] = []
        for sample in signal.samples {
            guard let channels = orientation.resolve(sample) else { continue }
            for (_, raw) in resampler.ingest(
                timestamp: sample.timestamp, value: channels.vertical ?? 0)
            {
                let filtered = gait.process(raw)
                if let estimate = estimator.append(vertical: filtered, magnitude: abs(raw)) {
                    out.append(estimate)
                }
            }
        }
        return out
    }

    /// The counterpart that keeps the fix honest, and the case that caught the first
    /// attempt at it.
    ///
    /// A running stride whose arm swing dominates its impacts has a weak half-lag
    /// correlation for the same reason a walking step does — so a rule that acted on the
    /// harmonic check alone halved this. Only the amplitude gate separates them, and this
    /// asserts it does.
    func testALoudRunningStrideWithWeakImpactsIsStillReadAsAStride() {
        for spm in stride(from: 140.0, through: 200.0, by: 5.0) {
            let signal = SyntheticGaitSignal.make(
                stepsPerMinute: spm, duration: 30, armSwingAmplitude: 20, impactAmplitude: 4)
            guard let last = cadences(signal, configuration: config).last else {
                XCTFail("no estimate for \(spm) spm")
                continue
            }
            XCTAssertEqual(
                last.stepsPerMinute, spm, accuracy: 10,
                "a \(spm) spm run was re-read as a slow gait — the amplitude gate let "
                    + "running through at \(last.stepsPerMinute) spm")
        }
    }

    /// The floor is a floor. Below it there is no reading to fall back to, and inventing
    /// one would be worse than reporting nothing.
    func testNothingIsReportedBelowTheSlowGaitFloor() {
        let estimates = cadences(walkSignal(stepsPerMinute: 40), configuration: config)
        for estimate in estimates {
            XCTAssertGreaterThanOrEqual(
                estimate.stepsPerMinute, config.cadence.slowGaitFloorStepsPerMinute - 1e-9,
                "reported \(estimate.stepsPerMinute) spm, below the floor")
        }
    }

    /// The configuration cannot promise a cadence the correlator never searched for.
    func testTheFloorIsRejectedBelowWhatTheCorrelatorSearches() {
        var c = MotionEstimationConfiguration.default
        c.cadence.slowGaitFloorStepsPerMinute = 30  // < minStepsPerMinute / 2
        XCTAssertThrowsError(try c.validate())
    }
}
