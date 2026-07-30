import CoreLocation
import CoreMotion
import Foundation
import ORModels

/// What the standalone tier is allowed to sense, and what that means for a run (S-035,
/// FR-S-A-1).
///
/// **The requests happen here and nowhere else.** AC-FR-S-A-1-2 requires location and
/// motion authorization to be asked for at the point of first starting a standalone run,
/// and *not* at launch or on any hub-only path — which is what makes ADR-S-01's "one app,
/// two personalities" cost a hub-only user nothing. Concentrating the calls in one type is
/// what makes that checkable: `StandaloneAuthorizationTests` asserts that exercising the
/// hub's paths produces zero requests, and a second call site would make that assertion
/// meaningless without making it fail.
@MainActor
final class StandaloneAuthorization {

    /// What a run can be started with.
    enum Readiness: Equatable {
        /// Both sensors are available. Full accuracy, route recorded.
        case full
        /// Location denied: motion-derived distance only, no route, reduced accuracy
        /// (AC-FR-S-A-1-4).
        case motionOnly
        /// Motion denied: GNSS only, and pace is unavailable during GPS outages
        /// (AC-FR-S-A-1-5).
        case locationOnly
        /// Neither. A paced run cannot measure anything, so it is refused with a message
        /// naming what is needed and why (AC-FR-S-A-1-6).
        case refused

        var permitsRun: Bool { self != .refused }
    }

    /// Counts every authorization request this process has made.
    ///
    /// Exists for the test that backs AC-FR-S-A-1-2 — "a hub-only session triggers no
    /// location or motion prompt" — because that requirement is about an *absence*, and an
    /// absence is only checkable if something counts.
    private(set) static var requestCount = 0

    static func resetRequestCountForTesting() { requestCount = 0 }

    private let locationManager: CLLocationManager
    private let motionActivityAvailable: Bool

    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        self.motionActivityAvailable = CMMotionManager().isDeviceMotionAvailable
    }

    // MARK: - Status

    var locationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }

    /// CoreMotion's device-motion stream needs `NSMotionUsageDescription` but reports its
    /// status through `CMMotionActivityManager`, which is a *different* API — and the one
    /// the system prompt is actually attached to.
    var motionStatus: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

    /// The readiness implied by the current statuses, with no prompting.
    var readiness: Readiness {
        let hasLocation = locationStatus == .authorizedWhenInUse
            || locationStatus == .authorizedAlways
        let hasMotion = motionActivityAvailable && motionStatus != .denied
            && motionStatus != .restricted

        switch (hasLocation, hasMotion) {
        case (true, true): return .full
        case (false, true): return .motionOnly
        case (true, false): return .locationOnly
        case (false, false): return .refused
        }
    }

    // MARK: - Requesting

    /// Asks for whatever is still undetermined, and returns what the run may use.
    ///
    /// Called from the start flow only. Requesting *when-in-use* rather than *always*: a
    /// run is a foreground activity that continues in the background, which is exactly what
    /// `UIBackgroundModes: location` plus `allowsBackgroundLocationUpdates` grants on a
    /// when-in-use authorization (CON-S-4). Asking for Always would be asking for more than
    /// the product needs, and iOS presents it as a scarier prompt for no benefit.
    func requestIfNeeded() async -> Readiness {
        if locationStatus == .notDetermined {
            Self.requestCount += 1
            locationManager.requestWhenInUseAuthorization()
            // The prompt is asynchronous and its result arrives through the delegate. The
            // run is not blocked on it: AC-FR-S-A-1-4 says a denied location still permits
            // the run, so the honest thing is to start and let the fusion layer discover
            // what it has. Blocking would turn a supported degraded mode into a modal wait.
        }

        if motionStatus == .notDetermined {
            Self.requestCount += 1
            await requestMotion()
        }

        return readiness
    }

    /// CoreMotion has no explicit "request authorization" call — the prompt appears on
    /// first *use*. A one-shot activity query is the cheapest use that triggers it, and it
    /// is deliberately a query over a one-second window rather than a live update stream,
    /// so nothing is left running afterwards (NFR-S-6).
    private func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let manager = CMMotionActivityManager()
        await withCheckedContinuation { continuation in
            manager.queryActivityStarting(
                from: Date().addingTimeInterval(-1), to: Date(), to: .main
            ) { _, _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Explaining

    /// What to tell the runner before the run starts, or `nil` when everything is
    /// available.
    ///
    /// Each string names the consequence rather than the permission, because "Location
    /// access is denied" tells a runner nothing they can decide with — whereas "distance
    /// will be estimated and no route recorded" is the actual trade they are being offered.
    static func explanation(for readiness: Readiness) -> String? {
        switch readiness {
        case .full:
            return nil
        case .motionOnly:
            return "Without location access, distance is estimated from your phone's "
                + "motion and no route is recorded. Accuracy is reduced."
        case .locationOnly:
            return "Without motion access, pace comes from GPS alone — so it will be "
                + "unavailable wherever GPS drops out, such as underpasses and dense city "
                + "streets."
        case .refused:
            return "A paced run needs either location or motion access to measure "
                + "anything. Enable one in Settings › OptimalRunner, or record a timed run "
                + "instead."
        }
    }
}
