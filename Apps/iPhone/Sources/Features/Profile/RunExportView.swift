import Foundation
import ORModels
import PhoneSupport
import SwiftData
import SwiftUI

/// Getting recorded runs off the phone (S-067).
///
/// **Every run in the store, not just the last one and not just phone runs.** A field
/// session produces several runs and the interesting one is rarely the most recent — and a
/// run recorded by an earlier build is exported by exactly the same path, because the
/// export is built from what the store already holds rather than from anything captured at
/// the time of the run. Nothing had to be enabled beforehand.
///
/// The route in every exported file is reduced to metres east and north of that run's own
/// first fix. That is not a setting on this screen, and there is no switch to turn it off —
/// see `RunExport`.
struct RunExportView: View {

    @Environment(\.modelContext) private var modelContext

    @State private var runs: [RunListItem] = []
    @State private var exports: [UUID: URL] = [:]
    @State private var bulkExport: [URL] = []
    @State private var isExportingAll = false
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if runs.isEmpty {
                Section {
                    Text("No recorded runs.").foregroundStyle(.secondary)
                }
            } else {
                allSection
                runsSection
            }
        }
        .navigationTitle("Export Runs")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    // MARK: - Sections

    private var allSection: some View {
        Section {
            if bulkExport.isEmpty {
                Button {
                    exportAll()
                } label: {
                    if isExportingAll {
                        ProgressView()
                    } else {
                        Label("Prepare All \(runs.count) Runs", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                .disabled(isExportingAll)
            } else {
                // Once prepared, one share sheet carries the lot — AirDropping eight files
                // individually is how a test session's evidence ends up half-transferred.
                ShareLink(items: bulkExport) {
                    Label("Share \(bulkExport.count) Files", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            Text(
                """
                Each run becomes one JSON file: summary, every sample, splits, degradation \
                flags, and — for phone runs — the calibration state and which stretches were \
                estimated. Routes are stored as metres east and north of each run's own \
                starting fix, so a file says what shape the run was without saying where it \
                happened.
                """)
        }
    }

    private var runsSection: some View {
        Section {
            ForEach(runs) { run in
                row(for: run)
            }
        } header: {
            Text("Runs")
        } footer: {
            // Two taps, and the icon says which one you are on. `ShareLink` needs its file
            // to exist before the row is built, so a row cannot both prepare and share on
            // one tap without hand-rolling the share sheet — not worth it for a tool only
            // ever used a few times per test session.
            Text("Tap a run to prepare it, then tap again to share. AirDrop to a Mac is "
                + "quickest; the files are also in the Files app under On My iPhone.")
        }
    }

    @ViewBuilder
    private func row(for run: RunListItem) -> some View {
        if let url = exports[run.runID] {
            ShareLink(item: url) { label(for: run, prepared: true) }
        } else {
            Button {
                export(run)
            } label: {
                label(for: run, prepared: false)
            }
        }
    }

    private func label(for run: RunListItem, prepared: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(PhoneFormat.runType(run.runType))
                    if run.deviceTier == .phoneStandalone {
                        Image(systemName: "iphone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if run.isDegraded {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: prepared ? "square.and.arrow.up" : "arrow.down.doc")
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Actions

    private func load() {
        do {
            runs = try RunRepository(context: modelContext).listItems()
        } catch {
            failure = "Could not read the run list: \(error.localizedDescription)"
        }
    }

    private func export(_ run: RunListItem) {
        do {
            exports[run.runID] = try write(run.runID)
        } catch {
            failure = "Could not export that run: \(error.localizedDescription)"
        }
    }

    private func exportAll() {
        isExportingAll = true
        Task {
            defer { isExportingAll = false }
            // The encoding is synchronous and main-actor-bound — `ModelContext` is — so
            // this yield is what lets the spinner actually render before a library of runs
            // is serialised. Without it the flag is set and cleared inside one frame and
            // the runner sees nothing happen for two seconds.
            await Task.yield()
            do {
                // Whole-batch: a partially prepared set shared as if complete is worse than
                // an error, because the missing run looks like a run that was never recorded.
                bulkExport = try runs.map { try write($0.runID) }
            } catch {
                bulkExport = []
                failure = "Could not export every run: \(error.localizedDescription)"
            }
        }
    }

    private func write(_ runID: UUID) throws -> URL {
        let repository = RunRepository(context: modelContext)
        guard let record = try repository.record(for: runID) else {
            throw ExportFailure.runNotFound
        }
        let analysis = try RunAnalysis(record: record)
        return try RunExport.write(
            analysis, appVersion: Bundle.main.appVersion, into: try directory())
    }

    /// A dedicated directory under `tmp`.
    ///
    /// Nothing sweeps it, and nothing needs to: filenames are derived from the run's own
    /// start time, so re-exporting a run overwrites its file rather than adding another.
    /// The directory holds at most one file per recorded run, and `tmp` is reclaimed by the
    /// system under storage pressure — which is the behaviour that keeps this from eating
    /// into what `minimumFreeBytesToStart` protects.
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-exports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private enum ExportFailure: LocalizedError {
        case runNotFound

        var errorDescription: String? {
            switch self {
            case .runNotFound: return "the run is no longer in the library"
            }
        }
    }
}
