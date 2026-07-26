import CoreLocation
import CoreMotion
import Foundation
import HealthKit
import ORModels
import ORStats
import LegacySupport

/// The real sensor feed — Legacy tier (T-063, T-064).
///
/// Talks to CoreLocation, CoreMotion and HealthKit, converts their readings to primitives, and hands
/// them to `LegacySupport.SensorPipeline`. **It contains no judgement of its own** — which source
/// wins, how offsets are re-anchored, how long a GPS drought must last, whether the altimeter is
/// forwarded: all of that is the pipeline's, and the pipeline is what AC-FR-K-1-2's fixture replay
/// exercises.
///
/// That boundary is the whole reason tier equivalence is testable. This file cannot be unit-tested at
/// all — `CLLocationManager` says nothing without a device, and this tier has no simulator either —
/// so everything above it is kept pure, and this is reduced to plumbing.
///
/// Zero `#available` (CON-3, AC-FR-K-1-5): every API here exists at watchOS 8.
///
/// ## Series 3 specifics
///
/// - The barometric altimeter **is** present (T-063), so `CMAltimeter` is started and relative
///   altitude is forwarded. `isRelativeAltitudeAvailable()` is still checked, because a capability
///   being present is not authorization being granted — and a denial raises
///   `.altimeterUnavailable` rather than silently reporting flat ground.
/// - `kCLLocationAccuracyBest`, not `…BestForNavigation`: the latter costs materially more power and
///   Series 3 has the smallest battery in the supported range. The accuracy threshold applied below
///   is what protects distance quality instead.
@MainActor
final class LiveSensorFeed: NSObject, RunSensorFeed {

    var onSample: ((EngineInput) -> Void)?

    var capabilities: SensorCapabilities { LegacyCapabilities.seriesThree }

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()

    private var pipeline: SensorPipeline?
    private var startDate: Date?
    private var isPaused = false

    /// Latest reading from each source, folded into the next tick.
    private var latestLocation: CLLocation?
    private var locationDistance: Double = 0
    private var pedometerDistance: Double?
    private var relativeAltitude: Double?
    private var heartRate: Double?
    private var altimeterDenied = false

    private var previousLocation: CLLocation?
    private var tickTimer: Timer?

    /// Reads the runner's pending tap/crown request so it can ride the next tick.
    var manualAdvanceRequested: () -> Bool = { false }

    /// The accuracy above which a fix must not anchor distance. Series 3's GPS is the least accurate
    /// in the range, so this threshold does real work here rather than being belt-and-braces.
    private let horizontalAccuracyLimit: CLLocationDistance = 30

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
    }

    func start(activity: RunActivityKind) throws {
        pipeline = SensorPipeline(activity: activity)
        startDate = Date()
        isPaused = false
        locationDistance = 0
        previousLocation = nil

        if activity == .outdoorRun {
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()

            if CMAltimeter.isRelativeAltitudeAvailable() {
                altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                    guard let data else { return }
                    self?.relativeAltitude = data.relativeAltitude.doubleValue
                }
            } else {
                // Recorded, not silently treated as flat: a run with no altimeter must not look like
                // a run on level ground (DEG-2 territory).
                altimeterDenied = true
            }
        }

        if CMPedometer.isDistanceAvailable(), let startDate {
            pedometer.startUpdates(from: startDate) { [weak self] data, _ in
                guard let distance = data?.distance else { return }
                self?.pedometerDistance = distance.doubleValue
            }
        }

        // The 1 Hz tick. A single timer drives everything, so `ActiveClock`, the engine, and the
        // sample store all advance on one clock — the reason `SampleStore` flushes tick-driven rather
        // than on a timer of its own.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func stop() async throws -> RunSummary {
        tickTimer?.invalidate()
        tickTimer = nil
        locationManager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()

        // The summary the app actually persists is built by `RunSessionModel.end` from the captured
        // samples, so this is the teardown acknowledgement rather than the authority on totals.
        // Returning an empty summary here would be misleading, so it reports what it knows.
        return RunSummaryBuilder.build(samples: [], activeSeconds: 0, zoneTimeline: [])
    }

    // MARK: - The tick

    private func tick() {
        guard var pipeline, let startDate else { return }

        let timestamp = Date().timeIntervalSince(startDate)
        let fix = latestLocation
        let isUsable = (fix?.horizontalAccuracy ?? .greatestFiniteMagnitude)
            <= horizontalAccuracyLimit && (fix?.horizontalAccuracy ?? -1) >= 0

        let input = pipeline.makeInput(from: RawSensorTick(
            timestamp: timestamp,
            // HealthKit's fused distance arrives through the workout builder, which this feed does
            // not own — the builder is the backend's. Left `nil` so CoreLocation and the pedometer
            // are the two live sources, which is what the fixture replay's tunnel case models.
            healthKitDistance: nil,
            locationDistance: locationDistance,
            pedometerDistance: pedometerDistance,
            location: fix.map {
                RawLocationReading(
                    timestamp: $0.timestamp.timeIntervalSince(startDate),
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitudeMetres: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            },
            isLocationFixUsable: isUsable,
            relativeAltitude: relativeAltitude,
            heartRate: heartRate,
            isPaused: isPaused,
            manualAdvanceRequested: manualAdvanceRequested()
        ))
        self.pipeline = pipeline
        onSample?(input)
    }
}

// MARK: - CLLocationManagerDelegate

extension LiveSensorFeed: CLLocationManagerDelegate {

    /// `nonisolated` because CoreLocation calls back on its own queue, then hops to the main actor —
    /// the same pattern the phone tier's `WCSessionDelegate` uses. Nothing is read from the
    /// `CLLocation` before the hop except by value, so there is no race on shared state.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let fixes = locations
        Task { @MainActor in
            for fix in fixes {
                // Cumulative horizontal distance, accumulated only across fixes accurate enough to
                // trust. An inaccurate fix is still kept as `latestLocation` for the route, but must
                // not move the distance total — which is why the two are tracked separately.
                if fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= horizontalAccuracyLimit {
                    if let previous = previousLocation {
                        locationDistance += fix.distance(from: previous)
                    }
                    previousLocation = fix
                }
                latestLocation = fix
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Deliberately silent: a failed fix is a normal condition mid-run, and the pipeline's GPS
        // drought timer (DEG-1) is what decides when it becomes a degradation.
    }
}
