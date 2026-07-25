import SwiftUI
import ORIntervals
import ORModels
import WatchSupport

/// The start screen (T-046, FR-A-7).
///
/// Five run types, each showing the target and band it will judge against, plus a slot for
/// today's planned workout and a per-run target adjustment. Two taps to start the default
/// type: the list row itself starts the run, so the second tap is the row and the first is
/// nothing — the app opens here.
///
/// Every value shown comes from `StartScreenModel`, including the guarantee that matters
/// most: adjusting today's target does not rewrite the stored profile
/// (`StartScreenModelTests`).
struct StartView: View {

    @Bindable var model: StartScreenModel
    @Bindable var settings: SettingsStore
    let onStart: (RunType) -> Void
    /// Set when a previous run was interrupted and its samples are recoverable (FR-D-6).
    let orphan: SampleStore.OrphanedRun?
    let onRecoverOrphan: () -> Void
    let onDiscardOrphan: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let orphan {
                    orphanSection(orphan)
                }

                if let planned = model.plannedWorkout {
                    Section("Today") {
                        PlannedWorkoutRow(plan: planned) { onStart(planned.runType) }
                    }
                }

                Section("Start a Run") {
                    ForEach(model.options, id: \.runType) { option in
                        NavigationLink {
                            RunTypeDetailView(
                                model: model,
                                option: option,
                                onStart: { onStart(option.runType) }
                            )
                        } label: {
                            RunTypeRow(option: option, isAdjusted: model.hasAdjustment(for: option.runType))
                        }
                    }
                }

                Section {
                    NavigationLink("Settings") {
                        SettingsView(store: settings)
                    }
                }
            }
            .navigationTitle("OptimalRunner")
        }
    }

    /// FR-D-6: an interrupted run is offered for save or discard on the next launch,
    /// before a new run can start. Offered rather than auto-saved — the runner may know
    /// the data is junk, and silently filing a half-run into their history is worse than
    /// asking.
    private func orphanSection(_ orphan: SampleStore.OrphanedRun) -> some View {
        Section("Unfinished Run") {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(orphan.sampleCount) seconds recorded")
                    .font(.caption)
                Text(orphan.lastModified, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Save It", action: onRecoverOrphan)
            Button("Discard", role: .destructive, action: onDiscardOrphan)
        }
    }
}

private struct RunTypeRow: View {

    let option: RunTypeOption
    let isAdjusted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(option.title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                if isAdjusted {
                    // The runner adjusted today's target. Marked, because an unmarked
                    // adjustment silently in force is how someone ends up wondering why
                    // their tempo run feels wrong.
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let target = option.targetText {
                Text(target)
                    .font(.caption2)
                    .monospacedDigit()
            } else {
                Text(option.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlannedWorkoutRow: View {

    let plan: WorkoutPlan
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 1) {
                Text(RunStrings.runType(plan.runType))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text("\(plan.resolvedSteps().count) steps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Target preview, per-run adjustment, and Start.
private struct RunTypeDetailView: View {

    @Bindable var model: StartScreenModel
    let option: RunTypeOption
    let onStart: () -> Void

    /// Whole seconds per preferred unit — the way runners talk about a target nudge
    /// ("ten seconds slower today"), not a percentage of a pace.
    private static let step: Double = 5

    var body: some View {
        List {
            Section {
                Button("Start", action: onStart)
                    .font(.system(.body, design: .rounded, weight: .bold))
            }

            if let target = model.option(for: option.runType).targetText {
                Section("Target") {
                    Text(target)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()

                    if let band = model.option(for: option.runType).bandText {
                        Text("On target: \(band)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack {
                        Button {
                            model.adjustTarget(for: option.runType, bySeconds: -Self.step)
                        } label: {
                            Label("Faster", systemImage: "minus")
                        }
                        Button {
                            model.adjustTarget(for: option.runType, bySeconds: Self.step)
                        } label: {
                            Label("Slower", systemImage: "plus")
                        }
                    }
                    .labelStyle(.iconOnly)

                    if model.hasAdjustment(for: option.runType) {
                        Button("Reset to Profile") {
                            model.resetAdjustment(for: option.runType)
                        }
                        Text("Today only — your saved pace is unchanged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(option.title)
    }
}
