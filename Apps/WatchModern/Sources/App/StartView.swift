import SwiftUI
import ORModels

/// Scaffolding placeholder. T-005 exists to prove the project builds and links
/// `Core` — the real start screen is T-046 (Wave 2).
struct StartView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.run")
            Text("OptimalRunner")
                .font(.headline)
            // Proves the local Core package actually links and resolves, not just
            // that the project file declares a dependency on it.
            Text("\(RunType.allCases.count) run types")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    StartView()
}
