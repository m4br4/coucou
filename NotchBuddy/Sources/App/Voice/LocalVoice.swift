#if !APPSTORE
import Foundation
import SwiftUI
@preconcurrency import FluidAudio

/// The natural local voice: Kokoro, run on this Mac by FluidAudio. Its models are downloaded once
/// when the user clicks Download in Settings → Voice, then nothing leaves the Mac: the text
/// becomes audio here. Any failure falls back to the Mac voice (VoiceSpeaker).
@MainActor
final class LocalVoice: ObservableObject {
    static let shared = LocalVoice()

    enum State: Equatable {
        /// Intel Mac: the models need Apple silicon.
        case unsupported
        case missing
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    private let synth = KokoroSynth()
    private var warming = false

    private init() { refresh() }

    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Not Parakeet's folder: removing one must not remove the other.
    nonisolated static var modelsRoot: URL {
        HookServer.supportDir.appendingPathComponent("VoiceModels", isDirectory: true)
    }

    /// Written once every voice has spoken: nothing is left to fetch, so it works offline.
    nonisolated private static var marker: URL { modelsRoot.appendingPathComponent("kokoro-ready") }

    var isReady: Bool { state == .ready }

    func refresh() {
        if !Self.isSupported { state = .unsupported; return }
        if state == .downloading { return }
        state = FileManager.default.fileExists(atPath: Self.marker.path) ? .ready : .missing
    }

    func download() {
        guard Self.isSupported, state != .downloading else { return }
        state = .downloading
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
                try await synth.prepareEverything()
                try Data().write(to: Self.marker)
                state = .ready
                appendAppLog("nb.log", "[LocalVoice] models downloaded")
            } catch {
                appendAppLog("nb.log", "[LocalVoice] download failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func remove() {
        Task { @MainActor in
            await synth.unload()
            try? FileManager.default.removeItem(at: Self.modelsRoot)
            refresh()
        }
    }

    /// Loads the voices ahead of the first answer, which would otherwise wait seconds.
    func preload() {
        guard VoiceSettings.ttsEngine == "local", isReady, !warming else { return }
        warming = true
        Task { @MainActor in
            for language in ["es", "en"] {
                do { try await synth.warm(language) } catch {
                    appendAppLog("nb.log", "[LocalVoice] load failed: \(error.localizedDescription)")
                }
            }
            warming = false
        }
    }

    /// The voice for this locale, nil when the Mac voice speaks instead.
    func voice(for locale: Locale?) -> VoiceSpeech.LocalVoice? {
        guard VoiceSettings.ttsEngine == "local", isReady, let locale else { return nil }
        return VoiceSpeech.localVoice(language: locale.identifier, chosen: "", gender: VoiceSettings.elevenGender)
    }

    /// WAV audio, nil when the Mac voice should say it: never a long wait for a voice still loading.
    func audio(for text: String, voice: VoiceSpeech.LocalVoice) async -> Data? {
        guard await synth.isWarm(voice.language) else { preload(); return nil }
        do {
            return try await synth.speak(text, voice: voice, speed: Float(VoiceSettings.speechRate))
        } catch is CancellationError {
            return nil
        } catch {
            appendAppLog("nb.log", "[LocalVoice] synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Kokoro's two frontends, one piece of speech at a time: an actor alone would interleave them
/// at each await.
private actor KokoroSynth {
    private var managers: [String: KokoroAneManager] = [:]
    private var warm = Set<String>()
    private var tail: Task<Void, Never>?

    func isWarm(_ language: String) -> Bool { warm.contains(language) }

    func warm(_ language: String) async throws {
        guard !warm.contains(language) else { return }
        try await inTurn { [self] in
            let voices = VoiceSpeech.localVoices.filter { $0.language == language }
            for voice in voices { _ = try await say("Hola.", voice: voice, speed: 1) }
            await markWarm(language)
        }
    }

    /// Every voice speaks once: voice packs and dictionaries only download on first use.
    func prepareEverything() async throws {
        for language in ["es", "en"] { try await warm(language) }
    }

    func speak(_ text: String, voice: VoiceSpeech.LocalVoice, speed: Float) async throws -> Data {
        try await inTurn { [self] in try await say(text, voice: voice, speed: speed) }
    }

    func unload() async {
        for manager in managers.values { await manager.cleanup() }
        managers = [:]
        warm = []
    }

    private func markWarm(_ language: String) { warm.insert(language) }

    private func inTurn<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func manager(_ language: String) async throws -> KokoroAneManager {
        if let manager = managers[language] { return manager }
        let manager = KokoroAneManager(variant: language == "es" ? .spanish : .english, directory: LocalVoice.modelsRoot)
        try await manager.initialize(preloadVoices: Set(VoiceSpeech.localVoices.filter { $0.language == language }.map(\.id)))
        managers[language] = manager
        return manager
    }

    private func say(_ text: String, voice: VoiceSpeech.LocalVoice, speed: Float) async throws -> Data {
        let kokoro = try await manager(voice.language)
        guard voice.language == "es" else { return try await kokoro.synthesize(text: text, voice: voice.id, speed: speed) }
        let phonemes = VoiceSpeech.seseo(try await kokoro.phonemes(for: text))
        // Past Kokoro's phoneme limit only the text path cuts it into pieces.
        if let audio = try? await kokoro.synthesizeFromPhonemes(phonemes, voice: voice.id, speed: speed) { return audio }
        return try await kokoro.synthesize(text: text, voice: voice.id, speed: speed)
    }
}

/// Settings → Voice: the download, like Parakeet's.
struct LocalVoiceRow: View {
    @ObservedObject private var voice = LocalVoice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch voice.state {
                case .unsupported:
                    Text(verbatim: "Necesita un Mac con Apple silicon.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                case .missing:
                    Button { voice.download() } label: { Text(verbatim: "Descargar voz natural (≈ 130 MB)") }
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Descargando…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                case .ready:
                    Label { Text(verbatim: "Instalada") } icon: { Image(systemName: "checkmark.circle.fill") }
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Button { voice.remove() } label: { Text(verbatim: "Eliminar") }
                case .failed:
                    Button { voice.download() } label: { Text(verbatim: "Reintentar descarga") }
                }
            }
            Text(verbatim: "Kokoro: habla en este Mac, sin internet. Hasta que esté lista, o si falla, habla la voz del Mac. En otros idiomas también.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
