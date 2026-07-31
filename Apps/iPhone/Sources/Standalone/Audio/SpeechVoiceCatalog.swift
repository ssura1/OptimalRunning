import AVFoundation
import Foundation

/// One system voice, in the terms the settings screen needs (S-066, FR-S-G-1).
///
/// A value rather than the `AVSpeechSynthesisVoice` itself so the picker can hold, compare
/// and diff them without holding engine objects, and so `id` is exactly what the profile
/// stores.
struct SpeechVoiceOption: Identifiable, Hashable {
    /// `AVSpeechSynthesisVoice.identifier` — the string persisted in `RunnerProfile`.
    let id: String
    let name: String
    let languageCode: String
    let quality: AVSpeechSynthesisVoiceQuality

    /// "Enhanced" / "Premium", or `nil` for the compact voice that ships with the OS.
    ///
    /// Named rather than ranked because the runner's question is "is this the good one",
    /// and the answer is a word Apple already uses in Settings.
    var qualityLabel: String? {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return nil
        }
    }
}

/// The voices installed on this device, and which one to use (S-066).
///
/// **There is no such thing as importing a voice into `AVSpeechSynthesizer`.** Third-party
/// speech assets cannot be loaded, and Siri's voices are not vended to apps. What *is*
/// available is Apple's own Enhanced and Premium downloads, which are not installed by
/// default — which is why the app shipped sounding robotic: with nothing else present,
/// `AVSpeechSynthesisVoice(language:)` returns the compact voice, and the compact voice is
/// the robotic one.
///
/// So this type does the two things that are actually possible: pick the best voice that
/// *is* installed, and let the runner choose among them.
enum SpeechVoiceCatalog {

    /// Voices worth offering, best first.
    ///
    /// Two exclusions, both deliberate:
    ///
    /// - **Novelty voices** (Bells, Bubbles, Trinoids). They are jokes, and a joke voice
    ///   reading "ease off, twelve seconds fast" is not a pace cue.
    /// - **Personal Voice.** Using one requires
    ///   `AVSpeechSynthesizer.requestPersonalVoiceAuthorization`, which this app does not
    ///   ask for. Offering a voice that would silently fail is worse than not offering it.
    static func installed(
        matching languageCode: String = AVSpeechSynthesisVoice.currentLanguageCode()
    ) -> [SpeechVoiceOption] {
        let family = language(of: languageCode)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard language(of: voice.language) == family else { return false }
                if voice.voiceTraits.contains(.isNoveltyVoice) { return false }
                if voice.voiceTraits.contains(.isPersonalVoice) { return false }
                return true
            }
            .map {
                SpeechVoiceOption(
                    id: $0.identifier, name: $0.name, languageCode: $0.language,
                    quality: $0.quality)
            }
            .sorted { ranks($0, above: $1, exactLanguage: languageCode) }
    }

    /// The voice to speak with, given what the runner chose.
    ///
    /// A stored identifier that no longer resolves falls back to the best available rather
    /// than to silence. That is not a hypothetical: a runner can delete a downloaded voice
    /// in Settings long after choosing it here, and the failure would otherwise be a run
    /// with no cues and no explanation.
    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return best()
    }

    /// The best installed voice for the current language, or `nil` to let AVFoundation
    /// choose — which is only reached when the filters exclude everything.
    static func best() -> AVSpeechSynthesisVoice? {
        guard let identifier = installed().first?.id else { return nil }
        return AVSpeechSynthesisVoice(identifier: identifier)
    }

    /// Whether a better voice than the current best could be downloaded.
    ///
    /// Drives the one sentence in settings that tells the runner where to go. Offering
    /// "download a better voice" to someone who already has Premium installed would be
    /// noise; withholding it from someone stuck on the compact voice is the whole problem.
    static func hasUpgradeAvailable(
        _ options: [SpeechVoiceOption] = installed()
    ) -> Bool {
        !options.contains { $0.quality == .enhanced || $0.quality == .premium }
    }

    // MARK: - Private

    private static func ranks(
        _ lhs: SpeechVoiceOption, above rhs: SpeechVoiceOption, exactLanguage: String
    ) -> Bool {
        if lhs.quality.rawValue != rhs.quality.rawValue {
            return lhs.quality.rawValue > rhs.quality.rawValue
        }
        // Among equals, the runner's own region first: an en-GB voice reading American
        // street names is a worse default for a US runner than en-US, and vice versa.
        let lhsExact = lhs.languageCode == exactLanguage
        let rhsExact = rhs.languageCode == exactLanguage
        if lhsExact != rhsExact { return lhsExact }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// "en-GB" -> "en". Compared case-insensitively because the region separator and casing
    /// of these strings is not something this app controls.
    private static func language(of code: String) -> String {
        code.split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased()
    }
}
