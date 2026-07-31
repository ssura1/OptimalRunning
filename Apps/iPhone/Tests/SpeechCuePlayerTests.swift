import AVFoundation
import Foundation
import ORModels
import PhoneSupport
import XCTest

@testable import OptimalRunner

/// The audio session sequence around a spoken cue (S-065, AC-FR-S-D-1-3, AC-FR-S-D-1-4).
///
/// **These exist because of a specific field failure.** On 2026-07-30 the app ducked the
/// runner's music for the first cue and never brought it back — not after the cue, not for
/// the rest of the run. The cause was one activation held for the whole run, which is what
/// `.duckOthers` means by "duck": for as long as the session is active, not for as long as
/// something is speaking.
///
/// Ducking itself cannot be observed from a test — there is no API that reports another
/// app's volume, and a simulator has no other app. What *can* be observed is the sequence
/// of session calls, and the sequence is where the bug lived: an activation with no
/// matching `setActive(false, options: .notifyOthersOnDeactivation)`. That call is the only
/// thing that tells the music app it may come back up, so its presence, its options, and
/// its timing relative to the utterance are the whole of what these assert.
///
/// What is still on the manual protocol (§3.1): whether the music *audibly* returns, and
/// whether the transition is smooth enough not to be distracting.
final class SpeechCuePlayerTests: XCTestCase {

    /// Generous: it is bounded by the player's quiet period plus main-actor scheduling, and
    /// a flaky failure here would be read as the bug returning.
    private let releaseTimeout: TimeInterval = 3

    // MARK: - The reported bug

    @MainActor
    func testTheSessionIsReleasedAfterACueSoMusicCanComeBackUp() async {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)

        let released = expectation(description: "session released")
        session.fulfillOnDeactivation(released)

        player.speak(.easeOff)
        XCTAssertTrue(
            session.events.contains(.activated),
            "A cue must activate the session — without it nothing is audible on silent.")

        // The delegate is driven rather than waited on. A simulator has no audio route, so
        // the real synthesizer never speaks and never reports back — waiting for it would
        // make this test about AVFoundation's willingness to produce sound rather than
        // about what this class does when a cue ends.
        player.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: ""))
        await fulfillment(of: [released], timeout: releaseTimeout)

        XCTAssertEqual(
            session.deactivations, [.notifyOthersOnDeactivation],
            """
            The session must be released with `.notifyOthersOnDeactivation` once the cue \
            has finished. Releasing without that option leaves the runner's music ducked; \
            not releasing at all is the 2026-07-30 failure.
            """)
    }

    /// The half of the fix that is easy to lose: a release that is skipped because some
    /// other handler cleared the "did I configure this" flag first.
    @MainActor
    func testHeadphoneRemovalDoesNotStrandTheSessionInADuckedState() async {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)
        let released = expectation(description: "session released")
        session.fulfillOnDeactivation(released)

        player.speak(.easeOff)
        // DEG-S-9, mid-cue. This clears the player's configured flag so the next cue
        // reconfigures for the new route — and a release guarded on that flag would now
        // silently do nothing, leaving the music down for the rest of the run.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ])
        player.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: ""))

        await fulfillment(of: [released], timeout: releaseTimeout)
        XCTAssertEqual(session.deactivations.count, 1)
    }

    /// The second route to the same failure, found by writing the test above.
    ///
    /// Releasing the session is driven by the synthesizer reporting an utterance finished.
    /// If that report never comes — and on a simulator it never does, because there is no
    /// audio route to speak into — nothing else would ever bring the music back. A device
    /// whose session failed to activate, or whose route vanished mid-cue, is the same
    /// situation with a runner attached to it.
    @MainActor
    func testACueThatNeverReportsBackStillGivesTheMusicBack() async {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session, maximumHoldSeconds: 0.3)
        let released = expectation(description: "session released")
        session.fulfillOnDeactivation(released)

        player.speak(.easeOff)
        // No `didFinish`, no `didCancel`, no `stop()`. Nothing at all.

        await fulfillment(of: [released], timeout: releaseTimeout)
        XCTAssertEqual(session.deactivations, [.notifyOthersOnDeactivation])
    }

    // MARK: - Not stuttering between cues

    /// A step transition and a split can land within a second of each other. Unducking
    /// between them would be an audible dip-and-recover in the middle of two sentences the
    /// runner hears as one.
    @MainActor
    func testCuesArrivingTogetherShareOneDuck() async throws {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "")

        player.speak(.easeOff)
        player.speechSynthesizer(synthesizer, didFinish: utterance)
        // Inside the quiet period, before the release would have fired.
        try await Task.sleep(for: .milliseconds(50))
        player.speak(.pickItUp)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            session.deactivations.isEmpty,
            "The second cue arrived before the release; the music must not come back up "
                + "only to be ducked again.")

        let released = expectation(description: "session released")
        session.fulfillOnDeactivation(released)
        player.speechSynthesizer(synthesizer, didFinish: utterance)
        await fulfillment(of: [released], timeout: releaseTimeout)

        XCTAssertEqual(
            session.deactivations.count, 1,
            "Two adjacent cues, one duck and one release.")
        XCTAssertEqual(
            session.activations, 1,
            "The second cue reuses the session it found already active.")
    }

    // MARK: - Category

    @MainActor
    func testTheCategoryIsAudibleOnSilentAndDucksRatherThanStopsMusic() {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)

        player.speak(.easeOff)

        let configuration = session.configurations.first
        XCTAssertNotNil(configuration, "A cue must configure the session before speaking.")
        XCTAssertEqual(
            configuration?.category, .playback,
            "AC-FR-S-D-1-4: `.ambient` would silence every cue for a runner whose ring "
                + "switch is set to silent, which is most of them.")
        XCTAssertEqual(
            configuration?.mode, .voicePrompt,
            "`.spokenAudio` declares this app to be the podcast and asks others to pause "
                + "for it; a pace cue is navigation-style speech over someone else's audio.")
        XCTAssertTrue(configuration?.options.contains(.duckOthers) ?? false)
        XCTAssertTrue(
            configuration?.options.contains(.mixWithOthers) ?? false,
            "Without it the runner's music stops instead of dipping.")
    }

    // MARK: - Teardown

    /// AC-FR-S-A-2-3 / NFR-S-6, and the last line of defence for the ducking bug: whatever
    /// else went wrong during a run, ending it must give the music back.
    @MainActor
    func testEndingARunReleasesTheSessionWithoutWaiting() {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)

        player.speak(.easeOff)
        player.stop()

        XCTAssertEqual(session.deactivations, [.notifyOthersOnDeactivation])
    }

    /// A phone call takes the session away; the app must not then hand it back on the
    /// caller's behalf.
    @MainActor
    func testAnInterruptionDoesNotReleaseTheSessionUnderTheCall() async throws {
        let session = FakeAudioSession()
        let player = SpeechCuePlayer(session: session)

        player.speak(.easeOff)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ])

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            session.deactivations.isEmpty,
            "The system already deactivated the session when the call began. Deactivating "
                + "again mid-call is this app reaching into someone else's audio.")
    }
}

// MARK: - Fakes

private extension SpokenCue {
    static let easeOff = SpokenCue(
        kind: .pace(.easeOff, secondsOff: 12),
        phrase: StandaloneStrings.paceCue(direction: .easeOff, secondsOff: 12))
    static let pickItUp = SpokenCue(
        kind: .pace(.pickItUp, secondsOff: 9),
        phrase: StandaloneStrings.paceCue(direction: .pickItUp, secondsOff: 9))
}

/// Records what the player asked of the audio session.
///
/// `@unchecked Sendable` behind a lock, the same shape as `SpyWorkoutWriter`:
/// `AudioSessionControlling` is not actor-isolated because `AVAudioSession` is not, so a
/// `@MainActor` fake could not conform to it.
private final class FakeAudioSession: AudioSessionControlling, @unchecked Sendable {

    struct Configuration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    enum Event: Equatable {
        case configured(Configuration)
        case activated
        case deactivated(AVAudioSession.SetActiveOptions)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var deactivationExpectation: XCTestExpectation?

    var events: [Event] { lock.withLock { recorded } }

    var configurations: [Configuration] {
        events.compactMap { event in
            if case let .configured(configuration) = event { return configuration }
            return nil
        }
    }

    var activations: Int {
        events.filter { $0 == .activated }.count
    }

    var deactivations: [AVAudioSession.SetActiveOptions] {
        events.compactMap { event in
            if case let .deactivated(options) = event { return options }
            return nil
        }
    }

    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        append(.configured(Configuration(category: category, mode: mode, options: options)))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        append(active ? .activated : .deactivated(options))
    }

    /// Fulfils `expectation` when the session is released — now if it already has been.
    ///
    /// The expectation is created by the test and handed in, rather than this type taking
    /// the `XCTestCase`. An `XCTestCase` is not `Sendable`, and this fake has to be, so
    /// passing one across would be a data race the compiler is right to reject.
    func fulfillOnDeactivation(_ expectation: XCTestExpectation) {
        let alreadyReleased: Bool = lock.withLock {
            let released = recorded.contains { event in
                if case .deactivated = event { return true }
                return false
            }
            if !released { deactivationExpectation = expectation }
            return released
        }
        if alreadyReleased { expectation.fulfill() }
    }

    private func append(_ event: Event) {
        let expectation: XCTestExpectation? = lock.withLock {
            recorded.append(event)
            guard case .deactivated = event else { return nil }
            defer { deactivationExpectation = nil }
            return deactivationExpectation
        }
        expectation?.fulfill()
    }
}
