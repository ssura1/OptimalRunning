import AVFoundation
import Foundation
import ORModels
import PhoneSupport

/// The slice of `AVAudioSession` this player uses.
///
/// Extracted so the *sequence* of session calls is testable, because the sequence is where
/// the bug was: a category and an activation with no matching deactivation reads as
/// perfectly reasonable code and leaves a runner's music quiet for half an hour. There is
/// no way to observe ducking from a test — but "was the session released after the
/// utterance, and with `.notifyOthersOnDeactivation`" is exactly the question, and it is
/// answerable.
///
/// `AVAudioSession` already declares both methods with these signatures, so the real
/// conformance is empty.
protocol AudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionControlling {}

/// Speaks cues over whatever the runner is listening to (S-041, S-065, design.md §9.3).
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
/// - `.duckOthers` lowers the music for the cue rather than stopping it.
/// - `.mixWithOthers` keeps the other app playing at all.
///
/// ## The session is held for a cue, not for a run
///
/// This is the correction from the 2026-07-30 field test, and it is the difference between
/// the feature working and the feature being unusable. **`.duckOthers` ducks for as long as
/// the session is active**, not for as long as something is speaking. The first version
/// activated at the first cue and deactivated at `stop()`, reasoning that reactivating per
/// cue would make the music stutter — but the alternative it actually chose was the
/// runner's music staying quiet for the entire run. It never came back up until the run
/// ended.
///
/// So: activate for each cue, and deactivate once the utterance has finished, with
/// `.notifyOthersOnDeactivation` — which is the signal that tells the music app it may
/// return to full volume. Nothing else restores it. The stutter the original comment worried
/// about is real but small, and it is bounded by `quietPeriod` below, which coalesces cues
/// that arrive together.
///
/// This file is on the manual protocol: whether a cue is *intelligible* at running speed
/// over wind and music is not something CI can answer (AC-FR-S-D-1-9, §12.2).
@MainActor
final class SpeechCuePlayer: NSObject, CueSpeaking {

    /// How long an utterance waits before its first word.
    ///
    /// The duck ramp is not instant. Speaking the moment `setActive(true)` returns puts
    /// "Ease off" underneath music that is still at full volume, which is what made the
    /// first cue of the 2026-07-30 test audible but unparseable. This is the lead-in that
    /// lets the ramp finish first.
    private static let leadInSeconds: TimeInterval = 0.3
    /// A short tail so `didFinish` is not racing the final phoneme out of the speaker.
    private static let tailSeconds: TimeInterval = 0.15
    /// How long to wait after speaking before releasing the session.
    ///
    /// Coalescing, not politeness: a step transition and a split can land within a second
    /// of each other, and unducking between them would produce exactly the stutter that is
    /// worth avoiding. Long enough to absorb that, short enough that the music is back
    /// before a runner notices it left.
    private static let quietPeriod: TimeInterval = 0.25
    private static let retryDelay: TimeInterval = 0.4
    private static let deactivationAttempts = 3
    /// The longest the session is ever held for one cue.
    ///
    /// A backstop, not a schedule. The release is driven by the synthesizer reporting an
    /// utterance finished or cancelled, and if that report never arrives — a synthesizer
    /// that declines to speak because the session would not activate, an audio route that
    /// disappears at the wrong moment — the count never returns to zero and the session is
    /// held for the rest of the run. Which is precisely the bug this file exists to fix,
    /// reachable by a second route.
    ///
    /// So: whatever else happens, the runner's music comes back within this. No cue is
    /// remotely this long, so a well-behaved run never reaches it.
    private static let defaultMaximumHoldSeconds: TimeInterval = 30

    private let synthesizer = AVSpeechSynthesizer()
    private let session: any AudioSessionControlling

    /// A second synthesizer used only to render warm-up audio that is thrown away.
    ///
    /// Separate from the speaking one because `write(_:toBufferCallback:)` and `speak(_:)`
    /// are not meant to be interleaved on one instance. It renders offline and never
    /// touches the audio session, which is the point — warming up must not duck the
    /// runner's music while they are still standing at the trailhead.
    private let warmUpSynthesizer = AVSpeechSynthesizer()

    private var settings = SpeechSettings(profile: RunnerProfile())
    private var voice: AVSpeechSynthesisVoice?

    /// Whether the category has been set and the session activated since the last teardown.
    ///
    /// Only ever used to decide whether to *configure*. Deactivation never consults it —
    /// see `deactivate()`.
    private var isSessionActive = false

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

    private var deactivation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let maximumHoldSeconds: TimeInterval

    /// Utterances handed to the synthesizer that have not reported back.
    ///
    /// The player's own count rather than `synthesizer.isSpeaking`, for two reasons. It is
    /// the honest question — "is another cue already on its way" is about what this class
    /// has queued, not about which phoneme the engine is on — and `isSpeaking` cannot be
    /// observed from a test without a real audio route, which would put the release
    /// sequence back out of reach of CI.
    ///
    /// A delegate callback that never arrives would leave this above zero forever, which
    /// would hold the session for the rest of the run. `startWatchdog` is what stops that
    /// from being possible; `stop()` resets it at the end of every run regardless.
    private var utterancesInFlight = 0

    init(
        session: any AudioSessionControlling = AVAudioSession.sharedInstance(),
        maximumHoldSeconds: TimeInterval = SpeechCuePlayer.defaultMaximumHoldSeconds
    ) {
        self.session = session
        self.maximumHoldSeconds = maximumHoldSeconds
        super.init()
        synthesizer.delegate = self

        // `object: nil` rather than scoping to the session. There is exactly one
        // `AVAudioSession` in a process, so the scope filters nothing — and with the
        // session injectable, scoping it would mean a test's fake session silently
        // unsubscribes the player from the interruption notifications it still needs.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CueSpeaking

    func prepare(_ settings: SpeechSettings) {
        self.settings = settings
        voice = SpeechVoiceCatalog.voice(for: settings.voiceIdentifier)
        warmUp()
    }

    func speak(_ cue: SpokenCue) {
        guard !isInterrupted else {
            deferredCue = cue
            return
        }
        // A cue arriving while a release is pending cancels it — the session is about to be
        // used again, and unducking only to reduck a moment later is the stutter.
        deactivation?.cancel()
        deactivation = nil
        activateIfNeeded()

        utterancesInFlight += 1
        synthesizer.speak(utterance(for: cue))
        startWatchdog()
    }

    /// Stops immediately and releases the session (AC-FR-S-A-2-3, NFR-S-6).
    ///
    /// `.immediate`, not `.word`: a run that has ended should end, and holding the session
    /// open to finish a sentence holds a wake source open with it.
    func stop() {
        deactivation?.cancel()
        deactivation = nil
        watchdog?.cancel()
        watchdog = nil
        synthesizer.stopSpeaking(at: .immediate)
        deferredCue = nil
        utterancesInFlight = 0
        // Retried on failure rather than attempted once. This is the path that leaves a
        // runner's music ducked after the run if it silently fails.
        if !deactivate() { scheduleDeactivation(immediately: true) }
    }

    /// One utterance reported back, whether it completed or was cut off.
    private func utteranceEnded() {
        utterancesInFlight = max(0, utterancesInFlight - 1)
        guard utterancesInFlight == 0 else { return }
        watchdog?.cancel()
        watchdog = nil
        // A cue cut short by an incoming call arrives here too, via `didCancel`. The system
        // has already taken the session for the call, and deactivating now would be this app
        // reaching into it — so an interruption releases nothing and the `.ended` handler
        // reactivates from scratch.
        guard !isInterrupted else { return }
        scheduleDeactivation()
    }

    // MARK: - Utterance

    private func utterance(for cue: SpokenCue) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: cue.phrase)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(settings.rateScale)
        utterance.preUtteranceDelay = Self.leadInSeconds
        utterance.postUtteranceDelay = Self.tailSeconds
        return utterance
    }

    /// Renders one short utterance offline and discards it.
    ///
    /// The first thing a synthesizer speaks after launch pays for loading the voice asset,
    /// and on a Premium voice that is not free. Paying it here, before the run, rather than
    /// in the middle of the first pace cue.
    ///
    /// A mitigation rather than a guarantee — whether the speech service keeps the asset
    /// warm across synthesizer instances is not contractual, which is why first-cue
    /// intelligibility stays on the manual protocol (§3.2) instead of being marked verified.
    private func warmUp() {
        let warmUp = AVSpeechUtterance(string: "ready")
        warmUp.voice = voice
        warmUp.volume = 0
        warmUpSynthesizer.write(warmUp) { _ in }
    }

    // MARK: - Session

    private func activateIfNeeded() {
        guard !isSessionActive else { return }
        do {
            try session.setCategory(
                // `.voicePrompt`, not `.spokenAudio`. The two are near-opposites of intent:
                // `.spokenAudio` declares *this* app to be the podcast, and asks others to
                // pause for it. `.voicePrompt` is the mode for navigation-style TTS spoken
                // over someone else's audio, which is exactly what a pace cue is.
                .playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            // `options: []` spelled out. The real `AVAudioSession` defaults this, but the
            // protocol does not — and `.notifyOthersOnDeactivation` is meaningless on
            // activation, so there is nothing to carry over.
            try session.setActive(true, options: [])
            isSessionActive = true
        } catch {
            // A session that will not activate is a run without its primary channel, and
            // that is a degradation rather than a failure: haptics are a complete channel
            // on their own (AC-FR-S-D-2-5), and the screen still shows everything. Failing
            // the run here would trade a reduced product for no product.
            isSessionActive = false
        }
    }

    /// Releases the session and tells the music app it may come back up.
    ///
    /// **Not guarded on `isSessionActive`.** A route change clears that flag while the
    /// session is still active and still ducking, and a guard here would turn that into
    /// music that never recovers — the exact bug this file exists to fix, reintroduced
    /// through a plausible-looking early return.
    @discardableResult
    private func deactivate() -> Bool {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isSessionActive = false
            return true
        } catch {
            return false
        }
    }

    /// Releases the session unconditionally if no utterance ever reports back.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.maximumHoldSeconds ?? 0))
            guard !Task.isCancelled, let self, self.utterancesInFlight > 0 else { return }
            // The count is not trustworthy any more — an utterance it is waiting on will
            // never arrive — so clear it rather than decrementing, or the next cue starts
            // from a number that can never reach zero either.
            self.utterancesInFlight = 0
            guard !self.isInterrupted else { return }
            self.deactivate()
        }
    }

    private func scheduleDeactivation(immediately: Bool = false) {
        deactivation?.cancel()
        deactivation = Task { [weak self] in
            for attempt in 0..<Self.deactivationAttempts {
                let delay = attempt == 0 && immediately ? 0 : Self.delay(forAttempt: attempt)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self else { return }
                // A new cue started during the quiet period. `speak` cancelled this task,
                // but a task already suspended past its cancellation point still resumes —
                // so re-read the state rather than trusting that the cancel landed in time.
                guard self.utterancesInFlight == 0, !self.isInterrupted else { return }
                if self.deactivate() { return }
            }
        }
    }

    private static func delay(forAttempt attempt: Int) -> TimeInterval {
        attempt == 0 ? quietPeriod : retryDelay
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // DEG-S-10. The run keeps recording and keeps buzzing; only the voice pauses.
            // The system has already deactivated the session, so there is nothing to
            // release — and a pending release would fire into someone else's call.
            deactivation?.cancel()
            deactivation = nil
            watchdog?.cancel()
            watchdog = nil
            isInterrupted = true
            synthesizer.stopSpeaking(at: .immediate)
            utterancesInFlight = 0
            isSessionActive = false
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
        // built-in speaker once the old route is gone. What matters is that the next cue
        // reconfigures, which is what clearing the flag arranges.
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override:
            isSessionActive = false
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
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    /// `stopSpeaking(at:)` produces this rather than `didFinish`, and a cancelled cue leaves
    /// the session just as active as a completed one.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }
}
