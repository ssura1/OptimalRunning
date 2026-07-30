import AVFoundation
import Foundation
import PhoneSupport

/// Speaks cues over whatever the runner is listening to (S-041, design.md §9.3).
///
/// **The audio session configuration is the whole product on this tier.** Audio is the
/// primary feedback channel (ADR-S-05), so a cue that does not arrive is not a missing
/// nicety — it is the app not working. Three settings carry that, and each one is a
/// separate requirement rather than a plausible default:
///
/// - `.playback` is what makes a cue audible **when the ring/silent switch is set to
///   silent** (AC-FR-S-D-1-4). Most runners run with their phone on silent. `.ambient`
///   would be the tidier-looking choice and would silence the product for most of its
///   users.
/// - `.duckOthers` lowers the music for the cue and restores it afterwards, rather than
///   stopping it.
/// - `.mixWithOthers` keeps the other app playing at all.
///
/// This file is on the manual protocol: whether a cue is *intelligible* at running speed
/// over wind and music is not something CI can answer (AC-FR-S-D-1-9, §12.2).
@MainActor
final class SpeechCuePlayer: NSObject, CueSpeaking {

    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private var isConfigured = false
    /// DEG-S-10 — a call is in progress, so nothing is spoken until it ends. Haptics keep
    /// firing throughout, which is why the run does not go silent in the sense that
    /// matters.
    private var isInterrupted = false

    /// Cues that arrived during an interruption.
    ///
    /// Deliberately **only the most recent**, not a queue. A runner returning from a
    /// two-minute phone call does not want to hear the four pace corrections they missed —
    /// three of them describe a pace they are no longer running. Speaking the latest is the
    /// only one that is still true.
    private var deferredCue: SpokenCue?

    override init() {
        super.init()
        synthesizer.delegate = self

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CueSpeaking

    func speak(_ cue: SpokenCue) {
        guard !isInterrupted else {
            deferredCue = cue
            return
        }
        activateIfNeeded()

        let utterance = AVSpeechUtterance(string: cue.phrase)
        // Slightly above the default rate. A cue is short and fixed-form, and a runner is
        // waiting to act on it — the default reads as unhurried in a way that is wrong for
        // "ease off". Not so fast that it needs concentration to parse, which would defeat
        // the point of not having to look at anything.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    /// Stops immediately and releases the session (AC-FR-S-A-2-3, NFR-S-6).
    ///
    /// `.immediate`, not `.word`: a run that has ended should end, and holding the session
    /// open to finish a sentence holds a wake source open with it.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deferredCue = nil
        guard isConfigured else { return }
        // `notifyOthersOnDeactivation` is what tells the music app it may return to full
        // volume. Without it a runner's music stays ducked after the run ends.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isConfigured = false
    }

    // MARK: - Session

    private func activateIfNeeded() {
        guard !isConfigured else { return }
        do {
            try session.setCategory(
                .playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true)
            isConfigured = true
        } catch {
            // A session that will not activate is a run without its primary channel, and
            // that is a degradation rather than a failure: haptics are a complete channel
            // on their own (AC-FR-S-D-2-5), and the screen still shows everything. Failing
            // the run here would trade a reduced product for no product.
            isConfigured = false
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // DEG-S-10. The run keeps recording and keeps buzzing; only the voice pauses.
            isInterrupted = true
            synthesizer.stopSpeaking(at: .immediate)
            isConfigured = false
        case .ended:
            isInterrupted = false
            if let deferred = deferredCue {
                deferredCue = nil
                speak(deferred)
            }
        @unknown default:
            isInterrupted = false
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        // DEG-S-9 — headphones came out. The run continues and cues move to the speaker
        // rather than silently ceasing, which is the failure mode that matters: a runner
        // who loses a headphone would otherwise get no feedback for the rest of the run and
        // no indication that anything had changed.
        //
        // Nothing needs to be *done* to move them — the session already routes to the
        // built-in speaker once the old route is gone. What matters is that the session is
        // not torn down and that the next cue reactivates it, which is what clearing the
        // flag arranges.
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override:
            isConfigured = false
        default:
            break
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechCuePlayer: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        // Deliberately empty of session teardown. Deactivating between cues would unduck
        // and reduck the runner's music every time — an audible stutter every minute — and
        // the session costs nothing to hold for the duration of a run that has already
        // declared the `audio` background mode.
    }
}
