import Foundation
import NaturalLanguage

// MARK: - VoiceSpeech
//
// How Coucou says things: its speed, where it breathes, in which language, which voices are on
// offer. No AVFoundation dependency — testable with standalone swiftc.

enum VoiceSpeech {

    // MARK: Speed

    /// Settings → Voice: a multiplier of the system's default speech rate.
    static let rateRange = 0.6...1.2
    static let defaultRate = 0.85

    /// 0 is what UserDefaults gives for a value never saved.
    static func rate(stored: Double) -> Double {
        stored == 0 ? defaultRate : min(rateRange.upperBound, max(rateRange.lowerBound, stored))
    }

    static func utteranceRate(multiplier: Double, base: Float) -> Float {
        base * Float(rate(stored: multiplier))
    }

    // MARK: Pauses

    struct Chunk: Equatable {
        let text: String
        /// Silence after it, if more speech follows.
        let pause: TimeInterval
    }

    static let commaPause: TimeInterval = 0.12
    static let sentencePause: TimeInterval = 0.28
    /// A comma only gets a pause between word groups at least this long: «Sí, claro» stays whole.
    private static let minWordsAroundComma = 3

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", ";", ":", "\n"]
    private static let closers: Set<Character> = [".", "!", "?", "…", "\"", "'", ")", "]", "»", "”", "’"]
    private static let abbreviations: Set<String> = ["sr.", "sra.", "srta.", "dr.", "dra.", "ud.", "uds.", "mr.", "mrs.", "ms.", "vs."]

    /// The text cut at its sentences and long commas. Punctuation only counts before a space:
    /// «1,500», «3.5» and «10:30» stay whole. Never empty: blank text comes back as it is.
    static func chunks(_ text: String) -> [Chunk] {
        let chars = Array(text)
        var out: [Chunk] = []
        var current = ""
        var i = 0

        func add(pause: TimeInterval) {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            if !piece.isEmpty { out.append(Chunk(text: piece, pause: pause)) }
        }

        while i < chars.count {
            let c = chars[i]
            current.append(c)
            i += 1
            guard c == "," || sentenceEnds.contains(c) else { continue }
            while i < chars.count, closers.contains(chars[i]) {
                current.append(chars[i])
                i += 1
            }
            guard i == chars.count || chars[i].isWhitespace || c == "\n" else { continue }
            if c == "," {
                if wordCount(current) >= minWordsAroundComma,
                   wordCount(String(chars[i...])) >= minWordsAroundComma { add(pause: commaPause) }
            } else if !endsWithAbbreviation(current) {
                add(pause: sentencePause)
            }
        }
        add(pause: 0)
        return out.isEmpty ? [Chunk(text: text, pause: 0)] : out
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).last.map { abbreviations.contains($0.lowercased()) } ?? false
    }

    // MARK: Mac voices

    enum Quality: Int, Comparable {
        case standard, enhanced, premium
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .standard: return "Estándar"
            case .enhanced: return "Enhanced"
            case .premium:  return "Premium"
            }
        }
    }

    struct Voice: Equatable, Identifiable {
        let id: String
        let name: String
        let language: String
        let quality: Quality

        /// macOS sometimes puts the quality in the name: "Paulina (Enhanced)".
        var plainName: String {
            name.replacingOccurrences(of: " (Enhanced)", with: "").replacingOccurrences(of: " (Premium)", with: "")
        }

        /// "Paulina · es-MX · Enhanced".
        var label: String { "\(plainName) · \(language) · \(quality.label)" }
    }

    /// The voices of a language, best first: Enhanced and Premium, then the rest, each with
    /// Mexico and Spain ahead among the Spanish ones.
    static func offered(_ voices: [Voice], language: String) -> [Voice] {
        voices
            .filter { code(of: $0.language) == code(of: language) }
            .sorted { a, b in
                let ka = (a.quality > .standard ? 0 : 1, languageRank(a.language), -a.quality.rawValue)
                let kb = (b.quality > .standard ? 0 : 1, languageRank(b.language), -b.quality.rawValue)
                if ka != kb { return ka < kb }
                return (a.plainName, a.id) < (b.plainName, b.id)
            }
    }

    private static func languageRank(_ language: String) -> Int {
        switch language {
        case "es-MX": return 0
        case "es-ES": return 1
        default:      return code(of: language) == "es" ? 2 : 3
        }
    }

    /// False leads to the "download voices" notice.
    static func hasGoodVoice(_ voices: [Voice]) -> Bool {
        voices.contains { $0.quality > .standard }
    }

    /// A chosen voice only speaks its own language: Paulina can't read an answer in French.
    static func voice(language: String, speaks wanted: String) -> Bool {
        code(of: language) == code(of: wanted)
    }

    // MARK: Language of an answer

    private static let minWordsToDetect = 3
    private static let minConfidence = 0.8

    /// The language an answer is really in, so each language gets its own voice: Spanish or
    /// English, as a locale. Too short or unclear keeps `fallback`, and so does any other
    /// language: there is no second voice to pick there.
    static func language(of text: String, fallback: String) -> String {
        guard ["es", "en"].contains(code(of: fallback)), wordCount(text) >= minWordsToDetect else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(text)
        guard let (detected, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minConfidence, detected.rawValue != code(of: fallback) else { return fallback }
        return detected == .spanish ? "es-MX" : "en-US"
    }

    // MARK: Local voices

    /// Kokoro's voices. Its Spanish ones need its Spanish frontend, the English ones its
    /// English frontend: `language` says which.
    struct LocalVoice: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let language: String
        let male: Bool
    }

    static let localVoices: [LocalVoice] = [
        .init(id: "ef_dora", name: "Dora", language: "es", male: false),
        .init(id: "em_alex", name: "Alex", language: "es", male: true),
        .init(id: "af_heart", name: "Heart", language: "en", male: false),
        .init(id: "am_michael", name: "Michael", language: "en", male: true),
    ]

    /// The voice picked for this language, else the one of the chosen gender. nil for a language
    /// Kokoro doesn't speak here: the Mac voice says it.
    static func localVoice(language: String, chosen: String, gender: String) -> LocalVoice? {
        let voices = localVoices.filter { $0.language == code(of: language) }
        return voices.first { $0.id == chosen } ?? voices.first { $0.male == (gender == "male") }
    }

    /// Kokoro's Spanish is Spain's: «cinco» comes with θ. Latin America says s.
    static func seseo(_ phonemes: String) -> String {
        phonemes.replacingOccurrences(of: "θ", with: "s")
    }

    private static func code(of language: String) -> String {
        language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
    }
}
