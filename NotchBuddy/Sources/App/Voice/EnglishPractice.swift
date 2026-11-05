import Foundation
import os

// MARK: - EnglishPractice
//
// «OK Jarvis, practiquemos inglés»: Claude talks in English, level from Settings → Voice, and
// ends each turn with a short correction. What starts it, what ends it and what Claude is told.
// No Claude or AppKit dependency — testable with standalone swiftc.

enum EnglishPractice {
    enum Command: Equatable { case start, stop, none }

    enum Level: String, CaseIterable, Identifiable {
        case basic, intermediate
        var id: String { rawValue }

        var label: String {
            switch self {
            case .basic:        return "Básico"
            case .intermediate: return "Intermedio"
            }
        }
    }

    private static let flag = OSAllocatedUnfairLock(initialState: false)
    static var isActive: Bool { flag.withLock { $0 } }
    static func set(_ on: Bool) { flag.withLock { $0 = on } }

    static let levelKey = "voicePracticeLevel"
    static var level: Level {
        Level(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .basic
    }

    private static let startPhrases = ["practiquemos ingles", "practicar ingles", "practica de ingles",
                                       "practice english", "practice my english"]
    private static let stopPhrases  = ["volvamos al espanol", "volver al espanol", "regresemos al espanol"]

    /// `active`: already practicing, so only leaving means something. «ya» has to be the whole
    /// turn: inside a sentence it is just a word.
    static func command(for transcript: String, active: Bool) -> Command {
        let text = plain(transcript)
        if active {
            return text == "ya" || stopPhrases.contains(where: text.contains) ? .stop : .none
        }
        return startPhrases.contains(where: text.contains) ? .start : .none
    }

    private static func plain(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .symbols).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Opens every session: it costs no call, and it can't fail.
    static let opening = "Great, let's practice English. What did you do today?"
    static let closing = "Listo, volvemos al español."
    static let needsKey = "Para practicar inglés necesito tu API key de Anthropic en Ajustes."
    static let needsParakeet = "Para oírte en inglés necesito Parakeet: elígelo en Ajustes, Voz."
    static let unreachable = "I can't reach Claude right now, so let's stop here."

    static func systemPrompt(level: Level) -> String {
        let pitch: String
        switch level {
        case .basic:
            pitch = "The learner is a beginner (A2). Use short sentences, the most common words and simple tenses."
        case .intermediate:
            pitch = "The learner is intermediate (B1 to B2). Speak naturally, with everyday idioms, but stay clear."
        }
        return """
        You are a friendly English conversation partner for a Spanish speaker practicing out loud. \
        \(pitch)

        Every turn has two parts, in this order:
        1. Answer in one to three sentences and ask one question, so the conversation goes on.
        2. A last line that starts with "Correction:". In simple English, fix the most useful \
        grammar or vocabulary mistake from their last turn: what they said and what to say instead. \
        If there is nothing to fix, write "Correction: nothing to fix, well done."

        Always write in English, even if they speak Spanish; then help them say it in English. \
        Their words come from speech recognition: never comment on pronunciation, spelling or \
        punctuation, and if a word looks wrong, guess what they meant. \
        Your text is read aloud: no lists, no markdown, no emoji. \
        You can only talk: you can't open apps, send anything or look anything up.
        """
    }
}
