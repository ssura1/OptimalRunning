import SwiftUI
import ORModels

/// Scaffolding placeholder. T-005 exists to prove the project builds and links
/// `Core` — every real screen belongs under `Features/` (Wave 3 onward).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.system(size: 48))
            Text("OptimalRunner")
                .font(.title2.bold())
            // Proves the local Core package actually links and resolves, not just
            // that the project file declares a dependency on it.
            Text("\(RunType.allCases.count) run types available")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
