import SwiftUI
import ORModels
import PhoneSupport
import SwiftData

/// The five-tab structure from design.md §13.1 (T-052).
///
/// Plan and Library are present but explicitly deferred — P1 and P2 respectively. They are shown
/// as "not in this version" rather than omitted, because a tab bar that gains items in a later
/// release relocates everything the user has learned; and rather than as a fake screen, because a
/// placeholder that looks functional is worse than one that admits what it is.
struct AppShell: View {

    @Environment(\.modelContext) private var modelContext
    @State private var selection: Tab = .runs
    @State private var needsOnboarding: Bool?

    enum Tab: Hashable { case runs, statistics, plan, library, profile }

    var body: some View {
        Group {
            switch needsOnboarding {
            case .none:
                // Deciding requires a store read, so the tabs are held back for that instant
                // rather than flashing the Runs tab and then covering it with a sheet.
                ProgressView()
            case .some(true):
                OnboardingView { needsOnboarding = false }
            case .some(false):
                tabs
            }
        }
        .task { decideOnboarding() }
    }

    /// Onboarding is shown when no profile has been stored — not on a "has launched before" flag.
    ///
    /// The two differ in the case that matters: a user who deleted and reinstalled, or whose first
    /// attempt was interrupted, has a launch flag set and no profile. Keying on the thing
    /// onboarding actually produces means it cannot be skipped without having produced it.
    private func decideOnboarding() {
        let hasProfile = (try? ProfileRepository(context: modelContext).profile()) != nil
        needsOnboarding = !hasProfile
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            RunListView()
                .tabItem { Label("Runs", systemImage: "figure.run") }
                .tag(Tab.runs)

            StatisticsView()
                .tabItem { Label("Statistics", systemImage: "chart.bar.fill") }
                .tag(Tab.statistics)

            DeferredFeatureView(
                title: "Plan",
                systemImage: "calendar",
                explanation: "Training plans arrive in a later version. Runs you record now will "
                    + "count toward them."
            )
            .tabItem { Label("Plan", systemImage: "calendar") }
            .tag(Tab.plan)

            DeferredFeatureView(
                title: "Library",
                systemImage: "books.vertical",
                explanation: "Saved routes, laps, and custom workouts arrive in a later version."
            )
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(Tab.library)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
    }
}

/// A tab that exists in the structure but not yet in the product.
private struct DeferredFeatureView: View {
    let title: String
    let systemImage: String
    let explanation: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(explanation)
            }
            .navigationTitle(title)
        }
    }
}
