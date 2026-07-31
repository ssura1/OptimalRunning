import ORModels
import PhoneSupport
import SwiftData
import SwiftUI

/// Standalone settings (S-052, FR-S-G-1).
///
/// **Everything here persists through the existing profile store** (AC-FR-S-G-1-4), which
/// is why there is no second settings record: a runner who also owns a watch gets these
/// fields synced across with everything else, and the watch decodes and ignores them.
///
/// The calibration section is the interesting one. It shows what was learned and offers a
/// reset, and it does both **without knowing what a calibration is** — the bytes come from
/// `CalibrationStoring` and the sentence comes from `CalibrationSummary`. That is the
/// isolation boundary paying for itself in the place it is least obvious: when S-064 changes
/// what a calibration contains, this screen keeps working and this file is not opened.
struct StandaloneSettingsView: View {

    @Environment(\.modelContext) private var modelContext

    @State private var profile = RunnerProfile()
    @State private var calibration: CalibrationSummary = .uncalibrated
    @State private var isImportingHeight = false
    @State private var showResetConfirmation = false
    @State private var voices: [SpeechVoiceOption] = []
    /// Held in `@State` so the sample plays through one synthesizer for the life of the
    /// screen rather than a new one per body evaluation.
    @State private var preview = SpeechCuePlayer()

    /// The three speeds offered, as multiples of the platform default.
    ///
    /// Named steps rather than a slider: the difference between 0.88 and 0.91 is not
    /// something a runner can choose meaningfully, and a slider invites them to try.
    private static let rateOptions: [(label: String, scale: Double)] = [
        ("Slower", 0.8),
        ("Normal", RunnerProfile.defaultSpeechRateScale),
        ("Faster", 1.0),
    ]

    /// Injected so the preview and the tests are not writing to the real one.
    let calibrationStore: any CalibrationStoring

    init(calibrationStore: any CalibrationStoring = CalibrationFileStore.inApplicationSupport()) {
        self.calibrationStore = calibrationStore
    }

    var body: some View {
        List {
            heightSection
            audioSection
            voiceSection
            hapticsSection
            calibrationSection
        }
        .navigationTitle("Phone Runs")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        // Leaving the screen mid-sample must not leave the runner's music ducked waiting
        // for a sentence nobody is listening to any more (S-065).
        .onDisappear { preview.stop() }
        .confirmationDialog(
            "Reset stride calibration?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetCalibration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // AC-FR-S-C-2-8 — the reset states what it does, in terms of consequence
            // rather than mechanism.
            Text(
                "Your phone will forget what it learned about your stride and start again "
                    + "on your next run. Recorded runs are not changed. Distance during GPS "
                    + "outages will be less accurate until it has relearned, which takes a "
                    + "few minutes of running with a good signal.")
        }
    }

    // MARK: - Sections

    private var heightSection: some View {
        Section {
            HStack {
                Text("Height")
                Spacer()
                if let height = profile.heightMetres {
                    Text(formatted(height: height)).foregroundStyle(.secondary)
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            // Editable without HealthKit permission, and offered from HealthKit rather than
            // asked for twice (AC-FR-S-G-1-1). Both halves matter: a runner who declines
            // Health must still be able to type it, and one who has it in Health should not
            // be asked to.
            Stepper(
                value: Binding(
                    get: { profile.heightMetres ?? 1.75 },
                    set: { profile.heightMetres = $0; save() }),
                in: 1.20...2.20,
                step: 0.01
            ) {
                Text("Adjust").foregroundStyle(.secondary)
            }
            Button {
                importHeightFromHealth()
            } label: {
                if isImportingHeight {
                    ProgressView()
                } else {
                    Text("Use Height from Health")
                }
            }
            .disabled(isImportingHeight)
        } header: {
            Text("Height")
        } footer: {
            Text(
                profile.heightMetres == nil
                    ? "The step-length model uses your height. Without it a standard 1.75 m "
                        + "is assumed and distance is marked lower-confidence until "
                        + "calibration settles."
                    : "Used by the step-length model to estimate distance when GPS is weak.")
        }
    }

    private var audioSection: some View {
        Section {
            Toggle("Spoken cues", isOn: binding(\.spokenCuesEnabled))
            Toggle("Split announcements", isOn: binding(\.splitAnnouncementsEnabled))
                .disabled(!profile.spokenCuesEnabled)
            Picker(
                "Time announcements",
                selection: Binding(
                    get: { profile.timeAnnouncementIntervalSeconds ?? 0 },
                    set: {
                        profile.timeAnnouncementIntervalSeconds = $0 == 0 ? nil : $0
                        save()
                    })
            ) {
                Text("Off").tag(TimeInterval(0))
                Text("Every 5 minutes").tag(TimeInterval(300))
                Text("Every 10 minutes").tag(TimeInterval(600))
            }
            .disabled(!profile.spokenCuesEnabled)
        } header: {
            Text("Audio")
        } footer: {
            Text(
                profile.spokenCuesEnabled
                    ? "Cues duck your music and are audible with the ring switch on silent."
                    : "With spoken cues off, haptics carry everything on their own.")
        }
    }

    /// Which voice, and how fast (S-066).
    ///
    /// Both settings exist because of one field test. The shipped voice was the compact
    /// system default — the robotic one — spoken 10% faster than the platform default, and
    /// the report was that it sounded robotic and was hard to follow while running.
    ///
    /// The footer is doing real work. A runner asking "can I use a better voice" deserves
    /// the true answer, which has two halves: no, you cannot install a third-party or Siri
    /// voice into an app, and yes, Apple's Enhanced and Premium voices are a free download
    /// that this picker will pick up. Only shown when there is in fact an upgrade to make.
    private var voiceSection: some View {
        Section {
            if voices.count > 1 {
                Picker("Voice", selection: voiceBinding) {
                    Text("Best available").tag(String?.none)
                    ForEach(voices) { option in
                        voiceLabel(option).tag(String?.some(option.id))
                    }
                }
            }
            Picker("Speed", selection: rateBinding) {
                ForEach(Self.rateOptions, id: \.scale) { option in
                    Text(option.label).tag(option.scale)
                }
            }
            .pickerStyle(.segmented)

            Button("Play a Sample") { playSample() }
        } header: {
            Text("Voice")
        } footer: {
            Text(
                SpeechVoiceCatalog.hasUpgradeAvailable(voices)
                    ? "Only the basic voice is installed, which is the robotic-sounding one. "
                        + "Better voices are a free download in Settings › Accessibility › "
                        + "Spoken Content › Voices — download an Enhanced or Premium English "
                        + "voice and it will appear here. Voices from other apps and Siri's "
                        + "own voice cannot be used."
                    : "Cues use the best voice installed on this phone. More are available in "
                        + "Settings › Accessibility › Spoken Content › Voices.")
        }
    }

    @ViewBuilder
    private func voiceLabel(_ option: SpeechVoiceOption) -> some View {
        if let quality = option.qualityLabel {
            Text("\(option.name) · \(quality)")
        } else {
            Text(option.name)
        }
    }

    private var hapticsSection: some View {
        Section {
            // The same setting the watch uses, deliberately — a runner who turned pace
            // haptics off on the watch has said what they want, and asking again on the
            // phone would be asking them to say it twice (AC-FR-B-1-7, AC-FR-S-D-2-4).
            Toggle("Pace haptics", isOn: binding(\.paceHapticsEnabled))
        } header: {
            Text("Haptics")
        } footer: {
            Text("Interval and workout haptics always fire, so a structured session is "
                + "still legible without the screen.")
        }
    }

    private var calibrationSection: some View {
        Section {
            LabeledContent("Status") {
                Text(statusText).foregroundStyle(.secondary)
            }
            if let metresPerStep = calibration.metresPerStepAtTypicalCadence {
                LabeledContent("Your stride") {
                    Text(String(format: "%.2f m per step", metresPerStep))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button("Reset Calibration", role: .destructive) {
                showResetConfirmation = true
            }
            .disabled(!calibration.isCalibrated)
        } header: {
            Text("Stride calibration")
        } footer: {
            Text(
                calibration.isCalibrated
                    ? "Learned from GPS while you run, and used to estimate distance when "
                        + "the signal drops. It keeps improving as you run."
                    : "Your phone learns your stride from GPS as you run. Until it has, "
                        + "distance during a GPS outage uses a published average and is "
                        + "less accurate.")
        }
    }

    // MARK: - State

    private var statusText: String {
        if !calibration.isCalibrated { return "Not calibrated yet" }
        if calibration.isConverged {
            return "Settled · \(calibration.observationCount) GPS stretches"
        }
        return "Learning · \(calibration.observationCount) GPS stretches"
    }

    private func binding(_ keyPath: WritableKeyPath<RunnerProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { profile[keyPath: keyPath] = $0; save() })
    }

    private func formatted(height: Double) -> String {
        switch profile.units {
        case .kilometres:
            return String(format: "%.2f m", height)
        case .miles:
            // Feet and inches, because a runner who thinks in miles thinks in feet — and a
            // height shown as "1.77 m" to someone who does not is a number they cannot
            // check.
            let totalInches = height / 0.0254
            let feet = Int(totalInches / 12)
            let inches = Int((totalInches - Double(feet) * 12).rounded())
            return "\(feet)′ \(inches)″"
        }
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { profile.speechVoiceIdentifier },
            set: { profile.speechVoiceIdentifier = $0; save(); applyToPreview() })
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { RunnerProfile.validSpeechRateScale(profile.speechRateScale) },
            set: { profile.speechRateScale = $0; save(); applyToPreview() })
    }

    private func load() {
        profile = (try? ProfileRepository(context: modelContext).profile()) ?? RunnerProfile()
        calibration = CalibrationBridge.summary(
            of: calibrationStore.loadCalibration(for: .handHeld))
        voices = SpeechVoiceCatalog.installed()
        applyToPreview()
    }

    private func applyToPreview() {
        preview.prepare(SpeechSettings(profile: profile))
    }

    /// A real cue rather than "This is a sample of the selected voice".
    ///
    /// The runner is choosing a voice for one job, and the only useful question is whether
    /// *this sentence* is followable at running speed. A generic sample answers a question
    /// nobody is asking.
    private func playSample() {
        preview.speak(
            SpokenCue(
                kind: .pace(.easeOff, secondsOff: 12),
                phrase: StandaloneStrings.paceCue(direction: .easeOff, secondsOff: 12)))
    }

    private func save() {
        try? ProfileRepository(context: modelContext).save(profile)
    }

    private func importHeightFromHealth() {
        isImportingHeight = true
        Task {
            defer { isImportingHeight = false }
            guard let metres = await HealthKitHeightReader.height() else { return }
            profile.heightMetres = metres
            save()
        }
    }

    private func resetCalibration() {
        calibrationStore.saveCalibration(nil, for: .handHeld)
        calibration = .uncalibrated
    }
}
