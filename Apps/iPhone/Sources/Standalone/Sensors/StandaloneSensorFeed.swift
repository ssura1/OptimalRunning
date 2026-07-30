import CoreLocation
import CoreMotion
import Foundation
import ORModels
import PhoneMotion

/// Standard gravity, m/s². CoreMotion reports acceleration in g and `PhoneMotion`
/// documents its inputs in m/s², so this is the one conversion between them.
///
/// At file scope rather than as a `static let` on the feed, because a static on a
/// `@MainActor` type is itself main-actor isolated — and the sensor handler that needs it
/// is a `@Sendable` closure running on a background queue, which is precisely the isolation
/// `Tools/check-sensor-handler-isolation.sh` exists to keep honest. The compiler caught
/// this; it is recorded here so the next person does not "tidy" it back inside.
private let standardGravity = 9.80665

/// The standalone tier's `RunSensorFeed`: CoreMotion + CoreLocation + CMAltimeter, reduced
/// to one `EngineInput` and one `MotionTelemetry` per second (S-031).
///
/// **What is here and what is not.** Every judgement — distance accumulation, the fix
/// accuracy rule, the estimated/measured split, cadence — lives in `MotionPipeline`, which
/// is replayed against committed traces. This file holds manager configuration, delegate
/// callbacks and the tick timer: the parts only a device can exercise, and therefore the
/// parts on the manual protocol rather than in CI (CON-S-1).
///
/// The same division as `WatchModern`'s `LiveSensorFeed`, for the same reason, and it
/// matters more here — the Simulator has no accelerometer at all, so a feed that did its
/// own arithmetic would be a feed whose arithmetic was never run before a device saw it.
@MainActor
final class StandaloneSensorFeed: NSObject, MotionTelemetryReporting {

    var onSample: ((EngineInput) -> Void)?
    var onTelemetry: ((MotionTelemetry) -> Void)?

    private let motion = CMMotionManager()
    private let locations = CLLocationManager()
    private let altimeter = CMAltimeter()
    /// Device motion is delivered here, not to `.main`. At 100 Hz a main-queue delivery
    /// would put the whole gait filter chain on the thread that also draws the screen,
    /// which AC-FR-S-B-1-5 forbids.
    private let motionQueue = OperationQueue()

    private let pipeline: SynchronizedPipeline
    private let configuration: MotionEstimationConfiguration
    private let activity: RunActivityKind

    private var tickTimer: Timer?
    private var startedAtUptime: TimeInterval?
    private var isPaused = false

    /// Latest readings, overwritten as callbacks arrive and sampled by the tick.
    /// Last-value-wins rather than a queue, for the reason `LiveSensorFeed` gives: the
    /// engine wants the runner's state *now*, and replaying a backlog after a stall is
    /// worse than a fresh reading.
    private var latestFix: RawFix?
    private var latestRelativeAltitude: Double?

    private let capabilities_: SensorCapabilities

    init(
        configuration: MotionEstimationConfiguration = .default,
        activity: RunActivityKind,
        carryPosition: CarryPosition = .handHeld,
        runnerHeightMetres: Double?,
        calibration: Data?
    ) {
        self.configuration = configuration
        self.activity = activity
        self.pipeline = SynchronizedPipeline(MotionPipeline(
            configuration: configuration,
            activity: activity,
            carryPosition: carryPosition,
            runnerHeightMetres: runnerHeightMetres,
            calibration: calibration))

        self.capabilities_ = SensorCapabilities(
            hasAltimeter: CMAltimeter.isRelativeAltitudeAvailable(),
            hasGPS: CLLocationManager.locationServicesEnabled(),
            // A phone screen is never on when it is not being looked at, and the
            // always-on-display machinery is a watch concept. Reported `false` so the
            // dimmed-swatch path is never taken here (AC-FR-B-2-5 is a watch requirement).
            hasAlwaysOnDisplay: false,
            // No `HKWorkoutSession` at this floor, so nothing native segments the workout
            // — the builder records step boundaries as workout events instead (S-033).
            supportsNativeActivitySegmentation: false,
            supportsDoubleTap: false,
            // ADR-S-02, design.md §7.2: GNSS is primary and this project's own model is
            // the fallback, which is a different claim from either "measured" alone or
            // "estimated" alone.
            distance: .measuredWithEstimatedFallback,
            // CON-S-2: `HKWorkoutSession`'s local initializer is iOS 26. `HKWorkoutBuilder`
            // has been available since iOS 12 and writes the same workout, which is why
            // this is a three-state enum and not a boolean (ADR-S-02).
            workoutSession: .builderOnly)

        super.init()

        motionQueue.name = "com.optimalrunner.standalone.motion"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInitiated
        locations.delegate = self
    }

    var capabilities: SensorCapabilities { capabilities_ }

    /// The calibration to persist when the run ends (AC-FR-S-C-2-2). Opaque bytes — see
    /// `CalibrationStoring`.
    var calibrationPayload: Data? { pipeline.calibrationPayload }

    var averageCadenceStepsPerMinute: Double? { pipeline.averageCadenceStepsPerMinute }
    var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] { pipeline.estimatedSpans }

    // MARK: - Lifecycle

    func start(activity: RunActivityKind) throws {
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        isPaused = false

        if activity == .outdoorRun {
            startLocation()
            startAltimeter()
        }
        startMotion()

        // A repeating `Timer` on the main run loop rather than a `Task` with `sleep`: the
        // run loop is serviced for the duration of a run because the `location` background
        // mode keeps the process alive (CON-S-4), and a timer is the thing that survives
        // the screen locking. Verified on device, not assumed — it is on the manual
        // protocol precisely because CI cannot lock a screen.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func pause() {
        isPaused = true
        locations.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if activity == .outdoorRun { locations.startUpdatingLocation() }
        startMotion()
    }

    /// Stops the feed and releases every sensor (AC-FR-S-A-2-3, NFR-S-6).
    ///
    /// The audio session is *not* deactivated here — it belongs to the cue engine, which
    /// the run controller tears down alongside this. Splitting them means neither one can
    /// leave the other running, which is what the teardown test checks.
    func stop() async throws -> RunSummary {
        tickTimer?.invalidate()
        tickTimer = nil
        locations.stopUpdatingLocation()
        locations.allowsBackgroundLocationUpdates = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        onSample = nil
        onTelemetry = nil

        let elapsed = startedAtUptime
            .map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        startedAtUptime = nil

        // Totals only, and deliberately thin: the run's real summary is built by
        // `StandaloneWorkoutComposer` from the engine's own output stream, so that a
        // standalone run's numbers are derived exactly as a watch run's are.
        return RunSummary(
            distanceMetres: pipeline.lastCumulativeDistance,
            activeSeconds: elapsed,
            averagePace: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            elevationGainMetres: 0,
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count))
    }

    /// Whether any sensor is still attached. Backs the teardown assertion of
    /// AC-FR-S-A-2-3 on device, where the fake-feed test cannot reach.
    var isFullyStopped: Bool {
        tickTimer == nil && !motion.isDeviceMotionActive
    }

    // MARK: - The tick

    private func tick() {
        guard !isPaused, let startedAtUptime else { return }
        let now = ProcessInfo.processInfo.systemUptime - startedAtUptime

        let fix = latestFix
        let result = pipeline.tick(
            at: now,
            location: fix?.locationSample,
            relativeAltitude: latestRelativeAltitude)

        // Sample first, telemetry second, always. A consumer that rebuilds its screen on
        // telemetry must already have the engine output for the same second, or the screen
        // shows this second's cadence against last second's pace.
        onSample?(result.input)
        onTelemetry?(result.telemetry)
    }

    // MARK: - Sensor configuration

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            // DEG-S-3 taken to its limit: no motion hardware at all. The run continues on
            // GNSS alone (AC-FR-S-A-1-5) rather than refusing, and the absence shows up as
            // no cadence rather than as a zero.
            return
        }
        motion.deviceMotionUpdateInterval = 1 / configuration.sampling.nominalHz

        // Explicitly typed and `@Sendable`, never a trailing closure (S-057).
        // `CMDeviceMotionHandler` is an Objective-C block with no `NS_SWIFT_SENDABLE`, so a
        // closure literal written inside this `@MainActor` type would inherit main-actor
        // isolation with no diagnostic and trap the moment CoreMotion invoked it on
        // `motionQueue`. That bug killed five field captures before
        // `Tools/check-sensor-handler-isolation.sh` existed; the gate now fails the build
        // on the form that caused it.
        let pipeline = self.pipeline
        let handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void = { data, _ in
            guard let data else { return }
            pipeline.ingest(motion: MotionSample(
                timestamp: data.timestamp,
                // CoreMotion reports acceleration in g. The conversion to m/s² happens
                // once, here, at the adapter — `PhoneMotion` documents its inputs as m/s²
                // so no reader downstream has to remember which unit they are holding.
                userAcceleration: Vector3(
                    x: data.userAcceleration.x * standardGravity,
                    y: data.userAcceleration.y * standardGravity,
                    z: data.userAcceleration.z * standardGravity),
                gravity: Vector3(
                    x: data.gravity.x * standardGravity,
                    y: data.gravity.y * standardGravity,
                    z: data.gravity.z * standardGravity),
                rotationRate: Vector3(
                    x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z)))
        }
        motion.startDeviceMotionUpdates(
            using: .xArbitraryZVertical, to: motionQueue, withHandler: handler)
    }

    private func startLocation() {
        locations.requestWhenInUseAuthorization()
        // Not cosmetic: `.fitness` tells CoreLocation the user is running, which changes
        // its filtering to suit foot speed rather than vehicle speed.
        locations.activityType = .fitness
        locations.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locations.distanceFilter = kCLDistanceFilterNone
        // AC-FR-S-A-2-2 — both of these, for the duration of the run only. Without the
        // first, fixes stop the moment the screen locks; without the second, iOS pauses
        // updates when it decides the user has stopped moving, which during a traffic-light
        // wait is exactly wrong.
        locations.allowsBackgroundLocationUpdates = true
        locations.pausesLocationUpdatesAutomatically = false
        locations.startUpdatingLocation()
    }

    private func startAltimeter() {
        // DEG-2: an unavailable altimeter disables grade adjustment through a `nil`
        // relative altitude rather than reporting flat ground, which would silently tell
        // the engine every hill is level.
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        // Delivered `to: .main`, so a closure literal here is correctly main-actor isolated
        // — which is why `check-sensor-handler-isolation.sh` exempts main-queue delivery
        // rather than banning the form outright.
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                self.latestRelativeAltitude = data.relativeAltitude.doubleValue
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension StandaloneSensorFeed: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            guard let startedAtUptime else { return }
            for location in locations {
                // Stamped with the fix's own time, converted to session-relative seconds.
                // Using the arrival time instead is what produced the S-060 double-count:
                // CoreLocation replays a buffered backlog when GNSS returns, and a backlog
                // fix that claims to have happened *now* bills the motion leg's stretch a
                // second time.
                let uptimeOfFix = location.timestamp.timeIntervalSinceNow
                    + ProcessInfo.processInfo.systemUptime
                let fix = RawFix(
                    timestamp: uptimeOfFix - startedAtUptime,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitudeMetres: location.altitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    verticalAccuracy: location.verticalAccuracy,
                    // CoreLocation reports a negative speed when it has none. Passing that
                    // through as a number would have the fusion layer reasoning about a
                    // runner travelling backwards.
                    speedMetresPerSecond: location.speed >= 0 ? location.speed : nil)
                pipeline.ingest(fix: fix)
                latestFix = fix
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Deliberately silent. A failed fix is a normal outdoor condition, not an error
        // state: sustained loss is DEG-S-1 and the fusion layer already handles it by
        // switching legs, and surfacing every transient failure would put a warning on
        // screen for running under a bridge.
    }
}

// MARK: - Synchronization

/// Serialises access to the pipeline across the two threads that touch it.
///
/// Device motion arrives at 100 Hz on a background queue and the tick runs on the main
/// actor once a second. Hopping every motion sample to the main actor would put the filter
/// chain on the UI thread (AC-FR-S-B-1-5 forbids it) and would enqueue a hundred
/// continuations a second to do it. A lock is the right tool: the critical sections are a
/// few microseconds of arithmetic and there is no `await` inside one.
///
/// `MotionPipeline` stays a `struct` so it can be replayed deterministically in tests with
/// no locking at all; this class exists only where two threads are real.
private final class SynchronizedPipeline: @unchecked Sendable {

    private let lock = NSLock()
    private var pipeline: MotionPipeline
    private var lastDistance = 0.0

    init(_ pipeline: MotionPipeline) {
        self.pipeline = pipeline
    }

    func ingest(motion sample: MotionSample) {
        lock.lock(); defer { lock.unlock() }
        pipeline.ingest(motion: sample)
    }

    func ingest(fix: RawFix) {
        lock.lock(); defer { lock.unlock() }
        pipeline.ingest(fix: fix)
    }

    func tick(
        at now: TimeInterval, location: LocationSample?, relativeAltitude: Double?
    ) -> (input: EngineInput, telemetry: MotionTelemetry) {
        lock.lock(); defer { lock.unlock() }
        let result = pipeline.tick(
            at: now, location: location, relativeAltitude: relativeAltitude)
        lastDistance = result.input.cumulativeDistance
        return result
    }

    var calibrationPayload: Data? {
        lock.lock(); defer { lock.unlock() }
        return pipeline.calibrationPayload
    }

    var averageCadenceStepsPerMinute: Double? {
        lock.lock(); defer { lock.unlock() }
        return pipeline.averageCadenceStepsPerMinute
    }

    var estimatedSpans: [StandaloneRunFacts.EstimatedSpan] {
        lock.lock(); defer { lock.unlock() }
        return pipeline.estimatedSpans
    }

    var lastCumulativeDistance: Double {
        lock.lock(); defer { lock.unlock() }
        return lastDistance
    }
}
