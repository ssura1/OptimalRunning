import Foundation
import ORModels
import PhoneMotion

/// Turns raw sensor readings into the `EngineInput` and `MotionTelemetry` a standalone run
/// is driven by (S-031).
///
/// **This is one of the two files in the app that may import `PhoneMotion`**, and the
/// division of labour between it and `StandaloneSensorFeed` is the same one
/// `WatchSupport.SensorPipeline` established for the watch: everything that is a decision
/// lives here, where it can be replayed against a recorded trace, and everything that is a
/// framework callback lives in the feed, where only a device can exercise it.
///
/// That split is not stylistic here — it is what makes the boundary provable. The
/// acceptance test for ADR-S-01 replays `Fixtures/motion/capture-2026-07-28-1918.motion.json`
/// through this type twice with different estimator configurations and asserts that the run
/// list, the statistics and the live screen all move. It could not do that against a type
/// that needed a `CMMotionManager`.
///
/// A `struct`, deliberately, and `mutating` throughout: the estimator is a value and the
/// pipeline is a value, so a replay is a fold over samples with no shared state to reset
/// between runs. `MotionEstimator` is documented as pure and this preserves that upwards.
struct MotionPipeline {

    /// What the estimator was configured with. Held so the feed can report it and so a
    /// test can assert that a swapped configuration is the one in force.
    let configuration: MotionEstimationConfiguration
    let carryPosition: CarryPosition

    private var estimator: MotionEstimator
    private let activity: RunActivityKind

    /// Cumulative horizontal distance along the track, accumulated from trusted fixes.
    /// The estimator wants a cumulative rather than per-fix deltas, so the accumulation
    /// happens once, here, rather than in both this type and the fusion layer.
    private var locationDistanceMetres = 0.0
    private var previousFix: (latitude: Double, longitude: Double)?
    private var previousPlanarFix: (east: Double, north: Double)?
    private var baselineAltitude: Double?

    // Telemetry accumulators.
    private var cadenceSum = 0.0
    private var cadenceCount = 0
    private var estimatedSpanStart: TimeInterval?
    private var closedSpans: [StandaloneRunFacts.EstimatedSpan] = []
    private var lastTickTimestamp: TimeInterval = 0

    init(
        configuration: MotionEstimationConfiguration = .default,
        activity: RunActivityKind,
        carryPosition: CarryPosition = .handHeld,
        runnerHeightMetres: Double?,
        calibration: Data?
    ) {
        self.configuration = configuration
        self.activity = activity
        self.carryPosition = carryPosition
        self.estimator = MotionEstimator(
            configuration: configuration,
            carryPosition: carryPosition,
            runnerHeightMetres: runnerHeightMetres,
            calibration: CalibrationBridge.decode(calibration))
    }

    // MARK: - Input

    mutating func ingest(motion sample: MotionSample) {
        estimator.ingest(sample)
    }

    /// Feeds one position fix, in the framework-free form the feed converts to.
    ///
    /// The distance accumulation is here rather than in the feed because it is arithmetic
    /// with a rule in it — an inaccurate fix is recorded for the route but must not add
    /// metres, or a bad fix in a street canyon invents distance the runner never covered.
    /// That rule is testable; a delegate callback is not.
    mutating func ingest(fix: RawFix) {
        var step: Double?
        if let previous = previousFix {
            step = Self.haversineMetres(
                fromLatitude: previous.latitude, longitude: previous.longitude,
                toLatitude: fix.latitude, longitude: fix.longitude)
        }
        let trusted = advance(
            step: step,
            horizontalAccuracy: fix.horizontalAccuracy,
            timestamp: fix.timestamp,
            speed: fix.speedMetresPerSecond)
        if trusted { previousFix = (fix.latitude, fix.longitude) }
    }

    /// The same, for a fix expressed as a displacement from the recording's own origin.
    ///
    /// Every committed trace has been through `Tools/scrub-trace.swift`, which replaces
    /// latitude and longitude with `eastMetres`/`northMetres` measured from the trace's
    /// first fix (NFR-S-16, S-059). Displacement, shape, bearing change and turn radius all
    /// survive; the origin does not.
    ///
    /// So replaying one has to enter here rather than through `ingest(fix:)`, and the
    /// alternative — inventing a plausible origin and converting back to coordinates —
    /// would be manufacturing the exact quantity the scrubber exists to destroy. Both
    /// entry points share `advance`, so the accuracy rule and the accumulation are the
    /// same code on both paths and the replay cannot drift from the live one.
    mutating func ingest(planarFix fix: PlanarFix) {
        var step: Double?
        if let previous = previousPlanarFix {
            let de = fix.eastMetres - previous.east
            let dn = fix.northMetres - previous.north
            step = (de * de + dn * dn).squareRoot()
        }
        let trusted = advance(
            step: step,
            horizontalAccuracy: fix.horizontalAccuracy,
            timestamp: fix.timestamp,
            speed: fix.speedMetresPerSecond)
        if trusted { previousPlanarFix = (fix.eastMetres, fix.northMetres) }
    }

    /// Accumulates a trusted step and hands the fix to the estimator. Returns whether the
    /// fix was trusted, so the caller knows whether to anchor on it.
    ///
    /// An inaccurate fix is still passed on — the fusion layer decides what to do with it —
    /// but must not add metres, or a bad fix in a street canyon invents distance the runner
    /// never covered.
    private mutating func advance(
        step: Double?, horizontalAccuracy: Double, timestamp: TimeInterval, speed: Double?
    ) -> Bool {
        let trusted = horizontalAccuracy >= 0
            && horizontalAccuracy <= configuration.fusion.maxHorizontalAccuracyMetres
        if trusted, let step, step.isFinite, step >= 0 {
            locationDistanceMetres += step
        }
        estimator.ingest(LocationFix(
            timestamp: timestamp,
            cumulativeDistanceMetres: locationDistanceMetres,
            horizontalAccuracy: horizontalAccuracy,
            speedMetresPerSecond: speed))
        return trusted
    }

    /// Records the altimeter baseline on first reading, so relative altitude is measured
    /// from the run's own start rather than from an absolute datum (DEG-2's `nil` case is
    /// the caller passing nothing at all).
    mutating func ingest(absoluteAltitude metres: Double) {
        if baselineAltitude == nil { baselineAltitude = metres }
    }

    // MARK: - Output

    /// One tick. Returns what `Core` judges the run by, and what the tier reports about
    /// itself.
    ///
    /// The two are deliberately separate values rather than one: `EngineInput` is the
    /// contract every tier satisfies and `RunEngine` must stay blind to how distance was
    /// obtained (AC-FR-S-C-1-1), while the telemetry is what the screen, the store and the
    /// workout writer need and the engine must never see.
    mutating func tick(
        at now: TimeInterval,
        location: LocationSample?,
        relativeAltitude: Double?
    ) -> (input: EngineInput, telemetry: MotionTelemetry) {
        lastTickTimestamp = now
        let estimate = estimator.tick(at: now)

        if let spm = estimate.cadenceStepsPerMinute, spm.isFinite, spm > 0 {
            cadenceSum += spm
            cadenceCount += 1
        }
        trackEstimatedSpan(source: estimate.source, at: now)

        // CON-S-8 — indoors there is **no distance**, not a suppressed one.
        //
        // A treadmill's belt gives the phone nothing to measure against: the arm still
        // swings and the step-length model still produces metres, but the runner has not
        // displaced, so those metres describe nothing. Reporting them and hiding them on
        // the screen would be worse than reporting nothing — the split announcer would call
        // out miles that were never covered, and the stored run would carry a distance
        // whose only provenance is a model applied outside its domain (ADR-S-06's principle
        // exactly).
        //
        // Zeroed here rather than at each consumer, so there is one place indoors means
        // what it says and no surface can disagree with another about it.
        let distance = activity == .outdoorRun ? estimate.cumulativeDistanceMetres : 0

        let input = EngineInput(
            timestamp: now,
            cumulativeDistance: distance,
            // Indoors there is no route and no fix worth carrying — CON-S-8 puts indoor
            // standalone out of scope for distance entirely, and the run controller
            // suppresses it, but passing a fix here would let one leak into the record.
            location: activity == .outdoorRun ? location : nil,
            relativeAltitude: relativeAltitude,
            // AC-FR-S-A-4-3 / DEG-S-4: there is no heart rate on this tier and none is
            // invented. `nil` travels all the way to the statistics screen as `--`.
            heartRate: nil,
            isPaused: false,
            manualAdvanceRequested: false,
            distanceSource: estimate.source)

        let telemetry = MotionTelemetry(
            cadenceStepsPerMinute: estimate.cadenceStepsPerMinute,
            cadenceConfidence: estimate.cadenceConfidence,
            stepCount: estimate.stepCount,
            measuredMetres: estimate.measuredMetres,
            estimatedMetres: estimate.estimatedMetres,
            calibration: estimate.calibration,
            flags: estimate.flags)

        return (input, telemetry)
    }

    /// The calibration to persist, as opaque bytes (AC-FR-S-C-2-2).
    var calibrationPayload: Data? { CalibrationBridge.encode(estimator.calibration) }

    /// Mean cadence over the ticks that had one, or `nil` when none did.
    var averageCadenceStepsPerMinute: Double? {
        cadenceCount > 0 ? cadenceSum / Double(cadenceCount) : nil
    }

    /// The stretches whose distance came from the motion model, with any span still open
    /// closed at the last tick — so a run that ends mid-outage records the outage.
    var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] {
        guard let open = estimatedSpanStart else { return closedSpans }
        return closedSpans + [.init(startSeconds: open, endSeconds: lastTickTimestamp)]
    }

    // MARK: - Private

    private mutating func trackEstimatedSpan(source: DistanceSource, at now: TimeInterval) {
        switch (source.isEstimated, estimatedSpanStart) {
        case (true, nil):
            estimatedSpanStart = now
        case (false, .some(let start)):
            closedSpans.append(.init(startSeconds: start, endSeconds: now))
            estimatedSpanStart = nil
        default:
            break
        }
    }

    /// Great-circle distance between two fixes, metres.
    ///
    /// Written out rather than taken from `CLLocation.distance(from:)` so this type stays
    /// free of CoreLocation and can therefore be replayed from a trace on the test host.
    /// The haversine is exact enough by a wide margin at the scale involved: successive
    /// fixes during a run are metres apart, where the difference from a geodesic
    /// calculation is well under a millimetre.
    static func haversineMetres(
        fromLatitude lat1: Double, longitude lon1: Double,
        toLatitude lat2: Double, longitude lon2: Double
    ) -> Double {
        let radius = 6_371_008.8  // IUGG mean Earth radius, metres.
        let toRadians = Double.pi / 180
        let phi1 = lat1 * toRadians
        let phi2 = lat2 * toRadians
        let deltaPhi = (lat2 - lat1) * toRadians
        let deltaLambda = (lon2 - lon1) * toRadians
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

// MARK: - Raw input

/// One position fix as the feed reads it off `CLLocation`.
///
/// Distinct from `ORModels.LocationSample` because the pipeline needs instantaneous speed
/// and `Core` does not, and distinct from `PhoneMotion.LocationFix` because that one
/// carries a cumulative distance this type is responsible for computing.
struct RawFix {
    let timestamp: TimeInterval
    let latitude: Double
    let longitude: Double
    let altitudeMetres: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speedMetresPerSecond: Double?

    /// The `Core` form, for the route and the pace engine's window anchoring.
    var locationSample: LocationSample {
        LocationSample(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            altitudeMetres: altitudeMetres,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy)
    }
}

/// A fix from a scrubbed recording: a displacement from the trace's own origin, with no
/// coordinate anywhere (NFR-S-16).
struct PlanarFix {
    let timestamp: TimeInterval
    let eastMetres: Double
    let northMetres: Double
    let horizontalAccuracy: Double
    let speedMetresPerSecond: Double?
}

// MARK: - Calibration

/// Moves a calibration between the estimator and whatever stores it, as bytes.
///
/// The whole type exists so that `CalibrationStoring` can be declared in `ORModels` over
/// `Data` (see its own documentation): the encoded shape belongs to the estimator and will
/// change when S-064 is resolved, and a store that knew the field names would have to
/// change with it.
enum CalibrationBridge {

    static func decode(_ payload: Data?) -> CalibrationState {
        guard let payload,
            let state = try? JSONDecoder().decode(CalibrationState.self, from: payload)
        else {
            // A calibration that cannot be read is treated as absent rather than as an
            // error. ADR-S-06's fallback is already "report no motion distance until one
            // is learned", which is the correct behaviour for a corrupt payload too, and
            // refusing to start a run over it would be a worse answer than relearning in
            // the first hundred metres.
            return CalibrationState()
        }
        return state
    }

    static func encode(_ state: CalibrationState) -> Data? {
        guard state.scale != nil else { return nil }
        return try? JSONEncoder().encode(state)
    }

    /// What the settings screen shows without a run in progress (AC-FR-S-G-1-3).
    static func summary(
        of payload: Data?,
        configuration: MotionEstimationConfiguration = .default
    ) -> CalibrationSummary {
        decode(payload).summary(configuration: configuration.calibration)
    }
}
