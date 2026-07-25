import Foundation
import Observation
import ORModels

/// The persistence primitive settings need, narrowed to two calls.
///
/// `UserDefaults` satisfies this in the app; an in-memory dictionary satisfies it in
/// tests. Narrowing it to `Data` rather than exposing typed accessors keeps the
/// encoding decision in one place, and means "does a setting survive a launch?" is
/// testable by constructing a second store over the same backing (T-047's Done-when),
/// with no simulator and no defaults domain to clean up between tests.
public protocol KeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// In-memory backing, for tests and for previews.
public final class InMemoryKeyValueStore: KeyValueStoring {
    private var storage: [String: Data]

    public init(storage: [String: Data] = [:]) {
        self.storage = storage
    }

    public func data(forKey key: String) -> Data? { storage[key] }

    public func set(_ data: Data?, forKey key: String) {
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
}

/// Persists the runner profile and exposes it to the settings UI (T-047).
///
/// The whole `RunnerProfile` is stored as one JSON blob rather than as a key per
/// field, and that is a deliberate trade. A blob cannot end up half-migrated — a
/// launch either reads a coherent profile or falls back to defaults — whereas
/// per-field keys drift into states like "units say kilometres, palette key missing",
/// which is exactly the class of bug that shows up only on a real watch six months
/// later. The cost is that a decode failure loses every setting at once; acceptable
/// because there are seven of them and re-entering is seconds of work, while a
/// silently wrong pace target is a ruined run.
///
/// The phone is authoritative when it syncs (`AC-FR-I-1-4`) — `apply(synced:)` is that
/// path, kept distinct from local edits so a sync can never be mistaken for a user
/// action or vice versa.
@MainActor
@Observable
public final class SettingsStore {

    private static let profileKey = "com.optimalrunner.profile.v1"

    public private(set) var profile: RunnerProfile

    private let backing: KeyValueStoring

    public init(backing: KeyValueStoring) {
        self.backing = backing
        if let data = backing.data(forKey: Self.profileKey),
           let decoded = try? JSONDecoder().decode(RunnerProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = RunnerProfile()
        }
    }

    // MARK: - Individual settings

    /// AC-FR-B-1-7 — pace haptics off must leave interval haptics working. That
    /// guarantee lives in `RunEngine`'s suppression, which reads exactly this flag;
    /// nothing here needs to know about haptics beyond storing the bit.
    public func setPaceHapticsEnabled(_ enabled: Bool) {
        mutate { $0.paceHapticsEnabled = enabled }
    }

    /// AC-FR-C-3-3 — opt-in crown detent for manual step advance.
    public func setCrownAdvanceEnabled(_ enabled: Bool) {
        mutate { $0.crownAdvanceEnabled = enabled }
    }

    /// AC-FR-J-2-3 — the CVD-safe palette toggle.
    public func setPalette(_ palette: PaletteChoice) {
        mutate { $0.palette = palette }
    }

    /// AC-FR-I-1-4 — miles or kilometres. Stored data is unit-independent, so this
    /// re-renders rather than converting anything.
    public func setUnits(_ units: UnitPreference) {
        mutate { $0.units = units }
    }

    public func setBasePace(_ pace: Pace?, for runType: RunType) {
        mutate {
            switch runType {
            case .tempo: $0.tempoPace = pace
            case .easy: $0.easyPace = pace
            case .long: $0.longPace = pace
            // Interval and VO2 max carry targets per step, not per run (FR-C-5), so
            // there is no profile field to set. Silently ignoring beats a crash and
            // beats a stored value that nothing would ever read.
            case .interval, .vo2max: break
            }
        }
    }

    /// Replaces the profile wholesale from a phone sync.
    public func apply(synced profile: RunnerProfile) {
        self.profile = profile
        persist()
    }

    private func mutate(_ change: (inout RunnerProfile) -> Void) {
        var copy = profile
        change(&copy)
        profile = copy
        persist()
    }

    /// Writes on every change rather than on background — a watch app can be
    /// terminated without a background transition when a workout ends.
    private func persist() {
        backing.set(try? JSONEncoder().encode(profile), forKey: Self.profileKey)
    }
}
