import AVFoundation
import os

// MARK: - VoiceCommandCapture
//
// The audio of the current recognition window, kept for Parakeet: the same buffers the
// recognizer gets, wake phrase included, because a command often starts in the same breath.
// `append` runs on the audio tap thread, the rest on main. Holds at most `maxSeconds`.

final class VoiceCommandCapture: Sendable {
    static let maxSeconds = 60

    private struct State {
        var samples: [Float] = []
        var spoiled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A new window: what came before is dropped.
    func begin(preroll: [AVAudioPCMBuffer]) {
        state.withLock { $0 = State() }
        preroll.forEach(append)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // VoiceAudio feeds the raw format when its converter failed: Parakeet can't use that.
        let isMono16k = buffer.format.sampleRate == 16_000 && buffer.format.channelCount == 1
        let chunk = buffer.floatChannelData.map {
            Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength)))
        }
        state.withLock { current in
            guard isMono16k, let chunk else { current.spoiled = true; return }
            current.samples.append(contentsOf: chunk)
            let extra = current.samples.count - Self.maxSeconds * 16_000
            if extra > 0 { current.samples.removeFirst(extra) }
        }
    }

    /// This window can't go to Parakeet (it holds Coucou's own voice, or it was a cancel word).
    func spoil() { state.withLock { $0.spoiled = true } }

    /// The window's audio, once. nil when spoiled or empty.
    func take() -> [Float]? {
        state.withLock { current in
            defer { current = State() }
            return current.spoiled || current.samples.isEmpty ? nil : current.samples
        }
    }
}
