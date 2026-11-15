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

    // ------------------------------------------------------------------ voice choice

    /// Preferred kind of voice; female by default. Device-only setting (UserDefaults).
    enum VoiceGender: String, CaseIterable, Identifiable {
        case female, male
        var id: String { rawValue }
        var label: String { self == .female ? "Weiblich" : "Männlich" }
    }

    nonisolated static let genderKey = "voice_gender"
    /// Key of the explicitly chosen voice for a language, e.g. "voice_id_en-GB".
    nonisolated static func voiceKey(_ tag: String) -> String { "voice_id_\(tag)" }

    var gender: VoiceGender {
        VoiceGender(rawValue: UserDefaults.standard.string(forKey: Self.genderKey) ?? "") ?? .female
    }

    /// Installed voices for a tag such as "en-GB", best first: same region before other regions of the language,
    /// premium/enhanced before compact, Apple's regular voices before the robotic Eloquence ones. Novelty and
    /// personal voices are left out.
    func voices(for tag: String) -> [AVSpeechSynthesisVoice] {
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        let all = AVSpeechSynthesisVoice.speechVoices().filter { v in
            (v.language == base || v.language.hasPrefix(base + "-"))
                && !v.voiceTraits.contains(.isNoveltyVoice) && !v.voiceTraits.contains(.isPersonalVoice)
        }
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
            let region = v.language.caseInsensitiveCompare(tag) == .orderedSame ? 1 : 0
            let regular = v.identifier.contains("eloquence") ? 0 : 1
            return (region, v.quality.rawValue, regular)
        }
        return all.sorted { a, b in
            let ra = rank(a)
            let rb = rank(b)
            if ra != rb { return ra > rb }
            return a.name < b.name
        }
    }

    /// The voice used for a language: the one chosen in the settings, otherwise the best one of the preferred
    /// gender, otherwise the best one at all.
    func voice(for tag: String) -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Self.voiceKey(tag)),
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        let list = voices(for: tag)
        let wanted: AVSpeechSynthesisVoiceGender = gender == .female ? .female : .male
        return list.first { $0.gender == wanted } ?? list.first
    }

    /// Plays `text` with a specific voice (or the automatic choice when nil), for trying voices in the settings.
    func preview(_ text: String, voice: AVSpeechSynthesisVoice?, tag: String) {
        guard let v = voice ?? self.voice(for: tag) else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = v
        utterance.rate = 0.47
        synthesizer.speak(utterance)
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
