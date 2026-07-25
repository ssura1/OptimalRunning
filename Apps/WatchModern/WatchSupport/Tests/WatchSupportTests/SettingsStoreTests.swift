import XCTest
import ORModels
@testable import WatchSupport

/// T-047 — each setting persists across launches, takes effect immediately, and can be
/// replaced wholesale by a phone sync.
@MainActor
final class SettingsStoreTests: XCTestCase {

    /// A second `SettingsStore` over the same backing is what a relaunch looks like.
    private func relaunch(_ backing: KeyValueStoring) -> SettingsStore {
        SettingsStore(backing: backing)
    }

    func testDefaultsAreUsedWhenNothingWasEverStored() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())
        XCTAssertEqual(store.profile.units, .miles)
        XCTAssertEqual(store.profile.palette, .standard)
        XCTAssertTrue(store.profile.paceHapticsEnabled)
        XCTAssertFalse(store.profile.crownAdvanceEnabled)
    }

    // MARK: - Immediate effect, then persistence

    func testEverySettingTakesEffectImmediatelyAndSurvivesALaunch() {
        let backing = InMemoryKeyValueStore()
        let store = SettingsStore(backing: backing)

        store.setPaceHapticsEnabled(false)
        store.setCrownAdvanceEnabled(true)
        store.setPalette(.colorVisionDeficiency)
        store.setUnits(.kilometres)

        // Immediately.
        XCTAssertFalse(store.profile.paceHapticsEnabled)
        XCTAssertTrue(store.profile.crownAdvanceEnabled)
        XCTAssertEqual(store.profile.palette, .colorVisionDeficiency)
        XCTAssertEqual(store.profile.units, .kilometres)

        // And after a relaunch.
        let relaunched = relaunch(backing)
        XCTAssertFalse(relaunched.profile.paceHapticsEnabled)
        XCTAssertTrue(relaunched.profile.crownAdvanceEnabled)
        XCTAssertEqual(relaunched.profile.palette, .colorVisionDeficiency)
        XCTAssertEqual(relaunched.profile.units, .kilometres)
    }

    /// AC-FR-J-2-3 — the CVD-safe palette toggle specifically, since it is the one
    /// setting whose whole purpose is that a runner who needs it never has to set it
    /// twice.
    func testTheCVDPaletteToggleRoundTrips() {
        let backing = InMemoryKeyValueStore()
        let store = SettingsStore(backing: backing)

        store.setPalette(.colorVisionDeficiency)
        XCTAssertEqual(relaunch(backing).profile.palette, .colorVisionDeficiency)

        store.setPalette(.standard)
        XCTAssertEqual(relaunch(backing).profile.palette, .standard)
    }

    func testBasePacesPersistPerRunType() {
        let backing = InMemoryKeyValueStore()
        let store = SettingsStore(backing: backing)

        store.setBasePace(Pace(minutesPerMile: 7.5), for: .tempo)
        store.setBasePace(Pace(minutesPerMile: 9.5), for: .easy)
        store.setBasePace(Pace(minutesPerMile: 9), for: .long)

        let relaunched = relaunch(backing)
        XCTAssertEqual(relaunched.profile.basePace(for: .tempo)?.minutesPerMile ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(relaunched.profile.basePace(for: .easy)?.minutesPerMile ?? 0, 9.5, accuracy: 1e-9)
        XCTAssertEqual(relaunched.profile.basePace(for: .long)?.minutesPerMile ?? 0, 9, accuracy: 1e-9)
    }

    /// Interval and VO2 max carry targets per step, not per run (FR-C-5), so there is
    /// nothing to store — and storing something would create a value nothing reads.
    func testSettingABasePaceForStructuredTypesIsIgnored() {
        let store = SettingsStore(backing: InMemoryKeyValueStore())

        store.setBasePace(Pace(minutesPerMile: 6), for: .interval)
        store.setBasePace(Pace(minutesPerMile: 6), for: .vo2max)

        XCTAssertNil(store.profile.basePace(for: .interval))
        XCTAssertNil(store.profile.basePace(for: .vo2max))
    }

    // MARK: - Phone sync

    func testASyncedProfileReplacesLocalSettings() {
        let backing = InMemoryKeyValueStore()
        let store = SettingsStore(backing: backing)
        store.setUnits(.kilometres)

        store.apply(synced: RunnerProfile(
            tempoPace: Pace(minutesPerMile: 7), units: .miles,
            palette: .colorVisionDeficiency, paceHapticsEnabled: false
        ))

        XCTAssertEqual(store.profile.units, .miles)
        XCTAssertEqual(store.profile.palette, .colorVisionDeficiency)
        XCTAssertFalse(store.profile.paceHapticsEnabled)
        XCTAssertEqual(relaunch(backing).profile.units, .miles, "a sync did not persist")
    }

    // MARK: - Corruption

    /// A blob that will not decode falls back to defaults rather than trapping. Losing
    /// seven settings is recoverable in seconds; a launch crash is not.
    func testCorruptStoredDataFallsBackToDefaults() {
        let backing = InMemoryKeyValueStore()
        backing.set(Data("not json".utf8), forKey: "com.optimalrunner.profile.v1")

        let store = SettingsStore(backing: backing)
        XCTAssertEqual(store.profile.units, .miles)
        XCTAssertTrue(store.profile.paceHapticsEnabled)
    }
}
