#if !APPSTORE
import Foundation

/// One English practice: its own conversation with Claude, no tools, in memory only.
@MainActor
final class EnglishPracticeSession {
    static let shared = EnglishPracticeSession()

    private static let maxMessages = 20
    private var messages: [[String: Any]] = []

    func begin() {
        messages = [["role": "user", "content": "Let's practice English."],
                    ["role": "assistant", "content": EnglishPractice.opening]]
        EnglishPractice.set(true)
    }

    func end() {
        messages = []
        EnglishPractice.set(false)
    }

    /// nil on any failure: no key, network, quota.
    func respond(to transcript: String) async -> String? {
        messages.append(["role": "user", "content": transcript])
        // By pairs: the history has to keep starting with the user.
        while messages.count > Self.maxMessages { messages.removeFirst(2) }
        let system = EnglishPractice.systemPrompt(level: EnglishPractice.level)
        guard let turn = await ClaudeService.shared.voiceTurn(system: system, messages: messages, tools: []),
              let text = claudeResponseText(fromContent: turn.content) else {
            messages.removeLast()
            return nil
        }
        // The session may have ended during the wait.
        guard EnglishPractice.isActive else { return nil }
        messages.append(["role": "assistant", "content": text])
        return VoiceQuery.spokenText(text)
    }
}
#endif
