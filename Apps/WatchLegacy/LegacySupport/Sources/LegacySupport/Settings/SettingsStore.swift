import Combine
import Foundation
import ORModels

/// The watch's own settings — Legacy tier (T-070, AC-FR-J-2-3).
///
/// A deliberate duplicate of the Modern tier's store (AC-FR-K-1-4), with the Double Tap preference
/// **absent** rather than present-and-disabled: Series 3 has no such hardware, so a setting for it
/// would be a control that does nothing. T-070's scope is explicitly "parity with T-046/T-047 minus
/// Double Tap settings".
///
/// `ObservableObject` for the same reason `RunSessionModel` is — `@Observable` needs watchOS 10
/// (design.md §8.1).
///
/// Persisted through an injectable `KeyValueStoring` rather than touching `UserDefaults` directly,
/// so the persistence behaviour is testable on the host. On this tier that is not a nicety: there is
/// no watchOS 8 simulator, so anything reaching `UserDefaults.standard` directly would be verifiable
/// only on hardware.
public protocol KeyValueStoring: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func hasValue(forKey key: String) -> Bool
    func set(_ value: String, forKey key: String)
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: KeyValueStoring {
    public func hasValue(forKey key: String) -> Bool { object(forKey: key) != nil }
    public func set(_ value: String, forKey key: String) { setValue(value, forKey: key) }
    public func set(_ value: Bool, forKey key: String) { setValue(value, forKey: key) }
}

/// An in-memory store, for tests and previews.
public final class InMemoryKeyValueStore: KeyValueStoring {
    private var values: [String: Any] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    public func hasValue(forKey key: String) -> Bool { values[key] != nil }
    public func set(_ value: String, forKey key: String) { values[key] = value }
    public func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@MainActor
public final class SettingsStore: ObservableObject {

    private enum Key {
        static let units = "settings.units"
        static let palette = "settings.palette"
        static let paceHaptics = "settings.paceHaptics"
    }

    private let defaults: KeyValueStoring

    @Published public var units: UnitPreference {
        didSet { defaults.set(units.rawValue, forKey: Key.units) }
    }

    /// The CVD-safe palette choice (AC-FR-J-2-3).
    @Published public var palette: PaletteChoice {
        didSet { defaults.set(palette.rawValue, forKey: Key.palette) }
    }

    /// Pace haptics on/off (AC-FR-B-1-7). Never consulted in VO2 max, where `RunTypeSemantics`
    /// suppresses pace haptics regardless — a runner switching this on must not start getting pace
    /// buzzes during a VO2 max session.
    @Published public var paceHapticsEnabled: Bool {
        didSet { defaults.set(paceHapticsEnabled, forKey: Key.paceHaptics) }
    }

    public init(defaults: KeyValueStoring) {
        self.defaults = defaults

        self.units = defaults.string(forKey: Key.units)
            .flatMap(UnitPreference.init(rawValue:)) ?? .miles
        self.palette = defaults.string(forKey: Key.palette)
            .flatMap(PaletteChoice.init(rawValue:)) ?? .standard
        // `bool(forKey:)` returns false for a missing key, which would silently default pace haptics
        // *off* — the opposite of the intended default. Presence is checked explicitly.
        self.paceHapticsEnabled = defaults.hasValue(forKey: Key.paceHaptics)
            ? defaults.bool(forKey: Key.paceHaptics)
            : true
    }

    /// Applies these settings to a profile arriving from the phone, so a downlink cannot silently
    /// overwrite a preference the runner set on the watch.
    public func merged(into profile: RunnerProfile) -> RunnerProfile {
        var merged = profile
        merged.units = units
        merged.palette = palette
        return merged
    }
}
