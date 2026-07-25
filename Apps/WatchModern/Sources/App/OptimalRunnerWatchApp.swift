import SwiftUI
import ORModels
import WatchSupport

@main
struct OptimalRunnerWatchApp: App {

    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}

/// Switches between the start screen and an active run.
///
/// A plain conditional rather than a `NavigationStack` push: a run is a *mode*, not a
/// destination. Pushing it would leave a back gesture that abandons a workout, which is
/// exactly what CON-1 and the deliberate End-on-Controls flow exist to prevent.
struct RootView: View {

    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if let run = coordinator.run {
            RunPagerView(
                model: run,
                configuration: coordinator.configuration,
                onEnd: { Task { await coordinator.endRun() } }
            )
        } else {
            StartView(
                model: coordinator.start,
                settings: coordinator.settings,
                onStart: { runType in Task { await coordinator.startRun(runType) } },
                orphan: coordinator.orphan,
                onRecoverOrphan: { coordinator.recoverOrphan() },
                onDiscardOrphan: { coordinator.discardOrphan() }
            )
            .alert(
                "Not Enough Space",
                isPresented: .constant(coordinator.startFailure != nil)
            ) {
                Button("OK") { }
            } message: {
                // DEG-6: refused before recording anything, and with the actual reason.
                // "Something went wrong" would be useless — the runner needs to know it is
                // storage so they can do something about it.
                Text("Free up some space on your watch before starting a run.")
            }
        }
    }
}
