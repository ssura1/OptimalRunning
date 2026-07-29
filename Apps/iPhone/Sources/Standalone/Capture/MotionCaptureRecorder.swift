import CoreLocation
import CoreMotion
import Foundation
import PhoneMotion
import UIKit

/// Records raw motion, location and pedometer streams to a file on device (S-006,
/// FR-S-F-1).
///
/// **This is the prerequisite for everything else on this track.** The iOS Simulator has
/// no accelerometer and no gyroscope, and unlike GPS there is no GPX-equivalent to fake
/// them (CON-S-1), so every accuracy figure the standalone tier claims has to come from a
/// file this produces or it is not a figure, it is a hope. It occupies the same position
/// here that the seven recorded traces occupy in the core track's Wave 1.
///
/// Deliberately a developer tool rather than a product surface (AC-FR-S-F-1-9): reachable
/// on purpose, not discoverable by accident.
///
/// ## Ownership (S-056)
///
/// **This object must outlive the capture screen.** It was previously a `@StateObject`
/// inside `MotionCaptureView`, which is a `NavigationLink` destination — so navigating away
/// from the screen destroyed the recorder, released `CMMotionManager`, and ended the
/// capture without ever calling `finish`. A runner who opened the screen to press MARK and
/// went back found the recording silently over and no assembled trace on disk. It is now
/// owned by the app and injected, so the capture's lifetime is the *capture's*, not a
/// view's.
@MainActor
final class MotionCaptureRecorder: NSObject, ObservableObject {

    // MARK: - Observable state

    @Published private(set) var isRecording = false
    @Published private(set) var motionSampleCount = 0
    @Published private(set) var locationFixCount = 0
    @Published private(set) var markCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    /// Finished captures, newest first.
    @Published private(set) var captures: [URL] = []

    // MARK: - Framework objects

    private let motion = CMMotionManager()
    private let locations = CLLocationManager()
    private let pedometer = CMPedometer()
    private let queue = OperationQueue()

    // MARK: - Capture state

    /// The serial destination for every record. See `CaptureSink` for why capture work is
    /// kept off the main thread entirely.
    private let sink = CaptureSink()
    private var startedAt: Date?
    private var startUptime: TimeInterval = 0
    private var displayTimer: Timer?
    private var cumulativeLocationMetres = 0.0
    private var previousLocation: CLLocation?
    private var runnerHeightMetres: Double?

    /// The rate the capture runs at, independent of whatever a live run would use.
    ///
    /// 100 Hz for capture regardless of QS-5's open question about the live rate: the
    /// whole point of a trace is to be able to answer that question later by
    /// decimating it, and a trace recorded at 50 Hz can never be turned back into one
    /// recorded at 100.
    private let sampleRateHz: Double = 100

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        locations.delegate = self
        refreshCaptures()
    }

    // MARK: - Availability

    /// What this device can actually record. On the Simulator the answer is "nothing",
    /// which is the finding CON-S-1 rests on and is surfaced rather than hidden.
    var availability: String {
        var parts: [String] = []
        parts.append("device motion: \(motion.isDeviceMotionAvailable ? "yes" : "NO")")
        parts.append("accelerometer: \(motion.isAccelerometerAvailable ? "yes" : "NO")")
        parts.append("gyroscope: \(motion.isGyroAvailable ? "yes" : "NO")")
        parts.append("pedometer: \(CMPedometer.isStepCountingAvailable() ? "yes" : "no")")
        return parts.joined(separator: "\n")
    }

    var canRecord: Bool { motion.isDeviceMotionAvailable }

    /// Whether location is authorised well enough to survive the screen locking.
    ///
    /// Surfaced because its absence is invisible until it matters: without authorisation
    /// the `location` background mode cannot keep the process alive (CON-S-4), so the
    /// capture ends the moment the phone sleeps — an hour into a run, with no error.
    var locationWarning: String? {
        switch locations.authorizationStatus {
        case .denied, .restricted:
            return "Location is denied, so recording will stop when the screen locks. "
                + "Enable it in Settings › Privacy › Location Services."
        case .notDetermined:
            return nil
        default:
            return nil
        }
    }

    // MARK: - Lifecycle

    func start(runnerHeightMetres height: Double?) {
        guard !isRecording else { return }
        guard canRecord else {
            lastError = "No device motion on this hardware. The Simulator has no "
                + "accelerometer or gyroscope at all (CON-S-1) — this needs a real phone."
            return
        }
        lastError = nil
        runnerHeightMetres = height
        motionSampleCount = 0
        locationFixCount = 0
        markCount = 0
        cumulativeLocationMetres = 0
        previousLocation = nil

        let now = Date()
        startedAt = now
        startUptime = ProcessInfo.processInfo.systemUptime

        do {
            _ = try sink.begin(startedAt: now)
        } catch {
            lastError = "cannot open capture file: \(error.localizedDescription)"
            return
        }

        startMotion()
        startLocation()
        startPedometer()

        // The one control that matters here has to be reachable, and a screen that has
        // slept puts Face ID and a passcode between the runner and the MARK button. Held
        // only while recording, and restored in `stop`.
        UIApplication.shared.isIdleTimerDisabled = true

        isRecording = true
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickDisplay() }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        displayTimer?.invalidate()
        displayTimer = nil
        motion.stopDeviceMotionUpdates()
        locations.stopUpdatingLocation()
        locations.allowsBackgroundLocationUpdates = false
        pedometer.stopUpdates()
        UIApplication.shared.isIdleTimerDisabled = false

        let header = MotionTrace.Header(
            name: Self.name(for: startedAt ?? Date()),
            describes: "raw hand-held capture",
            recordedAt: startedAt ?? Date(),
            deviceModel: Self.deviceModel(),
            systemVersion: Self.systemVersion(),
            appVersion: Self.appVersion(),
            nominalSampleRateHz: sampleRateHz,
            carryPosition: .handHeld,
            runnerHeightMetres: runnerHeightMetres,
            references: [])
        do {
            try sink.finish(header: header)
        } catch {
            lastError = "cannot finalise capture: \(error.localizedDescription)"
        }
        tickDisplay()
        refreshCaptures()
    }

    /// A labelled instant (AC-FR-S-F-1-5).
    ///
    /// The single most valuable thing a runner can contribute during capture: a mark
    /// bounding a counted-steps segment gives an *exact* step-count reference, which no
    /// GPS trace can provide.
    func mark(note: String? = nil) {
        guard isRecording else { return }
        markCount += 1
        sink.append(mark: MotionTrace.Mark(
            timestamp: relativeTime(), index: markCount, note: note))
    }

    // MARK: - Streams

    private func startMotion() {
        motion.deviceMotionUpdateInterval = 1 / sampleRateHz
        // `.xArbitraryZVertical` gives a gravity vector referenced to true vertical
        // without waiting for a magnetometer calibration the runner would have to perform.
        // Heading is irrelevant here — the estimator needs a scalar distance, not a
        // position (design.md §3.2) — so the cheapest reference frame is the right one.
        //
        // Nothing in this closure touches the main actor or the recorder: it captures the
        // sink and nothing else. At 100 Hz that is the difference between a capture screen
        // that responds and one that does not (S-056).
        let sink = self.sink

        // ## The annotation below is the fix for S-057, and it is load-bearing
        //
        // `CMDeviceMotionHandler` is a plain Objective-C block with no `NS_SWIFT_SENDABLE`,
        // so it imports as a *non-Sendable* closure type. A closure literal written inside
        // a method of a `@MainActor` type therefore **inherits main-actor isolation** —
        // silently, with no diagnostic, because the ObjC block type carries no isolation
        // information for the compiler to contradict. CoreMotion then invokes it on the
        // `NSOperationQueue` it was handed, Swift's runtime checks the executor, finds it
        // is not the main one, and traps: `EXC_BREAKPOINT` in
        // `swift_task_isCurrentExecutor`. Five field captures died this way within seconds
        // of the first sample, which is why all five files were zero bytes.
        //
        // Writing the type out and marking it `@Sendable` opts the closure out of that
        // inference and moves the whole question to compile time: any main-actor access
        // added here in future is a build error rather than a crash on a run.
        //
        // The Simulator cannot catch this. It has no accelerometer (CON-S-1), so the
        // handler is never invoked and the isolation check never runs — the one constraint
        // this track is built around, arriving as a crash instead of a missing number.
        let handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void = {
            [weak self] data, error in
            guard let data else {
                if let error {
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
                return
            }
            // Converted from g to m/s² **here**, once, so nothing downstream has to
            // remember which unit CoreMotion reports in.
            let g = 9.80665
            // CoreMotion's own uptime clock. `CaptureWriter.assemble` rebases these onto
            // the same origin as the other streams, which is why no shared start time has
            // to be read from this closure.
            sink.append(motion: MotionSample(
                timestamp: data.timestamp,
                userAcceleration: Vector3(
                    x: data.userAcceleration.x * g,
                    y: data.userAcceleration.y * g,
                    z: data.userAcceleration.z * g),
                gravity: Vector3(
                    x: data.gravity.x * g, y: data.gravity.y * g, z: data.gravity.z * g),
                rotationRate: Vector3(
                    x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z)))
        }
        motion.startDeviceMotionUpdates(
            using: .xArbitraryZVertical, to: queue, withHandler: handler)
    }

    private func startLocation() {
        locations.desiredAccuracy = kCLLocationAccuracyBest
        locations.activityType = .fitness
        locations.distanceFilter = kCLDistanceFilterNone
        locations.pausesLocationUpdatesAutomatically = false
        if locations.authorizationStatus == .notDetermined {
            locations.requestWhenInUseAuthorization()
        }
        // Background updates need the `location` background mode, and setting this
        // without it raises. Guarded rather than assumed, so a misconfigured plist is a
        // logged message instead of a crash mid-run (CON-S-4).
        if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
            .flatMap({ $0 as? [String] })?.contains("location") == true
        {
            locations.allowsBackgroundLocationUpdates = true
        }
        locations.startUpdatingLocation()
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let sink = self.sink
        // `CMPedometerHandler` carries no `NS_SWIFT_SENDABLE` either, and CMPedometer
        // delivers on its own queue — the same trap as the motion handler above (S-057),
        // and it would have fired the moment the first step was counted.
        let handler: @Sendable (CMPedometerData?, (any Error)?) -> Void = { data, _ in
            guard let data else { return }
            sink.append(pedometer: MotionTrace.RecordedPedometerReading(
                timestamp: data.endDate.timeIntervalSince(data.startDate),
                cumulativeSteps: data.numberOfSteps.intValue,
                cumulativeDistanceMetres: data.distance?.doubleValue,
                currentCadenceStepsPerSecond: data.currentCadence?.doubleValue))
        }
        pedometer.startUpdates(from: Date(), withHandler: handler)
    }

    // MARK: - Helpers

    private func relativeTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - startUptime
    }

    /// When a fix *happened*, not when it was handed to us (S-060).
    ///
    /// CoreLocation buffers fixes whenever delivery is deferred — which is exactly what a
    /// GNSS outage, a backgrounded app or a locked screen produce — and then hands the
    /// whole backlog over in a single `didUpdateLocations` call. Stamping each one with
    /// "now" collapses the entire outage into one instant.
    ///
    /// That is not cosmetic. In the 4.3 mi validation run it put **19 fixes at t=1126.071
    /// spanning 50.9 m** and 34 more at t=1171.4 spanning 97.2 m: 184.7 m of real running
    /// recorded as having taken zero seconds. The fusion re-anchors on one delta when GNSS
    /// returns, so it discarded the first of those and then added the other eighteen on top
    /// of the motion distance it had already accrued for the same stretch — double-counting
    /// the outage and making the fused figure worse than either leg alone.
    ///
    /// `CLLocation.timestamp` is when the fix was *determined*, so it is the only correct
    /// answer. Rebased onto the capture's own origin so it shares a timeline with the
    /// motion stream.
    private func relativeTime(of location: CLLocation) -> TimeInterval {
        guard let startedAt else { return relativeTime() }
        return location.timestamp.timeIntervalSince(startedAt)
    }

    /// Publishes the counters twice a second.
    ///
    /// The counts are read from the sink rather than incremented per sample: an
    /// `@Published` property mutated at 100 Hz asks SwiftUI to rebuild the screen on every
    /// frame, which is what made the capture screen stop responding (S-056).
    private func tickDisplay() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        let counts = sink.snapshot()
        motionSampleCount = counts.motion
        locationFixCount = counts.location
        if let failure = counts.failure, lastError == nil {
            lastError = failure
        }
    }

    private func refreshCaptures() {
        captures = CaptureWriter.existingCaptures()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshCaptures()
    }

    private static func name(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "capture-\(formatter.string(from: date))"
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }
}

// MARK: - Location delegate

extension MotionCaptureRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let fixes = locations
        Task { @MainActor in
            for location in fixes { self.record(location) }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: any Error
    ) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }

    /// Speed below which a fix contributes no distance (S-058).
    ///
    /// GNSS position wanders while the phone is still, and an accuracy gate does not catch
    /// it: in the first field bench test the accuracy was a healthy 5.1 m throughout, and
    /// **70.9 m of distance accumulated over thirty seconds of the runner standing
    /// motionless** — 15% of the whole session, fabricated. That number then becomes the
    /// reference the calibrator fits the step-length model against, so the error does not
    /// stay in the distance column.
    ///
    /// 0.5 m/s is 1.8 km/h, far below any running or ordinary walking pace, and the same
    /// trace measured 0.07 m/s standing against 1.44 walking and 2.71 running — an order of
    /// magnitude of headroom on both sides.
    static let minimumMovingSpeed: CLLocationSpeed = 0.5

    /// Whether the phone actually moved between two fixes.
    ///
    /// `CLLocation.speed` is Doppler-derived and reliable when present, so it is preferred.
    /// It reports `-1` when unavailable, in which case the implied speed is used rather
    /// than defaulting to "moving" — an unknown speed is not evidence of motion.
    func isMoving(_ location: CLLocation, since previous: CLLocation) -> Bool {
        if location.speed >= 0 { return location.speed >= Self.minimumMovingSpeed }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return false }
        return location.distance(from: previous) / elapsed >= Self.minimumMovingSpeed
    }

    /// Location arrives at roughly 1 Hz, so building the record on the main actor costs
    /// nothing — unlike motion at 100 Hz, which is why only that stream bypasses it.
    private func record(_ location: CLLocation) {
        guard isRecording else { return }
        // Cumulative distance is accumulated here rather than in `PhoneMotion`, because
        // it needs `CLLocation.distance(from:)` — the estimator stays framework-free
        // (ADR-S-03). Only fixes that pass the accuracy gate contribute, so the recorded
        // cumulative is the same series a live run would fuse.
        if location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 20 {
            if let previous = previousLocation, isMoving(location, since: previous) {
                cumulativeLocationMetres += location.distance(from: previous)
            }
            previousLocation = location
        }
        sink.append(location: MotionTrace.RecordedFix(
            timestamp: relativeTime(of: location),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeMetres: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speedMetresPerSecond: location.speed >= 0 ? location.speed : nil,
            cumulativeDistanceMetres: cumulativeLocationMetres))
    }
}
