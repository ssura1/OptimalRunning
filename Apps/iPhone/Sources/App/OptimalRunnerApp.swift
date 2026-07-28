import SwiftUI
import ORModels
import PhoneSupport
import SwiftData

@main
struct OptimalRunnerApp: App {

    /// Built once and injected, so every screen reads one store rather than opening its own.
    private let container: ModelContainer
    @State private var sync: WatchSyncCoordinator

    /// Owned here, not by the capture screen (S-056).
    ///
    /// A capture has to outlive the view that starts it: the screen is a `NavigationLink`
    /// destination, and while it was a `@StateObject` there, navigating back tore the
    /// recorder down mid-run and lost the trace. App-scoped is the shortest lifetime that
    /// is longer than a run.
    @StateObject private var motionCapture = MotionCaptureRecorder()

    init() {
        // A store that cannot be opened is not recoverable by retrying, and continuing with an
        // in-memory one would silently discard every run the user records. Failing loudly at
        // launch is the honest outcome — and this is the one place in the app where that is true.
        let container: ModelContainer
        do {
            container = try RunStoreContainer.make()
        } catch {
            fatalError("The run store could not be opened: \(error)")
        }
        self.container = container
        _sync = State(initialValue: WatchSyncCoordinator(container: container))
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(motionCapture)
                .task { sync.activate() }
        }
        .modelContainer(container)
    }
}
