import Foundation
import WatchKit
import WatchSupport

/// Plays a `HapticPattern` on the watch (T-042).
///
/// The mapping to `WKHapticType` is the entire content of this file, and choosing the
/// types is the one judgement in it. `.directionUp` / `.directionDown` are used for the
/// two pace corrections rather than the generic `.notification` because watchOS gives
/// them genuinely different tactile shapes — an ascending and a descending pattern — which
/// is what AC-FR-B-1-3 requires: distinguishable without looking. Reusing `.notification`
/// for both would technically fire a haptic and fail the requirement.
///
/// Whether they *feel* different on a wrist is hardware-only and is on the manual
/// protocol; that they are three different types is asserted in `HapticDispatcherTests`.
final class WatchHapticPlayer: HapticPlaying {

    func play(_ pattern: HapticPattern) {
        WKInterfaceDevice.current().play(Self.hapticType(for: pattern))
    }

    static func hapticType(for pattern: HapticPattern) -> WKHapticType {
        switch pattern {
        // "Ease off" — a descending pattern.
        case .slowDown: return .directionDown
        // "Pick it up" — ascending.
        case .speedUp: return .directionUp
        // Deliberately dissimilar to both of the above (AC-FR-C-2-2).
        case .stepTransition: return .notification
        case .workoutComplete: return .success
        }
    }
}
