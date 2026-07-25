import SwiftUI
import ORColor
import ORModels
import WatchSupport

/// Watch settings (T-047).
///
/// Four settings, each persisting immediately through `SettingsStore` — there is no Save
/// button and no Done handler, because a watch app can be terminated the moment a workout
/// ends and a deferred write would be lost. `SettingsStoreTests` asserts the persistence;
/// this view only binds.
struct SettingsView: View {

    @Bindable var store: SettingsStore

    var body: some View {
        List {
            Section("Alerts") {
                // AC-FR-B-1-7 — this switches off *pace* haptics only. The footer says so
                // explicitly, because a runner who wanted silence and then missed their
                // interval transitions would reasonably call that a bug.
                Toggle(
                    "Pace Haptics",
                    isOn: Binding(
                        get: { store.profile.paceHapticsEnabled },
                        set: { store.setPaceHapticsEnabled($0) }
                    )
                )
                Text("Interval and workout haptics keep working.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Intervals") {
                // AC-FR-C-3-3 — opt-in, and off by default: a crown detent that advanced
                // steps without being asked for would end reps whenever a sleeve brushed
                // the crown.
                Toggle(
                    "Crown Advances Steps",
                    isOn: Binding(
                        get: { store.profile.crownAdvanceEnabled },
                        set: { store.setCrownAdvanceEnabled($0) }
                    )
                )
            }

            Section("Display") {
                palettePicker
            }

            Section("Units") {
                Picker(
                    "Distance",
                    selection: Binding(
                        get: { store.profile.units },
                        set: { store.setUnits($0) }
                    )
                ) {
                    Text("Miles").tag(UnitPreference.miles)
                    Text("Kilometres").tag(UnitPreference.kilometres)
                }
            }
        }
        .navigationTitle("Settings")
    }

    /// The CVD-safe palette toggle (AC-FR-J-2-3).
    ///
    /// Shows a live swatch strip for each option rather than only a name. Someone choosing
    /// between colour palettes because of a colour vision deficiency cannot evaluate the
    /// choice from the words "Standard" and "High Contrast" — they need to see the actual
    /// colours, which is the one case where a preview is not decoration.
    private var palettePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Colours",
                selection: Binding(
                    get: { store.profile.palette },
                    set: { store.setPalette($0) }
                )
            ) {
                Text("Standard").tag(PaletteChoice.standard)
                Text("Colour-Safe").tag(PaletteChoice.colorVisionDeficiency)
            }

            PaletteSwatchStrip(palette: store.profile.palette)
        }
    }
}

/// The five judged zones in order, as the runner will actually see them.
private struct PaletteSwatchStrip: View {

    let palette: PaletteChoice

    /// Judged zones only, in fast-to-slow order. `neutral` is excluded because it is not
    /// a pace judgement and its inclusion would make the strip read as six steps of one
    /// scale.
    private static let zones: [PaceZone] = [
        .tooFast, .slightlyFast, .onTarget, .slightlySlow, .tooSlow,
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.zones, id: \.self) { zone in
                let swatch = ZonePalette.palette(for: palette).swatch(for: zone)
                // The glyph rides on the swatch here too — the preview would otherwise
                // misrepresent the run screen as colour-only (FR-J-1).
                Image(systemName: ZoneAffordance.affordance(for: zone).symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(swatch.text))
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(Color(swatch.background))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .accessibilityHidden(true)
    }
}
