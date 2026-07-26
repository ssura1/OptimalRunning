import Charts
import SwiftUI
import ORModels
import ORStats
import PhoneSupport
import SwiftData

/// The statistics hub (T-061, FR-F-3, NFR-5).
///
/// Reads the pre-computed `AggregateCache` rather than scanning runs. That is the whole reason the
/// cache exists: rendering this screen from 1 000 runs' stored records would be a full-table scan
/// on every appearance, whereas the cache is one small decoded blob. `AggregateTests` is what keeps
/// the shortcut honest — the cache is checked against a full recomputation after every operation.
struct StatisticsView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var cache = AggregateCache()
    @State private var unit: UnitPreference = .miles
    @State private var isRebuilding = false

    var body: some View {
        NavigationStack {
            Group {
                if cache.lifetime.runCount == 0 {
                    ContentUnavailableView {
                        Label("No statistics yet", systemImage: "chart.bar")
                    } description: {
                        Text("Record a run on your watch and your totals will appear here.")
                    }
                } else {
                    List {
                        lifetimeSection
                        weeklySection
                        bestsSection
                        maintenanceSection
                    }
                }
            }
            .navigationTitle("Statistics")
            .task { load() }
            .refreshable { load() }
        }
    }

    private var lifetimeSection: some View {
        Section("Lifetime") {
            StatRow("Runs", "\(cache.lifetime.runCount)")
            StatRow("Distance", PhoneFormat.distance(cache.lifetime.distanceMetres, unit: unit))
            StatRow("Time", PhoneFormat.duration(cache.lifetime.activeSeconds))
            StatRow("Average pace", PhoneFormat.pace(cache.lifetime.averagePace, unit: unit))
            StatRow("Total climb", "\(Int(cache.lifetime.elevationGainMetres.rounded())) m")
        }
    }

    /// The 52-week chart.
    private var weeklySection: some View {
        Section("Last 52 weeks") {
            let series = cache.weeklySeries(endingAt: Date(), weeks: 52)

            // Plotted against position in the window rather than the ISO week number: week
            // numbers restart each January, so a 52-week window spanning a year boundary would
            // otherwise draw two bars at "week 3" and lose their order.
            Chart(Array(series.enumerated()), id: \.offset) { index, entry in
                BarMark(
                    x: .value("Weeks ago", series.count - 1 - index),
                    y: .value("Distance", entry.totals.distanceMetres / unit.metresPerUnit)
                )
                .foregroundStyle(.blue)
            }
            .chartXScale(domain: .automatic(reversed: true))
            .frame(height: 160)
            .accessibilityLabel("Weekly distance over the last 52 weeks")

            let total = series.reduce(0) { $0 + $1.totals.distanceMetres }
            StatRow("52-week distance", PhoneFormat.distance(total, unit: unit))
        }
    }

    /// AC-FR-F-3-4 — bests reflect in-run segments, not whole runs, which is what the label says
    /// so the number is not mistaken for a race result.
    private var bestsSection: some View {
        Section {
            if cache.bests.isEmpty {
                Text("No benchmark distances reached yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(BenchmarkDistance.allCases, id: \.self) { distance in
                    if let best = cache.bests[distance] {
                        StatRow(
                            benchmarkName(distance),
                            PhoneFormat.duration(best.seconds),
                            detail: PhoneFormat.pace(best.pace, unit: unit)
                        )
                    }
                }
            }
        } header: {
            Text("Personal bests")
        } footer: {
            Text("Fastest continuous segment within any run — not only runs of exactly that distance.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                rebuild()
            } label: {
                if isRebuilding {
                    HStack { ProgressView(); Text("Recomputing…") }
                } else {
                    Text("Recompute Totals")
                }
            }
            .disabled(isRebuilding)
        } footer: {
            // Offered rather than hidden: the incremental cache is tested against a full rebuild,
            // but a user who suspects a wrong total should be able to settle it themselves rather
            // than being told the number is correct.
            Text("Recalculates every total and personal best from your stored runs.")
        }
    }

    private func benchmarkName(_ distance: BenchmarkDistance) -> String {
        switch distance {
        case .oneKilometre: return "1 km"
        case .oneMile: return "1 mile"
        case .fiveKilometres: return "5 km"
        case .tenKilometres: return "10 km"
        case .halfMarathon: return "Half marathon"
        case .marathon: return "Marathon"
        }
    }

    private func load() {
        cache = (try? AggregateRepository(context: modelContext).cache()) ?? AggregateCache()
        unit = (try? ProfileRepository(context: modelContext).profile()?.units) ?? .miles
    }

    private func rebuild() {
        isRebuilding = true
        defer { isRebuilding = false }
        cache = (try? RunLibrary(context: modelContext).rebuildAggregates(includingBests: true))
            ?? cache
    }
}

private struct StatRow: View {
    let title: String
    let value: String
    let detail: String?

    init(_ title: String, _ value: String, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).monospacedDigit()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
