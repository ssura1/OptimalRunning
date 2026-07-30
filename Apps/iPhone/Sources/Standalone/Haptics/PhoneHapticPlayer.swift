import Foundation
import PhoneSupport
import UIKit

/// Plays the tactile vocabulary on the Taptic Engine (S-043, FR-S-D-2).
///
/// **Which pattern fires and when is decided in `StandaloneHaptics`**, which is a pure
/// function in a testable package. This file is only the translation to UIKit, and it is on
/// the manual protocol for the one thing that cannot be automated: whether "ease off" and
/// "pick it up" are actually distinguishable in a hand at running pace (AC-FR-S-D-2-1,
/// §12.2). The Simulator has no Taptic Engine at all.
///
/// The patterns are built from `UIImpactFeedbackGenerator` rather than Core Haptics, and
/// that is a deliberate trade. Core Haptics would give richer envelopes; it also requires
/// its engine to be running, which is one more thing to keep alive across a backgrounded
/// run and one more thing that can fail silently. Impact generators are always available,
/// are audible-through-the-hand at running intensity, and — with the timing below — carry
/// direction well enough to be told apart. If the manual protocol says otherwise, this is
/// the file that changes.
@MainActor
final class PhoneHapticPlayer: HapticPlaying {

    /// Prepared generators. Preparation matters: an unprepared generator has a
    /// tens-of-milliseconds latency the first time, which for a rhythm made of two taps
    /// distorts the very thing that distinguishes the patterns.
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// Whether the device can produce distinct impact feedback at all.
    ///
    /// Not an availability check — every device this app supports has a Taptic Engine — but
    /// a Reduce-Motion-adjacent settings check would go here. AC-FR-S-D-2-5 requires
    /// graceful degradation rather than treating the absence of haptics as a failure to
    /// alert, and the honest form of that on this platform is that a generator whose
    /// hardware is unavailable is simply a no-op, which is what UIKit already does.
    init() {
        prepare()
    }

    func prepare() {
        heavy.prepare()
        light.prepare()
        rigid.prepare()
    }

    func play(_ pattern: StandaloneHapticPattern) {
        switch pattern {
        case .slowDown:
            // Descending: heavy then light. The falling intensity is the direction.
            tap(heavy)
            after(0.12) { self.tap(self.light) }
        case .speedUp:
            // Ascending: light then heavy.
            tap(light)
            after(0.12) { self.tap(self.heavy) }
        case .stepTransition:
            // Three even rigid taps — a rhythm neither pace pattern has, so it is
            // identifiable without having to judge intensity while out of breath.
            tap(rigid)
            after(0.10) { self.tap(self.rigid) }
            after(0.20) { self.tap(self.rigid) }
        case .workoutComplete:
            // Long and unmistakable: four heavy taps slowing down.
            tap(heavy)
            after(0.15) { self.tap(self.heavy) }
            after(0.35) { self.tap(self.heavy) }
            after(0.60) { self.tap(self.heavy) }
        case .notice:
            tap(light)
        }
    }

    private func tap(_ generator: UIImpactFeedbackGenerator) {
        generator.impactOccurred()
        // Re-prepared immediately so the next tap in the same pattern has no warm-up
        // latency of its own.
        generator.prepare()
    }

    private func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            work()
        }
    }
}
