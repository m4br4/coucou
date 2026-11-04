import AVFoundation
import Foundation

// VoiceAudio logs through the app; here the lines are kept to look at them.
nonisolated(unsafe) var logged: [String] = []
let logLock = NSLock()
func appendAppLog(_ fileName: String, _ message: String, timestampFormat: String = "") {
    logLock.withLock { logged.append(message) }
}

@main
enum VoiceAudioTests {

    static var failures = 0
    static var total    = 0

    static func check(_ name: String, _ condition: Bool) {
        total += 1
        if !condition { failures += 1; print("FAIL: \(name)") }
    }

    static func buffer(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount,
                       amplitude: Float) -> AVAudioPCMBuffer {
        // Without a channel layout, as AVAudioEngine reports a USB microphone.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buf.floatChannelData![ch][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate))
            }
        }
        return buf
    }

    static func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Feeds silence until the VAD is calibrated, then voice, and returns what reached onBuffer.
    static func delivered(rate: Double, channels: AVAudioChannelCount,
                          frames: AVAudioFrameCount) -> (buffers: [AVAudioPCMBuffer], started: Bool) {
        let audio = VoiceAudio()
        var buffers: [AVAudioPCMBuffer] = []
        var started = false
        audio.onBuffer = { buf, _ in buffers.append(buf) }
        audio.onVoiceStart = { started = true }
        audio.prepareConverter(for: buffer(rate: rate, channels: channels, frames: 1, amplitude: 0).format)
        let time = AVAudioTime(hostTime: 0)
        for _ in 0..<40 { audio.processTap(buffer(rate: rate, channels: channels, frames: frames, amplitude: 0.0005), time: time) }
        let quiet = buffers.count
        for _ in 0..<40 { audio.processTap(buffer(rate: rate, channels: channels, frames: frames, amplitude: 0.5), time: time) }
        drainMain()
        check("\(Int(rate)) Hz \(channels)ch: silence reaches no recognizer", quiet == 0)
        return (buffers, started)
    }

    static func main() {

        // MARK: 1. Format: whatever the mic gives, the recognizer gets mono 16 kHz Float32
        for (rate, channels, frames) in [(48_000.0, AVAudioChannelCount(2), AVAudioFrameCount(4800)),
                                         (48_000.0, 1, 4800), (44_100.0, 1, 4410), (16_000.0, 1, 1600)] {
            let name = "\(Int(rate)) Hz \(channels)ch"
            let (buffers, started) = delivered(rate: rate, channels: channels, frames: frames)
            check("\(name): voice starts", started)
            check("\(name): voice reaches the recognizer", !buffers.isEmpty)
            guard let last = buffers.last else { continue }
            check("\(name): 16 kHz", last.format.sampleRate == 16_000)
            check("\(name): mono", last.format.channelCount == 1)
            check("\(name): Float32", last.format.commonFormat == .pcmFormatFloat32)
            let expected = Double(frames) * 16_000 / rate
            check("\(name): 100 ms stays 100 ms", abs(Double(last.frameLength) - expected) <= expected * 0.05)
            let samples = UnsafeBufferPointer(start: last.floatChannelData![0], count: Int(last.frameLength))
            check("\(name): the sound survives", (samples.map { abs($0) }.max() ?? 0) > 0.1)
        }

        // MARK: 1b. 48 kHz stereo, the eMeet C960's format, with sound in one channel only
        do {
            let audio = VoiceAudio()
            let stereo = buffer(rate: 48_000, channels: 2, frames: 4800, amplitude: 0.5)
            memset(stereo.floatChannelData![1], 0, 4800 * MemoryLayout<Float>.size)
            var buffers: [AVAudioPCMBuffer] = []
            audio.onBuffer = { buf, _ in buffers.append(buf) }
            audio.prepareConverter(for: stereo.format)
            let time = AVAudioTime(hostTime: 0)
            for _ in 0..<40 { audio.processTap(buffer(rate: 48_000, channels: 2, frames: 4800, amplitude: 0.0005), time: time) }
            for _ in 0..<40 { audio.processTap(stereo, time: time) }
            let samples = buffers.last.map { UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) }
            check("stereo with one live channel reaches the recognizer", (samples?.map { abs($0) }.max() ?? 0) > 0.1)
        }

        // MARK: 2. Tap: reports the input once, with the first buffer
        do {
            logLock.withLock { logged.removeAll() }
            let audio = VoiceAudio()
            var inputs: [VoiceInput] = []
            audio.onListening = { inputs.append($0) }
            audio.prepareConverter(for: buffer(rate: 48_000, channels: 2, frames: 1, amplitude: 0).format)
            drainMain()
            check("no report before audio arrives", inputs.isEmpty)
            let time = AVAudioTime(hostTime: 0)
            for _ in 0..<3 { audio.processTap(buffer(rate: 48_000, channels: 2, frames: 4800, amplitude: 0), time: time) }
            drainMain()
            check("reported once", inputs.count == 1)
            check("reported sample rate is the mic's", inputs.first?.sampleRate == 48_000)
            let lines = logLock.withLock { logged }.filter { $0.hasPrefix("[Voice] escuchando con ") }
            check("logged once", lines.count == 1)
            check("reported channels are the mic's", inputs.first?.channels == 2)
            check("log has device and format", lines.first == "[Voice] escuchando con unknown device, 48000 Hz 2ch")
        }

        // MARK: 3. Dictation off is told apart from every other recognizer error
        do {
            check("201 is Dictation off",
                  spotterRecognizerIsDisabled(NSError(domain: "kLSRErrorDomain", code: 201)))
            check("another LSR error is not",
                  !spotterRecognizerIsDisabled(NSError(domain: "kLSRErrorDomain", code: 102)))
            check("201 in another domain is not",
                  !spotterRecognizerIsDisabled(NSError(domain: "kAFAssistantErrorDomain", code: 201)))
            check("no speech is not",
                  !spotterRecognizerIsDisabled(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
            check("201 is not an expected end",
                  !spotterIsExpectedError(NSError(domain: "kLSRErrorDomain", code: 201)))
        }

        // MARK: 4. Status line
        do {
            let mic = VoiceInput(device: "HD Webcam eMeet C960", sampleRate: 48_000, channels: 2)
            func status(enabled: Bool = true, paused: Bool = false, unavailable: Bool = false,
                        dictationOff: Bool = false, error: String? = nil,
                        input: VoiceInput? = mic, locale: String? = "es-MX") -> VoiceListenStatus {
                .resolve(enabled: enabled, paused: paused, recognizerUnavailable: unavailable,
                         dictationDisabled: dictationOff, audioError: error, input: input, locale: locale)
            }
            check("listening", status() == .listening(mic, locale: "es-MX"))
            check("listening text", status().text == "Escuchando ✓ HD Webcam eMeet C960, 48000 Hz 2ch, es-MX")
            check("listening is listening", status().isListening)
            check("off wins", status(enabled: false, dictationOff: true) == .off)
            check("paused", status(paused: true).text == "✗ En pausa")
            check("no model", status(unavailable: true).text == "✗ Sin modelo de voz instalado")
            check("Dictation off says where to fix it",
                  status(dictationOff: true).text == "✗ Dictado apagado: actívalo en Ajustes del Sistema → Teclado → Dictado")
            check("Dictation off with a working mic is not listening", !status(dictationOff: true).isListening)
            check("mic error", status(error: "x").text == "✗ Micrófono no disponible")
            check("Dictation off wins over a mic error", status(dictationOff: true, error: "x").text.contains("Dictado"))
            check("no audio yet", status(input: nil).text == "✗ Sin audio del micrófono")
        }

        print("\(total - failures)/\(total) tests passed.")
        exit(failures == 0 ? 0 : 1)
    }
}
