import AVFoundation
import ParlaCore
import UIKit

/// Text-to-speech with the iPhone's own voices and the short feedback sounds (same surface as the Audio class
/// of the Kotlin apps).
@MainActor
final class Audio {
    private let synthesizer = AVSpeechSynthesizer()
    private var language = "en-GB"
    private var players: [String: AVAudioPlayer] = [:]

    /// Called once per language when something should be spoken but no voice is installed for it.
    var onMissingVoice: (() -> Void)?
    private var noticeShown = Set<String>()

    // Speaker button: pressing it again for the same text reads it much slower, then alternates.
    private var lastButtonText: String?
    private var lastButtonSlow = false

    init() {
        // Playback: speech and sounds are heard even with the ring/silent switch on (a speaker button that
        // stays silent looks broken); other audio keeps playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? session.setActive(true)
        let sounds: [(String, Data)] = [
            ("tap", FeedbackSounds.tap),
            ("correct", FeedbackSounds.correct),
            ("wrong", FeedbackSounds.wrong),
            ("pair", FeedbackSounds.pair),
            ("complete", FeedbackSounds.lessonComplete),
        ]
        for (name, data) in sounds {
            if let player = try? AVAudioPlayer(data: data) {
                player.prepareToPlay()
                players[name] = player
            }
        }
    }

    /// True if a voice for the current language is installed.
    var available: Bool { voice(for: language) != nil }

    func setLanguage(_ tag: String) { language = tag }

    /// Best installed voice for a tag such as "en-GB": same region first, then any region of the language;
    /// enhanced/premium voices are preferred over the compact default ones.
    private func voice(for tag: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        var candidates = voices.filter { $0.language.caseInsensitiveCompare(tag) == .orderedSame }
        if candidates.isEmpty {
            candidates = voices.filter { $0.language == base || $0.language.hasPrefix(base + "-") }
        }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    func speak(_ text: String, slow: Bool = false) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        guard let voice = voice(for: language) else {
            if noticeShown.insert(language).inserted { onMissingVoice?() }
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice
        // Default rate is 0.5; "slow" is clearly slower, for listening closely.
        utterance.rate = slow ? 0.3 : 0.47
        synthesizer.speak(utterance)
    }

    /// For the speaker buttons: normal speed, and noticeably slower when pressed again for the same text.
    func speakButton(_ text: String) {
        let slow = text == lastButtonText && !lastButtonSlow
        lastButtonText = text
        lastButtonSlow = slow
        speak(text, slow: slow)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func feedback(correct: Bool, enabled: Bool) {
        if enabled { play(correct ? "correct" : "wrong") }
    }

    /// Soft pop when a word chip or an answer option is picked.
    func tap(enabled: Bool) {
        if enabled { play("tap") }
    }

    /// Small chime when a matching pair was found.
    func pairFound(enabled: Bool) {
        if enabled { play("pair") }
    }

    /// Rising chime when a lesson is finished.
    func lessonComplete(enabled: Bool) {
        if enabled { play("complete") }
    }

    private func play(_ name: String) {
        guard let player = players[name] else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }
}

enum Haptics {
    @MainActor
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
