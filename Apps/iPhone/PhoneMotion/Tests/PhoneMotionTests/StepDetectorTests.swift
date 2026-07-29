import XCTest

@testable import PhoneMotion

final class StepDetectorTests: XCTestCase {

    private let config = MotionEstimationConfiguration.default

    /// Drives the real front end — resampler, both filters, cadence estimator, detector —
    /// so the detector is exercised on the signal it actually receives rather than on an
    /// idealised one.
    private func detect(_ signal: SyntheticGaitSignal) -> [StepEvent] {
        let rate = config.sampling.nominalHz
        var resampler = UniformResampler(sampleRateHz: rate)
        var gait = BandPassFilter(
            lowCutoffHz: config.filters.gaitLowHz,
            highCutoffHz: config.filters.gaitHighHz,
            sampleRateHz: rate)
        var impact = BandPassFilter(
            lowCutoffHz: config.filters.impactLowHz,
            highCutoffHz: config.filters.impactHighHz,
            sampleRateHz: rate)
        var envelope = EnvelopeFollower(
            cutoffHz: config.filters.impactEnvelopeHz, sampleRateHz: rate)
        var cadence = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)
        var detector = StepDetector(
            configuration: config.steps, sampleRateHz: rate,
            minimumStepPeriod: config.cadence.minimumStepPeriod,
            minimumTrustedConfidence: config.cadence.minimumTrustedConfidence)
        let orientation = OrientationResolver()

        var events: [StepEvent] = []
        for sample in signal.samples {
            guard let channels = orientation.resolve(sample) else { continue }
            for (time, raw) in resampler.ingest(
                timestamp: sample.timestamp, value: channels.vertical ?? 0)
            {
                let g = gait.process(raw)
                let e = envelope.process(impact.process(raw))
                cadence.append(vertical: g, magnitude: abs(raw))
                events.append(contentsOf: detector.append(
                    timestamp: time, envelope: e, gaitVertical: g, cadence: cadence.current))
            }
        }
        return events
    }

    // MARK: - Counting

    /// AC-FR-S-B-3-4 — no double counting, across the whole admissible cadence range.
    ///
    /// The bound is on the *rate* rather than the absolute count: the detector needs a
    /// few steps to establish a cadence before its refractory interval means anything, so
    /// requiring `n ± 1` from the very first step would be requiring it to be right
    /// before it has any information. What must never happen is systematic
    /// double-counting, which is what the upper bound catches.
    func testDetectsRoughlyOneEventPerStepWithoutDoubleCounting() {
        for spm in [130.0, 150.0, 170.0, 180.0, 200.0, 220.0] {
            let signal = SyntheticGaitSignal.make(stepsPerMinute: spm, duration: 60)
            let events = detect(signal)
            let expected = Double(signal.labels.stepCount)
            XCTAssertGreaterThan(expected, 0)
            let ratio = Double(events.count) / expected
            XCTAssertLessThan(
                ratio, 1.15,
                "at \(spm) spm the detector emitted \(events.count) for \(Int(expected)) steps "
                    + "— a ratio near 2 would be every arm swing counted twice")
            XCTAssertGreaterThan(
                ratio, 0.80,
                "at \(spm) spm the detector emitted \(events.count) for \(Int(expected)) steps")
        }
    }

    /// AC-FR-S-B-3-2 — the refractory interval is what makes double-counting structurally
    /// impossible, so it is asserted directly rather than inferred from a count.
    func testNoTwoEventsAreCloserThanIsPhysiologicallyPossible() {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 180, duration: 60)
        let events = detect(signal)
        let minimumGap = config.cadence.minimumStepPeriod * config.steps.refractoryFraction
        for (a, b) in zip(events, events.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                b.timestamp - a.timestamp, minimumGap - 1e-9,
                "two events \(b.timestamp - a.timestamp)s apart")
        }
    }

    /// AC-FR-S-B-3-5 — no steps while standing still.
    func testEmitsNoEventsDuringAStationaryInterval() {
        let signal = SyntheticGaitSignal.make(
            stepsPerMinute: 176, duration: 90, stationary: 40...60)
        let events = detect(signal)
        // The envelope has to decay and the cadence estimate has to age out, so the first
        // second of the interval is excluded rather than pretending the transition is
        // instantaneous.
        let during = events.filter { (42.0...58.0).contains($0.timestamp) }
        XCTAssertTrue(
            during.isEmpty,
            "\(during.count) events during a labelled stationary interval")
    }

    /// AC-FR-S-B-3-3, at the detector rather than at the resolver: rotating the whole
    /// trace must not change the step count.
    func testStepCountIsInvariantToDeviceAttitude() {
        let upright = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 40)
        let rotated = SyntheticGaitSignal.make(
            stepsPerMinute: 176, duration: 40,
            rotation: .axisAngle(axis: Vector3(x: 0.4, y: 1, z: 0.2), radians: 1.1))
        XCTAssertEqual(detect(upright).count, detect(rotated).count)
    }

    // MARK: - The fallback

    /// The phase-locked fallback keeps the *rate* when the impact channel goes quiet.
    ///
    /// Driven by suppressing the impact channel outright — the extreme version of a
    /// light-footed runner on soft ground — because a partial suppression would leave it
    /// ambiguous whether the fallback or the detector produced the events.
    func testTheFallbackPreservesTheStepRateWhenImpactsAreUndetectable() {
        let rate = config.sampling.nominalHz
        let spm = 176.0
        let signal = SyntheticGaitSignal.make(stepsPerMinute: spm, duration: 60)
        var resampler = UniformResampler(sampleRateHz: rate)
        var gait = BandPassFilter(
            lowCutoffHz: config.filters.gaitLowHz,
            highCutoffHz: config.filters.gaitHighHz,
            sampleRateHz: rate)
        var cadence = CadenceEstimator(
            configuration: config.cadence, sampleRateHz: rate,
            stationaryRMSThreshold: config.steps.stationaryRMSThreshold)
        var detector = StepDetector(
            configuration: config.steps, sampleRateHz: rate,
            minimumStepPeriod: config.cadence.minimumStepPeriod,
            minimumTrustedConfidence: config.cadence.minimumTrustedConfidence)
        let orientation = OrientationResolver()

        var events: [StepEvent] = []
        for sample in signal.samples {
            guard let channels = orientation.resolve(sample) else { continue }
            for (time, raw) in resampler.ingest(
                timestamp: sample.timestamp, value: channels.vertical ?? 0)
            {
                let g = gait.process(raw)
                cadence.append(vertical: g, magnitude: abs(raw))
                // Envelope pinned at zero: the impact detector can never fire.
                events.append(contentsOf: detector.append(
                    timestamp: time, envelope: 0, gaitVertical: g, cadence: cadence.current))
            }
        }

        XCTAssertTrue(
            events.allSatisfy { $0.origin == .phaseLocked },
            "with no impact channel every event must be labelled as synthesised")
        guard let first = events.first, let last = events.last, events.count > 10 else {
            return XCTFail("the fallback produced \(events.count) events")
        }
        let observedRate = Double(events.count - 1) / (last.timestamp - first.timestamp) * 60
        XCTAssertEqual(
            observedRate, spm, accuracy: 6,
            "the fallback must hold the rate — that is the only thing distance needs")
    }

    /// The fallback must not fire on a cadence nobody believes.
    func testTheFallbackStaysSilentWithoutAConfidentCadence() {
        var detector = StepDetector(
            configuration: config.steps,
            sampleRateHz: config.sampling.nominalHz,
            minimumStepPeriod: config.cadence.minimumStepPeriod,
            minimumTrustedConfidence: config.cadence.minimumTrustedConfidence)
        var events: [StepEvent] = []
        let noCadence: CadenceEstimate? = nil
        for i in 0..<3000 {
            events.append(contentsOf: detector.append(
                timestamp: Double(i) / 100, envelope: 0, gaitVertical: 0, cadence: noCadence))
        }
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Amplitude

    /// The amplitude carried on each event is the model's load-bearing input, so it must
    /// track the signal rather than being a constant nobody noticed.
    func testEventAmplitudeTracksSignalAmplitude() {
        let quiet = SyntheticGaitSignal.make(
            stepsPerMinute: 176, duration: 40, armSwingAmplitude: 6, impactAmplitude: 4)
        let loud = SyntheticGaitSignal.make(
            stepsPerMinute: 176, duration: 40, armSwingAmplitude: 24, impactAmplitude: 16)
        let quietMean = mean(detect(quiet).map(\.amplitude))
        let loudMean = mean(detect(loud).map(\.amplitude))
        XCTAssertGreaterThan(loudMean, quietMean * 2)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
