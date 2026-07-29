import Foundation
import ORModels

/// The whole estimation pipeline behind one type (standalone/design.md §7.1).
///
/// Raw motion samples and position fixes in; cadence, step events and a fused distance
/// out. Pure: the same inputs always produce the same outputs, with no wall-clock and no
/// randomness anywhere — which is what makes a recorded trace replayable and CI
/// simulator-free (NFR-S-14), exactly as `RunEngine.tick` is for the core track.
///
/// `tick(at:)` is the single output entry point, deliberately mirroring `RunEngine`: one
/// call returns everything the caller needs, so there are no properties to read in the
/// right order.
public struct MotionEstimator: Sendable {
    private let config: MotionEstimationConfiguration
    private let carryPosition: CarryPosition
    private let model: StepLengthModel

    private let orientation = OrientationResolver()
    private var verticalResampler: UniformResampler
    private var magnitudeResampler: UniformResampler
    private var gaitFilter: BandPassFilter
    private var impactFilter: BandPassFilter
    private var envelope: EnvelopeFollower
    private var cadence: CadenceEstimator
    private var detector: StepDetector
    private var fusion: DistanceFusion

    /// Whether any calibration existed when the run started. Drives whether the
    /// published prior is permitted at all (design.md §5.4).
    private let startedCalibrated: Bool

    private var stepCount = 0
    private var lastSampleTime: TimeInterval?
    private var deliveredSamples = 0
    private var starvationWindowStart: TimeInterval?
    private var flags: Set<MotionFlag> = []

    public init(
        configuration: MotionEstimationConfiguration = .default,
        carryPosition: CarryPosition = .handHeld,
        runnerHeightMetres: Double? = nil,
        calibration: CalibrationState = .init()
    ) {
        config = configuration
        self.carryPosition = carryPosition
        model = StepLengthModel(
            configuration: configuration.stepLength, runnerHeightMetres: runnerHeightMetres)
        let rate = configuration.sampling.nominalHz
        verticalResampler = UniformResampler(sampleRateHz: rate)
        magnitudeResampler = UniformResampler(sampleRateHz: rate)
        gaitFilter = BandPassFilter(
            lowCutoffHz: configuration.filters.gaitLowHz,
            highCutoffHz: configuration.filters.gaitHighHz,
            sampleRateHz: rate)
        impactFilter = BandPassFilter(
            lowCutoffHz: configuration.filters.impactLowHz,
            highCutoffHz: configuration.filters.impactHighHz,
            sampleRateHz: rate)
        envelope = EnvelopeFollower(
            cutoffHz: configuration.filters.impactEnvelopeHz, sampleRateHz: rate)
        cadence = CadenceEstimator(
            configuration: configuration.cadence,
            sampleRateHz: rate,
            stationaryRMSThreshold: configuration.steps.stationaryRMSThreshold)
        detector = StepDetector(
            configuration: configuration.steps,
            sampleRateHz: rate,
            minimumStepPeriod: configuration.cadence.minimumStepPeriod,
            minimumTrustedConfidence: configuration.cadence.minimumTrustedConfidence)
        startedCalibrated = calibration.scale != nil
        fusion = DistanceFusion(
            configuration: configuration.fusion,
            calibration: configuration.calibration,
            calibrator: Calibrator(
                configuration: configuration.calibration, state: calibration))
    }

    /// The calibration to persist when the run ends (AC-FR-S-C-2-2).
    public var calibration: CalibrationState { fusion.calibration }

    /// Feeds one motion sample. Returns the step events it completed.
    @discardableResult
    public mutating func ingest(_ sample: MotionSample) -> [StepEvent] {
        guard sample.timestamp.isFinite else { return [] }
        trackDelivery(at: sample.timestamp)
        guard let channels = orientation.resolve(sample) else { return [] }

        // The vertical channel may be missing for a sample while the magnitude channel
        // is not, so the two are resampled independently rather than being forced onto a
        // shared grid that a degenerate gravity vector could stall.
        let verticalGrid = verticalResampler.ingest(
            timestamp: sample.timestamp, value: channels.vertical ?? 0)
        let magnitudeGrid = magnitudeResampler.ingest(
            timestamp: sample.timestamp, value: channels.magnitude)

        var events: [StepEvent] = []
        for (index, point) in verticalGrid.enumerated() {
            let (time, raw) = point
            let gait = gaitFilter.process(raw)
            let impact = envelope.process(impactFilter.process(raw))
            let magnitude = index < magnitudeGrid.count ? magnitudeGrid[index].1 : raw
            cadence.append(vertical: gait, magnitude: magnitude)
            let produced = detector.append(
                timestamp: time,
                envelope: impact,
                gaitVertical: gait,
                cadence: cadence.current)
            for event in produced {
                apply(event)
                events.append(event)
            }
        }
        flags.formUnion(cadence.flags)
        return events
    }

    /// Feeds one position fix.
    public mutating func ingest(_ fix: LocationFix) {
        fusion.ingest(fix: fix)
    }

    /// Advances the clock and returns the current estimate.
    public mutating func tick(at now: TimeInterval) -> MotionEstimate {
        fusion.tick(at: now)
        let current = cadence.current
        return MotionEstimate(
            cumulativeDistanceMetres: fusion.cumulativeMetres,
            source: fusion.source,
            cadenceStepsPerMinute: current.map { $0.stepsPerMinute },
            cadenceConfidence: current?.confidence ?? 0,
            measuredMetres: fusion.measuredMetres,
            estimatedMetres: fusion.estimatedMetres,
            stepCount: stepCount,
            flags: flags.union(fusion.flags))
    }

    /// The motion leg's own total, computed whether or not it was in use — the series a
    /// trace is scored against (design.md §6.1).
    public var motionOnlyMetres: Double { fusion.motionOnlyMetres }

    public var isCalibrated: Bool { fusion.isCalibrated }
    public var isConverged: Bool { fusion.isConverged }

    // MARK: - Internals

    private mutating func apply(_ event: StepEvent) {
        stepCount += 1
        let spm = event.stepFrequency * 60
        let confident = (cadence.current?.confidence ?? 0)
            >= config.cadence.minimumTrustedConfidence
        let unscaled = model.unscaledLength(
            amplitude: event.amplitude, stepFrequencyHz: event.stepFrequency)

        var metres: Double?
        if let scale = fusion.scale {
            let estimate = model.stepLength(
                amplitude: event.amplitude,
                stepFrequencyHz: event.stepFrequency,
                scale: scale,
                gain: fusion.gain(forStepsPerMinute: spm))
            metres = estimate?.metres
            if estimate?.wasClamped == true { flags.insert(.stepLengthClamped) }
        } else if !startedCalibrated, fusion.source == .motionModel {
            // No scale has ever been learned and GNSS is not carrying the run. The
            // published prior is the only thing left, and it is used rather than
            // reporting nothing — with the flag that says so (DEG-S-2).
            let estimate = model.priorStepLength(stepFrequencyHz: event.stepFrequency)
            metres = estimate?.metres
            if estimate != nil { flags.insert(.usingUncalibratedPrior) }
            if estimate?.wasClamped == true { flags.insert(.stepLengthClamped) }
        }

        fusion.ingestStep(
            metres: metres,
            unscaled: unscaled,
            stepsPerMinute: spm,
            cadenceIsConfident: confident)
    }

    /// Watches sample delivery against the configured rate (AC-FR-S-B-1-4).
    private mutating func trackDelivery(at now: TimeInterval) {
        lastSampleTime = now
        guard let start = starvationWindowStart else {
            starvationWindowStart = now
            deliveredSamples = 1
            return
        }
        deliveredSamples += 1
        let elapsed = now - start
        guard elapsed >= config.sampling.starvationWindowSeconds else { return }
        let expected = elapsed * config.sampling.nominalHz
        if Double(deliveredSamples) < expected * config.sampling.minimumDeliveryFraction {
            flags.insert(.sampleStarvation)
        }
        starvationWindowStart = now
        deliveredSamples = 0
    }
}
