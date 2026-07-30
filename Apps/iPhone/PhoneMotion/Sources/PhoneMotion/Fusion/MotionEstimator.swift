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

    /// Instantaneous GNSS speed from the most recent *usable* fix, m/s, with the time it
    /// arrived. The independent witness the carry-position detector needs.
    ///
    /// The timestamp is not decoration. Holding the speed alone made the witness immortal:
    /// during a GNSS outage the last good fix kept testifying that the runner was moving,
    /// so every outage long enough to also lose cadence confidence reported a
    /// carry-position change. The detector's whole premise is a *contradiction between two
    /// live sources*, and a source that stopped reporting is not one.
    private var latestFix: (speed: Double?, at: TimeInterval)?
    /// When the swing signal was last present while the runner was moving.
    private var lastCoherentSwingTime: TimeInterval?
    /// Whether the carry position is currently judged to have changed, so the flag and the
    /// window disqualification fire on the transition rather than on every tick.
    private var carryPositionIsSuspect = false

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

    /// The same calibration in the form anything outside this package is allowed to see.
    public var calibrationSummary: CalibrationSummary {
        fusion.calibration.summary(configuration: config.calibration)
    }

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
        if fix.isUsable(maxHorizontalAccuracy: config.fusion.maxHorizontalAccuracyMetres) {
            latestFix = (fix.speedMetresPerSecond, fix.timestamp)
        }
        fusion.ingest(fix: fix)
    }

    /// Advances the clock and returns the current estimate.
    public mutating func tick(at now: TimeInterval) -> MotionEstimate {
        fusion.tick(at: now)
        detectCarryPositionChange(at: now)
        let current = cadence.current
        return MotionEstimate(
            cumulativeDistanceMetres: fusion.cumulativeMetres,
            source: fusion.source,
            cadenceStepsPerMinute: current.map { $0.stepsPerMinute },
            cadenceConfidence: current?.confidence ?? 0,
            measuredMetres: fusion.measuredMetres,
            estimatedMetres: fusion.estimatedMetres,
            stepCount: stepCount,
            calibration: calibrationSummary,
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

    /// Detects the phone leaving the hand mid-run (DEG-S-7).
    ///
    /// **The signature is a contradiction between two sources, not a threshold on one.**
    /// A hand-held phone swings at stride frequency and produces a strong, stable
    /// periodicity; a pocketed one is quasi-rigidly coupled to the pelvis and produces a
    /// different signal the estimator is not fitted for (ADR-S-04). Cadence confidence
    /// collapsing is therefore *evidence* — but on its own it is also what a traffic light
    /// looks like, and flagging a carry-position change every time a runner stops would
    /// make the flag meaningless.
    ///
    /// GNSS is the witness that separates them: confidence gone **while the runner is
    /// demonstrably still moving** is the pocket case, and confidence gone while they are
    /// stationary is DEG-S-8, which is already handled by the stationary threshold.
    ///
    /// The consequence is deliberately conservative — flag it, and stop the calibrator
    /// learning from the window — rather than switching legs. AC-FR-S-C-1-6's reasoning
    /// applies unchanged: the damage a bad window does to a persisted calibration is
    /// permanent, while a few tens of metres of degraded distance is not. GNSS is already
    /// preferred whenever it is available, which is exactly when this fires.
    private mutating func detectCarryPositionChange(at now: TimeInterval) {
        // Needs a *live* GNSS witness saying the runner is moving. With no recent fix there
        // is no witness, and the honest answer is to make no claim: an outage is already
        // flagged as an outage, and adding a carry-position flag to every underpass would
        // be inventing a second reason for the same event.
        //
        // Staleness is judged against the same dropout window the fusion uses to switch
        // legs, so "GNSS is carrying the run" and "GNSS can witness the carry position" are
        // one condition rather than two that could drift apart.
        guard let latest = latestFix,
            now - latest.at <= config.fusion.gnssDropoutSeconds,
            let speed = latest.speed,
            speed >= config.carry.movingSpeedMetresPerSecond
        else {
            lastCoherentSwingTime = now
            return
        }

        let confidence = cadence.current?.confidence ?? 0
        if confidence >= config.cadence.minimumTrustedConfidence {
            lastCoherentSwingTime = now
            if carryPositionIsSuspect {
                // Recovered. The flag stays on the run — it is a record of what happened —
                // but the calibrator is allowed to learn again.
                carryPositionIsSuspect = false
            }
            return
        }

        guard let since = lastCoherentSwingTime else {
            lastCoherentSwingTime = now
            return
        }
        guard now - since >= config.carry.incoherentSwingSeconds else { return }
        guard !carryPositionIsSuspect else { return }

        carryPositionIsSuspect = true
        flags.insert(.carryPositionChanged)
        fusion.insert(flag: .carryPositionChanged)
        fusion.disqualifyCurrentWindow()
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
