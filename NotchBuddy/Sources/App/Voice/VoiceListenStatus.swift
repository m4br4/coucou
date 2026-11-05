import Foundation

// MARK: - VoiceListenStatus
//
// The line in Settings → Voice. "✓" only means microphone buffers arrive and nothing is
// known to be wrong: it does not promise the recognizer understands the wake word.
// No AppKit/AVFoundation dependency — testable with standalone swiftc.

/// The microphone as the tap really received it.
struct VoiceInput: Equatable, Sendable {
    let device: String
    let sampleRate: Double
    let channels: Int

    var description: String { "\(device), \(Int(sampleRate)) Hz \(channels)ch" }
}

/// What the recognizer last said about itself. The newest answer wins: after 201 another
/// error means Dictation is on and something else is wrong, and the line says that instead.
struct RecognizerHealth: Equatable {
    private(set) var dictationDisabled = false
    private(set) var failure: String? = nil   // "domain/code"

    mutating func dictationTurnedOff() {
        dictationDisabled = true
        failure = nil
    }

    /// A window ended with `failure`, or nil when it ended normally.
    mutating func windowEnded(failure newFailure: String?) {
        dictationDisabled = false
        if let newFailure { failure = newFailure }
    }

    /// It wrote something down: whatever was wrong is over.
    mutating func heard() {
        dictationDisabled = false
        failure = nil
    }
}

enum VoiceListenStatus: Equatable {
    case off
    case listening(VoiceInput, locale: String)
    case notListening(String)

    /// The first reason wins: what the user has to fix before anything else can work.
    static func resolve(enabled: Bool, paused: Bool, recognizerUnavailable: Bool,
                        recognizer: RecognizerHealth, audioStartFailed: Bool,
                        recognitionStalled: Bool,
                        input: VoiceInput?, locale: String?,
                        wantedLocale: String? = nil) -> VoiceListenStatus {
        guard enabled else { return .off }
        if paused { return .notListening("En pausa") }
        if recognizerUnavailable {
            return .notListening(wantedLocale.map { "Sin modelo de voz para \($0) en este Mac" } ?? "Sin modelo de voz instalado")
        }
        if recognizer.dictationDisabled {
            return .notListening("Dictado apagado: actívalo en Ajustes del Sistema → Teclado → Dictado")
        }
        if audioStartFailed { return .notListening("Micrófono no disponible") }
        if recognitionStalled { return .notListening("Reconocimiento atascado: apaga y enciende la voz") }
        if let failure = recognizer.failure { return .notListening("Reconocedor: \(failure)") }
        guard let input, let locale else { return .notListening("Sin audio del micrófono") }
        return .listening(input, locale: locale)
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .off:                            return ""
        case .listening(let input, let locale): return "Escuchando ✓ \(input.description), \(locale)"
        case .notListening(let reason):       return "✗ \(reason)"
        }
    }
}
