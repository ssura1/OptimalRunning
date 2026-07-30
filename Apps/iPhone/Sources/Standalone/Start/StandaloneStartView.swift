import ORIntervals
import ORModels
import PhoneSupport
import SwiftData
import SwiftUI

/// Starting a run on the phone alone (S-045, FR-S-A-1).
///
/// **Three taps to a default run** (AC-FR-S-A-1-7), counted from app launch: the Runs tab is
/// already showing, so tap one is the Start button, tap two is the run type — pre-selected
/// to the runner's last choice, so this tap is optional — and tap three is Go. A runner who
/// wants their usual run taps Start, Go.
///
/// The carry position is *stated* here rather than offered as a choice
/// (AC-FR-S-A-1-3, ADR-S-04). There is exactly one supported position, the model is fitted
/// to it, and a picker with one item would imply otherwise. Telling the runner is not
/// optional though — a phone in a pocket produces a signal the estimator is not fitted for,
/// and DEG-S-7 can only detect that after the fact.
struct StandaloneStartView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let onStart: (StandaloneRunRequest) -> Void

    @State private var runType: RunType = .easy
    @State private var activity: RunActivityKind = .outdoorRun
    @State private var readiness: StandaloneAuthorization.Readiness?
    @State private var profile: RunnerProfile?
    @State private var isPreparing = false

    var body: some View {
        NavigationStack {
            Form {
                runTypeSection
                carrySection
                if activity == .indoorRun { indoorSection }
                if let readiness, readiness != .full { permissionSection(readiness) }
            }
            .navigationTitle("Phone Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { start() }
                        .disabled(isPreparing || readiness == .refused)
                        .fontWeight(.semibold)
                }
            }
            .task { await prepare() }
        }
    }

    // MARK: - Sections

    private var runTypeSection: some View {
        Section {
            Picker("Run type", selection: $runType) {
                // All five outdoors — the same list and the same stored profile as the
                // watch (AC-FR-S-A-1-1). Not a subset: a runner who does intervals on the
                // watch and finds them missing on the phone would reasonably conclude the
                // phone tier is a lesser product rather than a different sensor.
                //
                // Indoors, the structured types are genuinely not offerable. Every preset's
                // steps are distance goals, and indoors there is no distance (CON-S-8) — so
                // a rep would never end and the runner would be stuck on step one with no
                // way to advance. Hiding them is the honest form of DEG-S-6's "offer a
                // timed-only run"; showing them and letting one hang would not be.
                ForEach(availableRunTypes, id: \.self) { type in
                    Text(StandaloneStrings.runType(type)).tag(type)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: activity) { _, _ in
                if !availableRunTypes.contains(runType) { runType = .easy }
            }
        } header: {
            Text("Run type")
        } footer: {
            if let pace = profile?.basePace(for: runType) {
                Text(
                    "Target \(PhoneFormat.pace(pace, unit: profile?.units ?? .miles)), "
                        + "from your profile.")
            } else if runType.isStructured {
                Text("Targets come from each step of the workout.")
            } else {
                // DEG-9 — a run with no target is recorded without judgement rather than
                // refused, and the runner is told which it will be.
                Text("No target pace set for this run type — the run is recorded without "
                    + "pace judging.")
            }
        }
    }

    private var carrySection: some View {
        Section {
            Picker("Where", selection: $activity) {
                Text("Outside").tag(RunActivityKind.outdoorRun)
                Text("Indoors").tag(RunActivityKind.indoorRun)
            }
            .pickerStyle(.segmented)

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold the phone in your hand").font(.subheadline.weight(.medium))
                    Text(
                        "Pace comes from your arm swing, so the phone needs to swing with "
                            + "it. A pocket or an armband will not measure correctly."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.tint)
            }
        } header: {
            Text("Carry position")
        }
    }

    /// The run types this activity can actually complete.
    private var availableRunTypes: [RunType] {
        activity == .outdoorRun
            ? RunType.allCases
            : RunType.allCases.filter { !$0.isStructured }
    }

    private var indoorSection: some View {
        Section {
            // DEG-S-6 / CON-S-8, said before the run rather than discovered during it. The
            // requirement is that indoor is "offered as a timed-only run with distance and
            // pace suppressed *and stated as suppressed*", and the honest place to state it
            // is before the runner commits.
            Label(
                "Indoors this records time only. Distance and pace need GPS, and a "
                    + "treadmill's belt gives the phone nothing to measure against — so "
                    + "interval sessions, whose steps end at a distance, are outdoor only.",
                systemImage: "info.circle")
                .font(.footnote)
        }
    }

    private func permissionSection(
        _ readiness: StandaloneAuthorization.Readiness
    ) -> some View {
        Section {
            if let explanation = StandaloneAuthorization.explanation(for: readiness) {
                Label(explanation, systemImage: readiness.permitsRun
                    ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(readiness.permitsRun ? Color.secondary : Color.red)
            }
            if !readiness.permitsRun, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
            }
        } header: {
            Text(readiness.permitsRun ? "Reduced accuracy" : "Cannot start")
        }
    }

    // MARK: - Actions

    /// Reads the profile and asks for authorization.
    ///
    /// **This is the only place either permission is requested** (AC-FR-S-A-1-2). It runs
    /// when this sheet appears — the first standalone run — and on no hub-only path, which
    /// is what keeps ADR-S-01's shared-app decision free for a runner who only ever looks
    /// at their history.
    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }

        profile = try? ProfileRepository(context: modelContext).profile()
        readiness = await StandaloneAuthorization().requestIfNeeded()
    }

    private func start() {
        guard readiness?.permitsRun ?? true else { return }
        onStart(StandaloneRunRequest(
            runType: runType,
            activity: activity,
            profile: profile ?? RunnerProfile()))
        dismiss()
    }
}

/// What the start flow decided.
struct StandaloneRunRequest {
    let runType: RunType
    let activity: RunActivityKind
    let profile: RunnerProfile

    /// The plan for this run.
    ///
    /// Structured types get `Core`'s own preset; steady types get a single open-goal step,
    /// which is what "run until you stop" looks like to the step machine.
    ///
    /// Every one of these comes from `WorkoutPresets` rather than being assembled here.
    /// The phone must not hold a second notion of what a 4×1000 is — a runner who does the
    /// same session on both devices and gets two different step lists would have no way to
    /// tell which was the real one.
    var plan: WorkoutPlan {
        switch runType {
        case .vo2max:
            return WorkoutPresets.vo2Max4x1000()
        case .interval:
            return WorkoutPresets.intervals(
                reps: 4, workMetres: 1000, recoveryMetres: 400)
        case .tempo, .easy, .long:
            return WorkoutPresets.continuousRun(runType: runType)
        }
    }
}
