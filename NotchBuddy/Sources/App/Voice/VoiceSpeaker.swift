#if !APPSTORE
import AVFoundation

// MARK: - VoiceSpeaker
//
// Gives Coucou a voice, sentence by sentence:
//   • macOS voices (AVSpeechSynthesizer), the voice chosen in Settings or the best installed
//     one for the language. Text is cut at sentences and long commas (VoiceSpeech.chunks) and
//     the queue waits a moment between pieces, cancelled like the rest by stop()/speak();
//   • the natural local voice (LocalVoice), made on this Mac: pieces are queued like the Mac
//     voice's and each starts being made right away, so the next one is usually ready;
//   • ElevenLabs (Settings → Voice, the user's own API key), female or male.
//     Each queued sentence starts downloading right away, so the next one is usually
//     ready when the previous one ends. Any ElevenLabs failure falls back to the Mac
//     voice for that sentence: Coucou never goes silent.
// onDidFinish fires ~150 ms after the queue drains. All methods: @MainActor.
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = VoiceSpeaker()

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private(set) var isSpeaking = false
    private var currentUtterance: AVSpeechUtterance? = nil
    private var waitingForAudio = false
    private var pauseAfterCurrent: TimeInterval = 0

    private struct Item {
        let text: String
        let locale: Locale?
        let audio: Task<Data?, Never>?   // ElevenLabs or local voice, started at enqueue time
        var pause: TimeInterval = 0      // silence after it, if more follows
    }
    private var queue: [Item] = []
    /// Bumped by stop()/speak(): late callbacks from an older utterance are ignored.
    private var generation = 0

    /// Called ~150 ms after the last queued sentence finishes.
    var onDidFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// Clears the queue, stops current speech, and speaks text now.
    func speak(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        stopPlayback()
        enqueue(text, locale: locale)
    }

    /// Adds a sentence to the queue. Starts playing if nothing is playing.
    func enqueue(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        if ElevenLabsTTS.isActive {
            // ElevenLabs phrases a whole sentence itself.
            queue.append(Item(text: text, locale: locale, audio: Task { await ElevenLabsTTS.shared.audio(for: text) }))
        } else {
            let local = LocalVoice.shared.voice(for: locale)
            queue += VoiceSpeech.chunks(text).map { chunk in
                let audio = local.map { voice in Task { await LocalVoice.shared.audio(for: chunk.text, voice: voice) } }
                return Item(text: chunk.text, locale: locale, audio: audio, pause: chunk.pause)
            }
        }
        if !isSpeaking { playNext() }
    }

    func stop() { stopPlayback() }

    /// What the mic gate uses: what is actually playing or about to play, never a flag
    /// alone, so a missed callback cannot leave Coucou deaf.
    var isBusy: Bool {
        synth.isSpeaking || (player?.isPlaying ?? false) || waitingForAudio || !queue.isEmpty
    }

    // MARK: - Playback

    private func stopPlayback() {
        generation += 1
        for item in queue { item.audio?.cancel() }
        queue.removeAll()
        currentUtterance = nil
        waitingForAudio = false
        pauseAfterCurrent = 0
        isSpeaking = false
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func playNext() {
        guard !queue.isEmpty else { finished(); return }
        let item = queue.removeFirst()
        isSpeaking = true
        pauseAfterCurrent = item.pause
        guard let audio = item.audio else { speakSystem(item.text, locale: item.locale); return }
        let gen = generation
        waitingForAudio = true
        Task { @MainActor in
            let data = await audio.value
            guard gen == self.generation else { return }
            self.waitingForAudio = false
            if let data, let p = try? AVAudioPlayer(data: data) {
                p.delegate = self
                self.player = p
                if p.play() { return }
                self.player = nil
            }
            self.speakSystem(item.text, locale: item.locale)   // fallback: Mac voice
        }
    }

    private func speakSystem(_ text: String, locale: Locale?) {
        let utt = AVSpeechUtterance(string: text)
        let gender = VoiceSettings.elevenGender
        // Pitch per voice type (Settings → Voice): the male voice a bit higher sounds younger.
        utt.pitchMultiplier = Float(VoiceSettings.pitch(for: gender))
        utt.rate = VoiceSpeech.utteranceRate(multiplier: VoiceSettings.speechRate, base: AVSpeechUtteranceDefaultSpeechRate)
        utt.voice = Self.bestVoice(for: locale, gender: gender)
        currentUtterance = utt
        synth.speak(utt)
    }

    private func itemDone() {
        currentUtterance = nil
        player = nil
        let pause = pauseAfterCurrent
        pauseAfterCurrent = 0
        guard pause > 0, !queue.isEmpty else { playNext(); return }
        // isSpeaking stays on and the queue is not empty: isBusy holds the mic gate meanwhile.
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(pause))
            guard gen == self.generation else { return }
            self.playNext()
        }
    }

    private func finished() {
        isSpeaking = false
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms gap
            guard gen == self.generation, !self.isSpeaking else { return }
            self.onDidFinish?()
        }
    }

    /// Best installed Mac voice for the language and the chosen gender (Settings → Voice):
    /// quality first (.premium > .enhanced > default — Ava Premium beats a compact US voice),
    /// then same region. Novelty voices and the user's Personal Voice are never used.
    /// Falls back to any gender when none of the chosen one is installed.
    /// Premium and Siri voices often report no gender: their name tells it instead.
    static func bestVoice(for locale: Locale?, gender: String) -> AVSpeechSynthesisVoice? {
        guard let loc = locale else { return nil }
        if let chosen = chosenVoice(for: loc) { return chosen }
        // Listing the system voices (150+) for every sentence cost milliseconds between
        // sentences: one lookup per language and voice type, redone when voices change.
        let key = "\(loc.identifier)|\(gender)"
        if let hit = voiceCache[key] { return hit }
        observeVoiceChanges()
        let v = findBestVoice(for: loc, gender: gender)
        voiceCache[key] = .some(v)
        return v
    }

    /// The voice picked in Settings, if it is still installed and speaks this language.
    private static func chosenVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        guard !VoiceSettings.macVoice.isEmpty,
              let v = AVSpeechSynthesisVoice(identifier: VoiceSettings.macVoice),
              VoiceSpeech.voice(language: v.language, speaks: locale.identifier) else { return nil }
        return v
    }

    /// Settings → Voice → Mac voice. Novelty voices and Personal Voice stay out, as in findBestVoice.
    static func macVoices() -> [VoiceSpeech.Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .map { VoiceSpeech.Voice(id: $0.identifier, name: $0.name, language: $0.language, quality: quality(of: $0)) }
    }

    private static func quality(of v: AVSpeechSynthesisVoice) -> VoiceSpeech.Quality {
        switch v.quality {
        case .premium:  return .premium
        case .enhanced: return .enhanced
        default:        return .standard
        }
    }

    private static var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
    private static var observingVoices = false

    private static func observeVoiceChanges() {
        guard !observingVoices else { return }
        observingVoices = true
        NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { VoiceSpeaker.voiceCache.removeAll() }
        }
    }

    private static func findBestVoice(for loc: Locale, gender: String) -> AVSpeechSynthesisVoice? {
        let lang = loc.language.languageCode?.identifier ?? ""
        guard !lang.isEmpty else { return nil }
        let exact = loc.region.map { "\(lang)-\($0.identifier)" }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            (v.language == lang || v.language.hasPrefix(lang + "-"))
                && !v.voiceTraits.contains(.isNoveltyVoice)
                && !v.voiceTraits.contains(.isPersonalVoice)
        }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: exact ?? lang) }
        let wanted: AVSpeechSynthesisVoiceGender = gender == "male" ? .male : .female
        let ofGender = voices.filter { Self.gender(of: $0) == wanted }
        let pool = ofGender.isEmpty ? voices : ofGender

        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int) {
            (v.quality.rawValue, v.language == exact ? 1 : 0)
        }
        return pool.max { rank($0) < rank($1) }
    }

    /// The voice's gender, from the system when it says, else from its identifier
    /// ("siri_female_…") or its first name (Ava, Zoe… / Jamie, Evan…).
    static func gender(of v: AVSpeechSynthesisVoice) -> AVSpeechSynthesisVoiceGender {
        if v.gender != .unspecified { return v.gender }
        switch VoiceGenderNames.gender(name: v.name, identifier: v.identifier) {
        case "female": return .female
        case "male":   return .male
        default:       return .unspecified
        }
    }

    /// "Ava (Premium)" — shown in Settings so it is clear which voice Coucou uses.
    static func macVoiceName(for locale: Locale, gender: String) -> String {
        guard let v = bestVoice(for: locale, gender: gender) else { return "—" }
        let voice = VoiceSpeech.Voice(id: v.identifier, name: v.name, language: v.language, quality: quality(of: v))
        return voice.quality == .standard ? voice.plainName : "\(voice.plainName) (\(voice.quality.label))"
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        // stopPlayback() already reset everything; nothing to do for older utterances.
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let curr = self.player, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let curr = self.player, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }
}
#endif
