import SwiftUI
import ORColor
import ORModels
import PhoneSupport
import SwiftData

/// First-run onboarding (T-062, FR-I-1, R-6).
///
/// Four steps, in the order the requirements imply: units, palette, target paces, and the health
/// notice. The palette comes **second**, not buried in a settings screen — AC-FR-J-2-3 exists
/// because someone who needs the colour-safe palette needs it before their first run, not after
/// discovering the default is unreadable to them.
///
/// Nothing here derives a pace without showing it first: AC-FR-I-1-3 requires every derived value
/// to be overridable, and a flow that computed three paces and moved on would technically satisfy
/// that while practically hiding them.
struct OnboardingView: View {

    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var step = 0
    @State private var profile = RunnerProfile(
        units: Locale.current.measurementSystem == .metric ? .kilometres : .miles
    )
    @State private var raceDistance: Double = 5_000
    @State private var raceMinutes = 25
    @State private var raceSeconds = 0
    @State private var hasDerived = false

    private var derived: PaceDerivation.DerivedPaces? {
        PaceDerivation.derive(from: RaceResult(
            distanceMetres: raceDistance, seconds: Double(raceMinutes * 60 + raceSeconds)
        ))
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                unitsStep.tag(0)
                paletteStep.tag(1)
                pacesStep.tag(2)
                disclaimerStep.tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle("Set Up")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Steps

    private var unitsStep: some View {
        OnboardingStep(
            title: "Miles or kilometres?",
            detail: "Everything is stored independently of this, so you can change it whenever you like."
        ) {
            Picker("Units", selection: $profile.units) {
                Text("Miles").tag(UnitPreference.miles)
                Text("Kilometres").tag(UnitPreference.kilometres)
            }
            .pickerStyle(.segmented)

            Button("Continue") { step = 1 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var paletteStep: some View {
        OnboardingStep(
            title: "Which colours read best?",
            detail: "Your watch fills the screen with a colour showing whether you are on target. "
                + "Pick whichever set you can tell apart most easily — a direction arrow is always "
                + "shown alongside the colour, on both."
        ) {
            ForEach(PaletteChoice.allCases, id: \.self) { choice in
                Button {
                    profile.palette = choice
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(choice == .standard ? "Standard" : "Colour-Safe")
                                .font(.headline)
                            Spacer()
                            if profile.palette == choice {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        OnboardingPaletteStrip(palette: choice)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(profile.palette == choice ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Button("Continue") { step = 2 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var pacesStep: some View {
        OnboardingStep(
            title: "What are your target paces?",
            detail: "Enter a recent race result and these are worked out for you. You can change "
                + "any of them now or later, and skip this entirely if you would rather set them "
                + "by hand."
        ) {
            Picker("Distance", selection: $raceDistance) {
                Text("5 km").tag(5_000.0)
                Text("10 km").tag(10_000.0)
                Text("Half").tag(21_097.5)
                Text("Marathon").tag(42_195.0)
            }
            .pickerStyle(.segmented)

            HStack {
                Stepper("\(raceMinutes) min", value: $raceMinutes, in: 10...360)
                Stepper("\(raceSeconds) s", value: $raceSeconds, in: 0...59)
            }
            .monospacedDigit()

            if let derived {
                VStack(spacing: 4) {
                    DerivedRow("Tempo", derived.tempo, profile.units)
                    DerivedRow("Easy", derived.easy, profile.units)
                    DerivedRow("Long", derived.long, profile.units)
                }
                .padding(.vertical, 4)

                Button("Use These Paces") {
                    profile.tempoPace = derived.tempo
                    profile.easyPace = derived.easy
                    profile.longPace = derived.long
                    hasDerived = true
                    step = 3
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Skip — I'll set them myself") { step = 3 }
                .font(.subheadline)
        }
    }

    /// R-6 — acknowledged before finishing, and the acknowledgement is what gates plan generation
    /// when Wave 5 adds it.
    private var disclaimerStep: some View {
        OnboardingStep(
            title: "Before you start",
            detail: "OptimalRunner suggests training paces from your own runs. It is not a medical "
                + "device and gives no medical advice.\n\nTalk to a doctor before starting or "
                + "changing a training programme, particularly if you have a heart condition, are "
                + "recovering from injury, or have been inactive. Stop and seek help if you feel "
                + "chest pain, dizziness, or unusual breathlessness."
        ) {
            Button("I Understand — Finish Setup") { finish() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func finish() {
        let repository = ProfileRepository(context: modelContext)
        try? repository.save(profile)
        try? repository.acknowledgeDisclaimer()
        onFinish()
    }
}

// MARK: - Pieces

private struct OnboardingStep<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2.weight(.bold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .padding(.bottom, 40)
        }
    }
}

private struct DerivedRow: View {
    let title: String
    let pace: Pace
    let unit: UnitPreference

    init(_ title: String, _ pace: Pace, _ unit: UnitPreference) {
        self.title = title
        self.pace = pace
        self.unit = unit
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(PhoneFormat.pace(pace, unit: unit)).monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct OnboardingPaletteStrip: View {
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
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(Color(swatch.background))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .accessibilityHidden(true)
    }
}
