import SwiftUI
import ORIntervals
import ORModels
import LegacySupport

/// The start screen — Legacy tier (T-070, FR-A-7).
///
/// Every run type with a one-line description of what it is for, so the choice is not a guess. The
/// strings come from `RunStrings`, which is pinned identical to the Modern tier's.
struct StartView: View {

    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        List {
            // DEG-7: a run left behind by a crash is offered before a new one can start, so a
            // recoverable run is never silently overwritten by the next one.
            if let orphan = coordinator.run.orphan {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unfinished run")
                            .font(.headline)
                        Text("\(orphan.sampleCount) samples recorded")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            Button("Save") { coordinator.saveOrphan() }
                                .buttonStyle(.borderedProminent)
                            Button("Discard") { coordinator.run.discardOrphan() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if coordinator.run.phase == .refusedInsufficientStorage {
                // DEG-6: refused before starting, rather than failing at minute 40 with data lost.
                Text("Not enough free space to record a run.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Section {
                ForEach(RunType.allCases, id: \.self) { type in
                    Button {
                        coordinator.startRun(type: type)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(RunStrings.runType(type))
                                .font(.headline)
                            Text(RunStrings.runTypeDetail(type))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Section {
                Button {
                    coordinator.screen = .settings
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .navigationTitle("OptimalRunner")
    }
}

/// Settings — Legacy tier (T-070, AC-FR-B-1-7, AC-FR-J-2-3).
///
/// Units, the CVD-safe palette, and pace haptics. **No Double Tap row**: Series 3 has no such
/// hardware, and a toggle that does nothing is worse than an absent one. T-070's scope is "parity
/// with T-046/T-047 minus Double Tap settings".
struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    let onDone: () -> Void

    var body: some View {
        List {
            Section("Units") {
                Picker("Units", selection: $settings.units) {
                    ForEach(UnitPreference.allCases, id: \.self) { unit in
                        Text(RunStrings.unitSuffix(unit)).tag(unit)
                    }
                }
            }

            Section("Colours") {
                Picker("Palette", selection: $settings.palette) {
                    ForEach(PaletteChoice.allCases, id: \.self) { choice in
                        Text(choice == .standard ? "Standard" : "High contrast").tag(choice)
                    }
                }
            }

            Section("Haptics") {
                Toggle("Pace alerts", isOn: $settings.paceHapticsEnabled)
                Text("Never fires during VO2 Max.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button("Done", action: onDone)
        }
        .navigationTitle("Settings")
    }
}
