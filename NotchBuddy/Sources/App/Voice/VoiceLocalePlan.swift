import Foundation

// MARK: - VoiceLocalePlan
//
// Who hears what, from Settings → Voice → "You speak". The recognizer stays on the Mac, so a
// language only counts if its model is installed. Parakeet only works on finished audio: it
// can write the command but never hear the wake word, which always needs a recognizer.
// No Speech/AVFoundation dependency — testable with standalone swiftc.

struct VoiceLocalePlan: Equatable, Sendable {
    /// The locale the recognizer really uses, as macOS reports it ("es" comes back as "es-419").
    let locale: String
    /// Set when `locale` is not the language spoken: it only hears the wake word, Parakeet
    /// writes the command. Holds the locale that was wanted.
    var wakeOnlyFor: String? = nil
    /// Parakeet writes the command, the recognizer only follows the sentence.
    var parakeetCommand = false

    /// The locales for a "You speak" value, best first. Never the Mac's language: on a Mac
    /// set to English it would answer "es" with English.
    static func candidates(for listenLanguage: String) -> [String] {
        let spanish = ["es-MX", "es-ES", "es", "es-US"]
        let english = ["en-US", "en-GB", "en-AU", "en-CA", "en"]
        switch listenLanguage {
        case "fr":   return ["fr-FR", "fr-CA"]
        case "en":   return english
        case "auto": return spanish + english
        default:     return spanish
        }
    }

    /// `onDevice` gives the locale macOS would really use, nil when that model is not on this Mac.
    /// nil result: nothing can listen in this language.
    static func resolve(listenLanguage: String, parakeet: Bool,
                        onDevice: (String) -> String?) -> VoiceLocalePlan? {
        let wanted = candidates(for: listenLanguage)
        if let locale = wanted.lazy.compactMap(onDevice).first {
            return VoiceLocalePlan(locale: locale, parakeetCommand: parakeet)
        }
        // Without Parakeet the command would come out in another language: better not to listen.
        guard parakeet, let locale = candidates(for: "auto").lazy.compactMap(onDevice).first else { return nil }
        return VoiceLocalePlan(locale: locale, wakeOnlyFor: wanted.first, parakeetCommand: true)
    }

    /// The end of the "Escuchando" line.
    var statusText: String {
        let hearing = wakeOnlyFor.map { "wake \(locale) (sin modelo \($0))" } ?? locale
        return parakeetCommand ? "\(hearing) · comando con Parakeet" : hearing
    }
}

// MARK: - VoiceCommandText

enum VoiceCommandText {
    /// How many words of the recognizer's transcript the wake phrase took, what came before it
    /// included: where to look for it in Parakeet's words.
    static func wakeWordCount(in transcript: String, coucou: Bool) -> Int {
        let split = WakePhrase.split(transcript, coucou: coucou)
        guard split.matched else { return 0 }
        return words(transcript).count - words(split.command).count
    }

    /// What Parakeet wrote, without the wake phrase: it heard the same audio as the recognizer.
    /// The recognizer's words when Parakeet has nothing better. `wakeWords` is 0 when the turn
    /// had no wake phrase (a follow-up answer).
    static func pick(parakeet: String?, recognizer: String, wakeWords: Int = 0, coucou: Bool) -> String {
        let heard = (parakeet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let split = WakePhrase.split(heard, coucou: coucou)
        let command = split.matched ? split.command : withoutMisheardWake(heard, wakeWords: wakeWords)
        return command.isEmpty ? recognizer : command
    }

    /// Parakeet has no «Jarvis» in its vocabulary and writes things like "O Harvis, abre…".
    /// Only near the start, where the recognizer heard the wake phrase: one word of slack.
    private static func withoutMisheardWake(_ heard: String, wakeWords: Int) -> String {
        let all = words(heard)
        guard let last = all.prefix(wakeWords + 1).lastIndex(where: soundsLikeJarvis), wakeWords > 0 else { return heard }
        return all[(last + 1)...].joined(separator: " ")
    }

    private static func soundsLikeJarvis(_ word: String) -> Bool {
        distance(Array(WakePhrase.normalise(word)), Array("jarvis")) <= 2
    }

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// Levenshtein.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let next = min(row[j + 1] + 1, row[j] + 1, previous + (x == y ? 0 : 1))
                previous = row[j + 1]
                row[j + 1] = next
            }
        }
        return row[b.count]
    }
}
