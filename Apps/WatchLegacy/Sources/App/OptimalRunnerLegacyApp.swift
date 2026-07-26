import SwiftUI
import WatchKit
import ORIntervals
import ORModels
import LegacySupport

/// The Legacy watch app's entry point (T-070).
///
/// A `NavigationView`, not a `NavigationStack` — the first divergence in design.md §8.1's tier
/// matrix. `NavigationStack` is watchOS 9+; this target is watchOS 8, so `NavigationView` is not a
/// preference but the available API. Zero `#available` anywhere in this tree (CON-3, AC-FR-K-1-5).
@main
struct OptimalRunnerLegacyApp: App {

    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                RootView(coordinator: coordinator)
            }
        }
    }
}

/// Owns the objects that outlive a single run.
///
/// Kept deliberately small: everything with behaviour worth testing lives in `LegacySupport`, which
/// `swift test` can reach on the host. This tier has no simulator, so anything holding logic here
/// would be verifiable on hardware only.
@MainActor
final class AppCoordinator: ObservableObject {

    enum Screen: Hashable {
        case start
        case run
        case settings
    }

    @Published var screen: Screen = .start

    let settings: SettingsStore
    let run: RunSessionModel
    let feed: LiveSensorFeed
    /// The durable outbound queue (T-071). Survives relaunch, so a run that reaches it is not lost
    /// while the phone is out of range.
    let queue: PendingPayloadQueue

    /// The plan the current run is following, needed to build the envelope at the end.
    var activePlan: WorkoutPlan?
    /// Retained across a relaunch-free crash recovery, so a recovered run can still be described.
    var lastKnownPlan: WorkoutPlan?
    /// The most recent tick time, so pause/resume/end share the run's clock rather than each reading
    /// `Date()` separately and disagreeing by a few milliseconds.
    var lastTickTime: TimeInterval = 0

    let appVersion: String = (Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

    private let haptics = WatchHapticPlayer()

    init() {
        self.settings = SettingsStore(defaults: UserDefaults.standard)

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        self.run = RunSessionModel(
            store: SampleStore(directory: support.appendingPathComponent("Capture", isDirectory: true)),
            session: WorkoutSessionController(backend: HealthKitWorkoutBackend()),
            haptics: haptics
        )
        self.feed = LiveSensorFeed()
        self.queue = PendingPayloadQueue(
            directory: support.appendingPathComponent("Outbox", isDirectory: true)
        )

        // DEG-7: a run left behind by a crash is offered for recovery before a new one can start.
        run.checkForOrphanedRun()
    }

    /// The profile the watch runs with.
    ///
    /// Paces arrive from the phone (T-050's downlink); units and palette are the watch's own, so a
    /// downlink cannot overwrite a preference set on the wrist.
    var profile: RunnerProfile {
        settings.merged(into: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)))
    }
}

/// Routes between the three screens.
struct RootView: View {

    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.screen {
        case .start:
            StartView(coordinator: coordinator)
        case .run:
            RunPagerView(coordinator: coordinator)
        case .settings:
            SettingsView(settings: coordinator.settings) {
                coordinator.screen = .start
            }
        }
    }
}
