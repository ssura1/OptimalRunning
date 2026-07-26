import Foundation
import WatchKit
import LegacySupport

/// Plays haptics on real hardware — Legacy tier (T-068, FR-B-1).
///
/// The entire mapping from the app's tactile vocabulary to WatchKit, and nothing else: *which*
/// pattern fires and *when* were decided by `Core`'s `AlertPolicy` and relayed by
/// `HapticDispatcher`, both of which are unit-tested. What is left here is only "how it feels", which
/// no test can assert.
///
/// On this tier that residue is a genuine hardware question rather than a formality. Series 3's
/// haptic engine is the weakest in the supported range, and the requirement that
/// `.stepTransition` be identifiable *without looking* (AC-FR-B-1-3, AC-FR-C-2-2) depends on the
/// patterns feeling distinct on that engine specifically. It is on the hardware-verification list.
///
/// `.directionUp`/`.directionDown` for the pace patterns rather than `.notification` for both: they
/// are ascending and descending, so the direction is carried by the sensation itself and matches the
/// glyph on screen. `.success` marks a step boundary because it is the most distinct of the
/// available patterns from the two directional ones, and `.stop` marks completion.
final class WatchHapticPlayer: HapticPlaying {

    func play(_ pattern: HapticPattern) {
        WKInterfaceDevice.current().play(watchKitType(for: pattern))
    }

    private func watchKitType(for pattern: HapticPattern) -> WKHapticType {
        switch pattern {
        case .slowDown: return .directionDown
        case .speedUp: return .directionUp
        case .stepTransition: return .success
        case .workoutComplete: return .stop
        }
    }
}
