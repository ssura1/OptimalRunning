import Foundation
import CoreLocation
import CoreMotion
import HealthKit
import ORModels
import WatchSupport

/// The real `RunSensorFeed` for this tier: CoreLocation + CoreMotion + HealthKit,
/// reduced to one `EngineInput` per second (T-034, T-036).
///
/// **What is here and what is not.** All of the fusion, the GPS-drought timing, the
/// indoor exclusions, and the `EngineInput` construction happen in
/// `WatchSupport.SensorPipeline`, which is unit-tested and replays all seven shared
/// fixtures against `Core`'s own goldens (AC-FR-K-1-2). This file holds the parts that
/// only a device can exercise: manager configuration, delegate callbacks, and the tick
/// timer. That division is why the tier's behaviour is testable at all.
///
/// Consequently this file is on the manual verification list — see the protocol in
/// `Apps/WatchModern/README.md`.
@MainActor
final class LiveSensorFeed: NSObject, RunSensorFeed {

    var onSample: ((EngineInput) -> Void)?

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()

    private var pipeline: SensorPipeline?
    private var tickTimer: Timer?
    private var startedAt: Date?
    private var isPaused = false

    /// Latest readings, overwritten as callbacks arrive and sampled by the tick.
    ///
    /// Deliberately last-value-wins rather than a queue: the engine wants the runner's
    /// state *now*, once a second. Buffering every CoreLocation callback and replaying
    /// them would deliver a backlog after a stall, which is worse than a fresh reading.
    private var latestLocation: CLLocation?
    private var baselineAltitude: Double?
    private var latestRelativeAltitude: Double?
    private var latestPedometerDistance: Double?
    private var latestHeartRate: Double?
    private var locationDistance: Double = 0
    private var previousLocation: CLLocation?
    private var healthKitDistance: Double?

    /// Horizontal accuracy beyond which a fix is recorded but not trusted to anchor
    /// distance. Matches `RollingPaceConfiguration`'s own threshold, read from
    /// configuration rather than restated (NFR-21).
    private let maxHorizontalAccuracy: Double
    private let capabilities_: SensorCapabilities

    init(configuration: PaceEngineConfiguration = .default) {
        self.maxHorizontalAccuracy = configuration.rollingPace.maxHorizontalAccuracyMetres
        self.capabilities_ = SensorCapabilities(
            hasAltimeter: CMAltimeter.isRelativeAltitudeAvailable(),
            hasGPS: CLLocationManager.locationServicesEnabled(),
            // Every watch this tier supports (Series 4+, watchOS 10) has an always-on
            // display except Series 4 and 5 SE — and watchOS reports the state through
            // `isLuminanceReduced` regardless, so the app renders dimmed variants when
            // told to and never asks the hardware. Reported `true` because the *code
            // path* is present; the display either uses it or does not.
            hasAlwaysOnDisplay: true,
            supportsNativeActivitySegmentation: true,
            // Double Tap is Series 9 and later. There is no public API to query it, and
            // CON-3 forbids an availability check, so the gesture is offered
            // unconditionally and simply never fires on hardware without it — a silent
            // no-op rather than a version test.
            supportsDoubleTap: true
        )
        super.init()

        locationManager.delegate = self
    }

    var capabilities: SensorCapabilities { capabilities_ }

    // MARK: - Lifecycle

    func start(activity: RunActivityKind) throws {
        pipeline = SensorPipeline(activity: activity)
        startedAt = Date()
        isPaused = false

        if activity == .outdoorRun {
            startLocation()
            startAltimeter()
        }
        // The pedometer runs indoors *and* out: outdoors it is the GPS-loss fallback
        // (DEG-1), and it costs nothing to have already been counting when the fix goes.
        startPedometer()

        // A repeating `Timer` on the main run loop, not a `Task` with `sleep`: watchOS
        // keeps the main run loop serviced for the duration of a workout session, which
        // is what makes the 1 Hz cadence survive the screen sleeping (AC-FR-B-1-6).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func pause() {
        isPaused = true
        locationManager.stopUpdatingLocation()
    }

    func resume() {
        isPaused = false
        if pipeline != nil { locationManager.startUpdatingLocation() }
    }

    func stop() async throws -> RunSummary {
        // NFR-8: every subscription released here, and the assertion that this happens
        // lives in `RunSessionModelTests` against a fake feed.
        tickTimer?.invalidate()
        tickTimer = nil
        locationManager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        onSample = nil

        let summary = RunSummary(
            distanceMetres: locationDistance,
            activeSeconds: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
            averagePace: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            elevationGainMetres: 0,
            timeInZoneSeconds: Array(repeating: 0, count: PaceZone.allCases.count)
        )

        pipeline = nil
        startedAt = nil
        return summary
    }

    // MARK: - The tick

    private func tick() {
        guard var pipeline, let startedAt else { return }

        let now = Date().timeIntervalSince(startedAt)
        let fix = latestLocation
        let isUsable = fix.map { $0.horizontalAccuracy > 0
            && $0.horizontalAccuracy <= maxHorizontalAccuracy } ?? false

        let input = pipeline.makeInput(from: RawSensorTick(
            timestamp: now,
            healthKitDistance: healthKitDistance,
            locationDistance: locationDistance,
            pedometerDistance: latestPedometerDistance,
            location: fix.map {
                RawLocationReading(
                    timestamp: now,
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitudeMetres: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            },
            isLocationFixUsable: isUsable,
            relativeAltitude: latestRelativeAltitude,
            heartRate: latestHeartRate,
            // Pause and manual advance are the run controller's to own, not a sensor's
            // — it merges them into the input it receives. See `RunSessionModel.merge`.
            isPaused: false,
            manualAdvanceRequested: false
        ))

        self.pipeline = pipeline
        onSample?(input)
    }

    /// Called by the run controller when HealthKit's builder publishes a new cumulative
    /// distance. Kept as a setter rather than a subscription so the live-workout
    /// plumbing stays in one place (`HealthKitWorkoutBackend`).
    func updateHealthKitDistance(_ metres: Double?) {
        healthKitDistance = metres
    }

    func updateHeartRate(_ bpm: Double?) {
        latestHeartRate = bpm
    }

    // MARK: - Sensor configuration

    private func startLocation() {
        locationManager.requestWhenInUseAuthorization()
        // `.fitness` is not cosmetic: it tells CoreLocation the user is running, which
        // changes its filtering to suit foot speed rather than vehicle speed.
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        // Required for a fix to keep arriving with the screen off during a workout.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
    }

    private func startAltimeter() {
        // DEG-2: an unavailable altimeter disables grade adjustment through
        // `SensorCapabilities` and a `nil` relative altitude, rather than reporting flat
        // ground — which would silently tell the engine every hill is level.
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                self.latestRelativeAltitude = data.relativeAltitude.doubleValue
            }
        }
    }

    private func startPedometer() {
        guard CMPedometer.isDistanceAvailable() else { return }
        // Explicitly typed and `@Sendable` (S-057). `CMPedometerHandler` is an Objective-C
        // block with no `NS_SWIFT_SENDABLE`, so a closure literal here would inherit this
        // type's `@MainActor` isolation with no diagnostic — and unlike the altimeter above,
        // which is delivered `to: .main`, CMPedometer delivers on a background queue. The
        // previous form therefore called `MainActor.assumeIsolated` off the main actor,
        // which is a hard fatal error, not a check that quietly passes.
        //
        // This was found by `Tools/check-sensor-handler-isolation.sh`, written after the
        // same mistake in the phone's capture tool crashed five field recordings. It had
        // never been observed here because the modern watch app has not been run on a real
        // Series 4-or-later device — the Simulator's pedometer never delivers.
        let handler: @Sendable (CMPedometerData?, (any Error)?) -> Void = { [weak self] data, _ in
            guard let metres = data?.distance?.doubleValue else { return }
            Task { @MainActor in self?.latestPedometerDistance = metres }
        }
        pedometer.startUpdates(from: Date(), withHandler: handler)
    }
}

// MARK: - CLLocationManagerDelegate

extension LiveSensorFeed: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            for location in locations {
                // Distance accumulates from *trusted* fixes only. An inaccurate fix is
                // still kept as the latest reading — the route wants it — but must not
                // add metres, or a bad fix in a street canyon invents distance the
                // runner never covered.
                let trusted = location.horizontalAccuracy > 0
                    && location.horizontalAccuracy <= maxHorizontalAccuracy

                if trusted, let previous = previousLocation {
                    let step = location.distance(from: previous)
                    if step.isFinite, step >= 0 { locationDistance += step }
                }
                if trusted { previousLocation = location }
                latestLocation = location
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Deliberately silent. A failed fix is a normal outdoor condition, not an error
        // state: the GPS-drought timeout in `SensorPipeline` already handles sustained
        // loss (DEG-1), and surfacing every transient failure would put a warning on
        // screen for running under a bridge.
    }
}
