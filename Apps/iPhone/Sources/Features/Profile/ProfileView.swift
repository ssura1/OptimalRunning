import SwiftUI
import ORColor
import ORModels
import ORStats
import PhoneSupport
import SwiftData

/// Profile and settings (T-062, FR-I-1).
///
/// Every derived pace is a *suggestion* the user confirms — `PaceDerivation` returns values and
/// writes nothing, so AC-FR-I-1-3 and AC-FR-I-1-5 hold at the type level rather than by the view
/// remembering to ask.
struct ProfileView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var profile = RunnerProfile()
    @State private var suggestion: PaceDerivation.Suggestion?
    @State private var showingDerivation = false
    @State private var hasAcknowledgedDisclaimer = false

    var body: some View {
        NavigationStack {
            List {
                pacesSection
                unitsSection
                displaySection
                alertsSection
                standaloneSection
                disclaimerSection
                developerSection
            }
            .navigationTitle("Profile")
            .task { load() }
            .sheet(isPresented: $showingDerivation) {
                PaceDerivationSheet(unit: profile.units) { derived in
                    // Applied only here, on explicit confirmation — never inside the derivation.
                    profile.tempoPace = derived.tempo
                    profile.easyPace = derived.easy
                    profile.longPace = derived.long
                    save()
                }
            }
        }
    }

    /// Settings for runs recorded on the phone alone (S-052, FR-S-G-1).
    ///
    /// A push rather than an inline block: height, cue preferences and calibration are
    /// meaningless to a runner who only ever uses the watch, and putting five more rows in
    /// front of them would make the settings screen worse for the majority to serve the
    /// minority. A single labelled row costs them one line.
    private var standaloneSection: some View {
        Section {
            NavigationLink("Phone Runs") { StandaloneSettingsView() }
        } header: {
            Text("Phone runs")
        } footer: {
            Text("Height, spoken cues, and the stride calibration used when GPS is weak.")
        }
    }

    /// The standalone track's capture tool (S-006, AC-FR-S-F-1-9).
    ///
    /// Last section, plainly labelled, behind a navigation push: reachable deliberately
    /// rather than discoverable by accident. It records raw motion for algorithm
    /// development and is not part of the product — but it lives inside this app rather
    /// than in a scratch project, because that way recording a trace means building the
    /// one app that already exists and already has the entitlements.
    private var developerSection: some View {
        Section {
            NavigationLink("Motion Capture") { MotionCaptureView() }
            NavigationLink("Export Runs") { RunExportView() }
        } header: {
            Text("Developer")
        } footer: {
            Text(
                """
                Motion Capture records raw motion to a file for algorithm development. The \
                iOS Simulator has no accelerometer, so it needs a real device — see \
                Tools/motion-recording-protocol.md.

                Export Runs shares any recorded run as JSON, with its route reduced to \
                offsets from its own starting point.
                """)
        }
    }

    private var pacesSection: some View {
        Section {
            ForEach([RunType.tempo, .easy, .long], id: \.self) { type in
                PaceRow(
                    title: PhoneFormat.runType(type),
                    pace: binding(for: type),
                    unit: profile.units
                )
            }

            Button("Suggest From a Race Result…") { showingDerivation = true }

            if let suggestion {
                SuggestionRow(suggestion: suggestion, unit: profile.units) {
                    apply(suggestion)
                } dismiss: {
                    self.suggestion = nil
                }
            }
        } header: {
            Text("Target paces")
        } footer: {
            // AC-FR-I-1-1/2/3 stated where the user can see it.
            Text(
                "Intervals and VO2 Max take their targets from each workout's steps, so they have "
                    + "no run-level pace here. Every suggested pace can be edited."
            )
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Distance", selection: Binding(
                get: { profile.units },
                set: { profile.units = $0; save() }
            )) {
                Text("Miles").tag(UnitPreference.miles)
                Text("Kilometres").tag(UnitPreference.kilometres)
            }
        }
    }

    /// AC-FR-J-2-3 — the palette choice, with a live preview for the same reason as on the watch:
    /// someone choosing it because of a colour vision deficiency cannot evaluate the choice from
    /// the words alone.
    private var displaySection: some View {
        Section {
            Picker("Colours", selection: Binding(
                get: { profile.palette },
                set: { profile.palette = $0; save() }
            )) {
                Text("Standard").tag(PaletteChoice.standard)
                Text("Colour-Safe").tag(PaletteChoice.colorVisionDeficiency)
            }
            PaletteStrip(palette: profile.palette)
        } header: {
            Text("Display")
        } footer: {
            Text("Zone colours are always paired with a direction glyph, on both palettes.")
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Pace Haptics", isOn: Binding(
                get: { profile.paceHapticsEnabled },
                set: { profile.paceHapticsEnabled = $0; save() }
            ))
            Toggle("Crown Advances Steps", isOn: Binding(
                get: { profile.crownAdvanceEnabled },
                set: { profile.crownAdvanceEnabled = $0; save() }
            ))
        } header: {
            Text("On the watch")
        } footer: {
            Text("Interval and workout haptics keep working when pace haptics are off.")
        }
    }

    /// R-6 — the disclaimer is acknowledged before plan generation becomes reachable. Plan
    /// generation is Wave 5, so this records the acknowledgement now and the gate is already in
    /// place when there is something behind it.
    private var disclaimerSection: some View {
        Section {
            if hasAcknowledgedDisclaimer {
                Label("Acknowledged", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink("Read and Acknowledge") {
                    DisclaimerView {
                        try? ProfileRepository(context: modelContext).acknowledgeDisclaimer()
                        hasAcknowledgedDisclaimer = true
                    }
                }
            }
        } header: {
            Text("Health notice")
        }
    }

    private func binding(for type: RunType) -> Binding<Pace?> {
        Binding(
            get: { profile.basePace(for: type) },
            set: { newValue in
                switch type {
                case .tempo: profile.tempoPace = newValue
                case .easy: profile.easyPace = newValue
                case .long: profile.longPace = newValue
                case .interval, .vo2max: break
                }
                save()
            }
        )
    }

    private func load() {
        let repository = ProfileRepository(context: modelContext)
        profile = (try? repository.profile()) ?? RunnerProfile(
            // AC-FR-I-1-4 — the default follows the device locale rather than assuming miles.
            units: Locale.current.measurementSystem == .metric ? .kilometres : .miles
        )
        hasAcknowledgedDisclaimer = (try? repository.hasAcknowledgedDisclaimer()) ?? false
        loadSuggestion()
    }

    private func loadSuggestion() {
        // AC-FR-I-1-5 — offered after five runs of a type, and only when the change is meaningful.
        guard let runs = try? RunRepository(context: modelContext).listItems(
            filter: RunListFilter(runTypes: [.tempo])
        ) else { return }

        let paces = runs.prefix(10).compactMap(\.averagePace)
        suggestion = PaceDerivation.suggestTarget(
            for: .tempo, recentPaces: Array(paces), currentTarget: profile.tempoPace
        )
    }

    private func apply(_ suggestion: PaceDerivation.Suggestion) {
        switch suggestion.runType {
        case .tempo: profile.tempoPace = suggestion.suggested
        case .easy: profile.easyPace = suggestion.suggested
        case .long: profile.longPace = suggestion.suggested
        case .interval, .vo2max: break
        }
        self.suggestion = nil
        save()
    }

    private func save() {
        try? ProfileRepository(context: modelContext).save(profile)
    }
}

// MARK: - Rows

private struct PaceRow: View {
    let title: String
    @Binding var pace: Pace?
    let unit: UnitPreference

    /// Edited in whole seconds per preferred unit — how runners talk about a pace, and it avoids a
    /// text field that has to parse "7:45".
    private var secondsPerUnit: Double {
        (pace?.secondsPerMetre ?? 0) * unit.metresPerUnit
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(PhoneFormat.pace(pace, unit: unit)).monospacedDigit()
            Stepper("") {
                adjust(by: -5)
            } onDecrement: {
                adjust(by: 5)
            }
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) target \(PhoneFormat.pace(pace, unit: unit))")
    }

    private func adjust(by delta: Double) {
        let base = secondsPerUnit > 0 ? secondsPerUnit : 8 * 60
        let updated = base + delta
        guard updated > 60 else { return }
        pace = Pace(secondsPerMetre: updated / unit.metresPerUnit)
    }
}

private struct SuggestionRow: View {
    let suggestion: PaceDerivation.Suggestion
    let unit: UnitPreference
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Based on your last \(suggestion.sampleCount) \(PhoneFormat.runType(suggestion.runType).lowercased()) runs")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(PhoneFormat.pace(suggestion.current, unit: unit))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                Text(PhoneFormat.pace(suggestion.suggested, unit: unit))
                    .fontWeight(.semibold)
            }
            .monospacedDigit()
            HStack {
                Button("Update Target", action: apply).buttonStyle(.borderedProminent)
                Button("Not Now", action: dismiss)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PaletteStrip: View {
    let palette: PaletteChoice

    private static let zones: [PaceZone] = [
        .tooFast, .slightlyFast, .onTarget, .slightlySlow, .tooSlow,
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.zones, id: \.self) { zone in
                let swatch = ZonePalette.palette(for: palette).swatch(for: zone)
                Image(systemName: ZoneLabels.symbol(zone))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(swatch.text))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color(swatch.background))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sheets

private struct PaceDerivationSheet: View {
    let unit: UnitPreference
    let onConfirm: (PaceDerivation.DerivedPaces) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var distance: Double = 5_000
    @State private var minutes = 25
    @State private var seconds = 0

    private var derived: PaceDerivation.DerivedPaces? {
        PaceDerivation.derive(from: RaceResult(
            distanceMetres: distance, seconds: Double(minutes * 60 + seconds)
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your result") {
                    Picker("Distance", selection: $distance) {
                        Text("5 km").tag(5_000.0)
                        Text("10 km").tag(10_000.0)
                        Text("Half marathon").tag(21_097.5)
                        Text("Marathon").tag(42_195.0)
                    }
                    Stepper("Minutes: \(minutes)", value: $minutes, in: 10...360)
                    Stepper("Seconds: \(seconds)", value: $seconds, in: 0...59)
                }

                if let derived {
                    Section {
                        LabeledContent("Tempo", value: PhoneFormat.pace(derived.tempo, unit: unit))
                        LabeledContent("Easy", value: PhoneFormat.pace(derived.easy, unit: unit))
                        LabeledContent("Long", value: PhoneFormat.pace(derived.long, unit: unit))
                    } header: {
                        Text("Suggested targets")
                    } footer: {
                        Text(
                            "Equivalent 10 km time "
                                + "\(PhoneFormat.duration(derived.equivalentTenKilometreTime)). "
                                + "You can edit any of these afterwards."
                        )
                    }
                }
            }
            .navigationTitle("Derive Paces")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use These") {
                        if let derived { onConfirm(derived) }
                        dismiss()
                    }
                    .disabled(derived == nil)
                }
            }
        }
    }
}

private struct DisclaimerView: View {
    let onAcknowledge: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "OptimalRunner suggests training paces from your own recorded runs. It is not "
                        + "a medical device and gives no medical advice."
                )
                Text(
                    "Talk to a doctor before starting or changing a training programme, "
                        + "particularly if you have a heart condition, are recovering from injury, "
                        + "or have been inactive. Stop running and seek help if you feel chest "
                        + "pain, dizziness, or unusual breathlessness."
                )
                Text("Heart-rate and pace readings come from your watch's sensors and can be wrong.")
                    .foregroundStyle(.secondary)

                Button("I Understand") {
                    onAcknowledge()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Health Notice")
    }
}
