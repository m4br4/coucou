import Foundation

// MARK: - SpotterGeneration
//
// Thread-safe generation counter for WakeSpotter task validation.
// No AppKit/AVFoundation dependency — testable with standalone swiftc.
//
// Usage inside WakeSpotter (all mutations under NSLock):
//   • beginWindow: taskGen = gen.bump()   — capture generation at task creation
//   • endWindow:   gen.bump()             — invalidate pending callbacks
//   • handleResult: guard gen.isValid(capturedGen) else { ignore stale callback }

struct SpotterGeneration {
    private(set) var current: Int = 0

    /// Increment the generation (call on beginWindow and endWindow).
    /// Returns the new value so callers can capture it.
    @discardableResult
    mutating func bump() -> Int {
        current += 1
        return current
    }

    /// True only if `gen` was produced by the most recent `bump()`.
    func isValid(_ gen: Int) -> Bool {
        gen == current
    }
}

// MARK: - Expected-error classification
//
// Returns `true` for errors that represent a normal/expected end of a recognition
// session: no-speech timeout or voluntary cancellation. These do NOT count as
// backoff failures in VoiceEngine.

func spotterIsExpectedError(_ error: Error) -> Bool {
    let e = error as NSError
    // kAFAssistantErrorDomain/1110 — "no speech detected" (window closed with no audio)
    if e.domain == "kAFAssistantErrorDomain" && e.code == 1110 { return true }
    // NSUserCancelledError (3072) — task.cancel() from endWindow()
    if e.code == NSUserCancelledError { return true }
    return false
}

// MARK: - Recognizer turned off in macOS
//
// kLSRErrorDomain/201 — "Siri and Dictation are disabled". Every window fails at once, with
// the microphone working: rebuilding the audio pipeline cannot help, only the user can.

func spotterRecognizerIsDisabled(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == "kLSRErrorDomain" && e.code == 201
}
