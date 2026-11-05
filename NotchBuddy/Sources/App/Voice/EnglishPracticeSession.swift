#if !APPSTORE
import Foundation

/// One English practice: its own conversation with Claude, no tools, in memory only.
@MainActor
final class EnglishPracticeSession {
    static let shared = EnglishPracticeSession()

    private var history = EnglishPractice.History()

    func begin() {
        history.begin()
        EnglishPractice.set(true)
    }

    func end() {
        history.clear()
        EnglishPractice.set(false)
    }

    /// nil on any failure: no key, network, quota.
    func respond(to transcript: String) async -> String? {
        history.add(turn: transcript)
        let system = EnglishPractice.systemPrompt(level: EnglishPractice.level)
        guard let turn = await ClaudeService.shared.voiceTurn(system: system, messages: history.messages, tools: []),
              let text = claudeResponseText(fromContent: turn.content) else {
            history.takeBack(turn: transcript)
            return nil
        }
        // The session may have ended during the wait.
        guard EnglishPractice.isActive else { return nil }
        history.add(answer: text)
        return VoiceQuery.spokenText(text)
    }
}
#endif
