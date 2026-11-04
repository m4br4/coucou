import Foundation

// MARK: - VoiceListenStatus
//
// The line in Settings → Voice that says whether the wake word can be heard, and why not.
// No AppKit/AVFoundation dependency — testable with standalone swiftc.

/// The microphone as the tap really received it.
struct VoiceInput: Equatable, Sendable {
    let device: String
    let sampleRate: Double

    var description: String { "\(device), \(Int(sampleRate)) Hz" }
}

enum VoiceListenStatus: Equatable {
    case off
    case listening(VoiceInput, locale: String)
    case notListening(String)

    /// The first reason wins: what the user has to fix before anything else can work.
    static func resolve(enabled: Bool, paused: Bool, recognizerUnavailable: Bool,
                        dictationDisabled: Bool, audioError: String?,
                        input: VoiceInput?, locale: String?) -> VoiceListenStatus {
        guard enabled else { return .off }
        if paused { return .notListening("En pausa") }
        if recognizerUnavailable { return .notListening("Sin modelo de voz instalado") }
        if dictationDisabled {
            return .notListening("Dictado apagado: actívalo en Ajustes del Sistema → Teclado → Dictado")
        }
        if audioError != nil { return .notListening("Micrófono no disponible") }
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
