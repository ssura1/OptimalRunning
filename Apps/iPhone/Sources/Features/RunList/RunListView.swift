import SwiftUI
import ORModels
import PhoneSupport
import SwiftData

/// The run list (T-054, FR-F-1).
///
/// Reads `RunListItem` value types through the repository rather than binding `@Query` to
/// `RunRecord` directly. That is deliberate and load-bearing: a `@Query` over the model would hand
/// each row a live managed object, and any row that touched `packedSamples` would fault in ~100 KB
/// — turning a 1 000-run scroll into tens of megabytes of I/O. A projection cannot do that by
/// construction (AC-FR-F-1-3, NFR-5).
struct RunListView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var model = RunListModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Runs")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        filterMenu
                    }
                }
                .task { model.load(context: modelContext) }
                .refreshable { model.load(context: modelContext) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty && model.filter.isEmpty {
            // AC-FR-F-1-4 — the empty state explains how to record a first run, rather than
            // saying "No runs" and leaving the user to work it out.
            ContentUnavailableView {
                Label("No runs yet", systemImage: "figure.run")
            } description: {
                Text(
                    "Start a run on your Apple Watch. When it finishes it transfers here "
                        + "automatically — the watch keeps it safe until this phone confirms it, "
                        + "so you can leave your phone at home."
                )
            }
        } else if model.items.isEmpty {
            ContentUnavailableView {
                Label("No matching runs", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No runs match the current filter.")
            } actions: {
                Button("Clear Filter") {
                    model.filter = RunListFilter()
                    model.load(context: modelContext)
                }
            }
        } else {
            List(model.items) { item in
                NavigationLink {
                    RunDetailView(runID: item.runID)
                } label: {
                    RunListRow(item: item, unit: model.unit)
                }
            }
            .listStyle(.plain)
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("Run type") {
                ForEach(RunType.allCases, id: \.self) { type in
                    Button {
                        model.toggle(type)
                        model.load(context: modelContext)
                    } label: {
                        Label(
                            PhoneFormat.runType(type),
                            systemImage: model.filter.runTypes.contains(type) ? "checkmark" : ""
                        )
                    }
                }
            }
            Section("Period") {
                Button("Last 30 days") {
                    model.setRange(days: 30)
                    model.load(context: modelContext)
                }
                Button("Last 12 months") {
                    model.setRange(days: 365)
                    model.load(context: modelContext)
                }
                Button("All time") {
                    model.filter.from = nil
                    model.filter.to = nil
                    model.load(context: modelContext)
                }
            }
            if !model.filter.isEmpty {
                Button("Clear Filter", role: .destructive) {
                    model.filter = RunListFilter()
                    model.load(context: modelContext)
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.filter.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }
}

/// One row. AC-FR-F-1-1's six fields, and nothing that would touch a blob.
private struct RunListRow: View {
    let item: RunListItem
    let unit: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(PhoneFormat.runType(item.runType))
                    .font(.headline)
                if item.isDegraded {
                    // A degraded run is marked in the list, not only in the detail view: a user
                    // comparing two runs' distances deserves to know one of them was
                    // reconstructed from HealthKit rather than recorded.
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Partial data")
                }
                Spacer()
                Text(item.startedAt, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(PhoneFormat.distance(item.distanceMetres, unit: unit), systemImage: "arrow.right")
                Label(PhoneFormat.duration(item.activeSeconds), systemImage: "clock")
            }
            .font(.subheadline)
            .labelStyle(.titleOnly)

            HStack(spacing: 12) {
                Text(PhoneFormat.pace(item.averagePace, unit: unit))
                Text(PhoneFormat.heartRate(item.averageHeartRate))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The list's state.
@MainActor
@Observable
final class RunListModel {

    var items: [RunListItem] = []
    var filter = RunListFilter()
    var unit: UnitPreference = .miles

    func load(context: ModelContext) {
        let runs = RunRepository(context: context)
        items = (try? runs.listItems(filter: filter)) ?? []
        // The list renders in the runner's own units, read from the stored profile rather than
        // from a per-screen setting — one source of truth (AC-FR-I-1-4).
        unit = (try? ProfileRepository(context: context).profile()?.units) ?? .miles
    }

    func toggle(_ type: RunType) {
        if filter.runTypes.contains(type) {
            filter.runTypes.remove(type)
        } else {
            filter.runTypes.insert(type)
        }
    }

    func setRange(days: Int) {
        filter.to = Date()
        filter.from = Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}
