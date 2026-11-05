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
                        dictationOff: Bool = false, startFailed: Bool = false, stalled: Bool = false,
                        recognizer: RecognizerHealth? = nil,
                        input: VoiceInput? = mic, locale: String? = "es-MX") -> VoiceListenStatus {
                var health = recognizer ?? RecognizerHealth()
                if dictationOff { health.dictationTurnedOff() }
                return .resolve(enabled: enabled, paused: paused, recognizerUnavailable: unavailable,
                                recognizer: health, audioStartFailed: startFailed,
                                recognitionStalled: stalled, input: input, locale: locale)
            }
            check("listening", status() == .listening(mic, locale: "es-MX"))
            check("listening text", status().text == "Escuchando ✓ HD Webcam eMeet C960, 48000 Hz 2ch, es-MX")
            check("listening is listening", status().isListening)
            check("off wins", status(enabled: false, dictationOff: true) == .off)
            check("paused", status(paused: true).text == "✗ En pausa")
            check("no model", status(unavailable: true).text == "✗ Sin modelo de voz instalado")
            check("no model names the locale wanted",
                  VoiceListenStatus.resolve(enabled: true, paused: false, recognizerUnavailable: true,
                                            recognizer: RecognizerHealth(), audioStartFailed: false,
                                            recognitionStalled: false, input: mic, locale: nil,
                                            wantedLocale: "es-MX").text == "✗ Sin modelo de voz para es-MX en este Mac")
            check("Dictation off says where to fix it",
                  status(dictationOff: true).text == "✗ Dictado apagado: actívalo en Ajustes del Sistema → Teclado → Dictado")
            check("Dictation off with a working mic is not listening", !status(dictationOff: true).isListening)
            check("audio start failure", status(startFailed: true).text == "✗ Micrófono no disponible")
            check("Dictation off wins over a mic error", status(dictationOff: true, startFailed: true).text.contains("Dictado"))
            check("stalled is not a microphone problem",
                  status(stalled: true).text == "✗ Reconocimiento atascado: apaga y enciende la voz")
            check("audio start failure wins over stalled", status(startFailed: true, stalled: true).text == "✗ Micrófono no disponible")

            var failed = RecognizerHealth()
            failed.windowEnded(failure: "kLSRErrorDomain/102")
            check("recognizer error shows its code", status(recognizer: failed).text == "✗ Reconocedor: kLSRErrorDomain/102")
            check("recognizer error is not listening", !status(recognizer: failed).isListening)
            check("stalled wins over a recognizer error", status(stalled: true, recognizer: failed).text.contains("atascado"))
            check("no audio yet", status(input: nil).text == "✗ Sin audio del micrófono")
        }

        // MARK: 5. Recognizer health: the newest answer wins
        do {
            var health = RecognizerHealth()
            health.dictationTurnedOff()
            health.windowEnded(failure: "kLSRErrorDomain/102")
            check("another error replaces the Dictation notice", !health.dictationDisabled && health.failure == "kLSRErrorDomain/102")
            health.windowEnded(failure: nil)
            check("a normal end keeps the error", health.failure == "kLSRErrorDomain/102")
            health.dictationTurnedOff()
            check("201 replaces the error", health.dictationDisabled && health.failure == nil)
            health.windowEnded(failure: nil)
            check("a normal end clears Dictation off", !health.dictationDisabled)
            health.windowEnded(failure: "x/1")
            health.heard()
            check("text clears the error", health.failure == nil)
            health.dictationTurnedOff()
            health.heard()
            check("text clears Dictation off", !health.dictationDisabled)

            check("failure text is domain/code",
                  spotterFailure(NSError(domain: "kLSRErrorDomain", code: 102)) == "kLSRErrorDomain/102")
            check("no error is no failure", spotterFailure(nil) == nil)
            check("no speech is no failure", spotterFailure(NSError(domain: "kAFAssistantErrorDomain", code: 1110)) == nil)
            check("cancelling is no failure", spotterFailure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) == nil)
        }

        // MARK: 5. "You speak" → locale
        do {
            typealias Plan = VoiceLocalePlan
            // macOS answers for a locale, like SFSpeechRecognizer: "es" comes back as "es-419".
            func mac(_ installed: String...) -> (String) -> String? {
                { id in
                    let real = id == "es" ? "es-419" : id == "en" ? "en-CA" : id
                    return installed.contains(real) ? real : nil
                }
            }
            check("es tries Mexico, then Spain, then plain es",
                  Plan.candidates(for: "es").prefix(3) == ["es-MX", "es-ES", "es"])
            check("es stays Spanish", Plan.candidates(for: "es").allSatisfy { $0.hasPrefix("es") })
            check("auto tries es then en",
                  Plan.candidates(for: "auto").first == "es-MX"
                      && Plan.candidates(for: "auto").contains("en-US")
                      && Plan.candidates(for: "auto").firstIndex(of: "es")! < Plan.candidates(for: "auto").firstIndex(of: "en-US")!)
            check("en stays English", Plan.candidates(for: "en").allSatisfy { $0.hasPrefix("en") })
            check("fr stays French", Plan.candidates(for: "fr").allSatisfy { $0.hasPrefix("fr") })
            check("an unknown value is the fork's Spanish", Plan.candidates(for: "de") == Plan.candidates(for: "es"))

            func plan(_ language: String, parakeet: Bool = false, _ onDevice: @escaping (String) -> String?) -> Plan? {
                Plan.resolve(listenLanguage: language, parakeet: parakeet, onDevice: onDevice)
            }
            check("es uses es-MX", plan("es", mac("es-MX", "es-ES", "en-CA")) == Plan(locale: "es-MX"))
            check("es falls back to es-ES", plan("es", mac("es-ES", "en-CA")) == Plan(locale: "es-ES"))
            check("plain es reports what macOS really uses", plan("es", mac("es-419", "en-CA")) == Plan(locale: "es-419"))
            check("es never listens in English without Parakeet", plan("es", mac("en-CA", "en-US")) == nil)
            check("fr never listens in English without Parakeet", plan("fr", mac("en-US")) == nil)
            check("en never listens in Spanish without Parakeet", plan("en", mac("es-MX")) == nil)
            check("auto takes Spanish first", plan("auto", mac("es-MX", "en-US")) == Plan(locale: "es-MX"))
            check("auto takes English without Spanish", plan("auto", mac("en-CA")) == Plan(locale: "en-CA"))
            check("auto with nothing installed", plan("auto", mac()) == nil)
            check("Parakeet writes the command in the chosen language",
                  plan("es", parakeet: true, mac("es-MX", "en-US")) == Plan(locale: "es-MX", parakeetCommand: true))
            check("no Spanish model: English only hears the wake word",
                  plan("es", parakeet: true, mac("en-US", "en-CA"))
                      == Plan(locale: "en-US", wakeOnlyFor: "es-MX", parakeetCommand: true))
            check("no model at all, Parakeet can't hear the wake word", plan("es", parakeet: true, mac()) == nil)

            check("line: plain locale", Plan(locale: "es-MX").statusText == "es-MX")
            check("line: Parakeet", Plan(locale: "es-MX", parakeetCommand: true).statusText == "es-MX · comando con Parakeet")
            check("line: wake only says so",
                  Plan(locale: "en-US", wakeOnlyFor: "es-MX", parakeetCommand: true).statusText
                      == "wake en-US (sin modelo es-MX) · comando con Parakeet")
        }

        // MARK: 6. Parakeet's words
        do {
            func pick(_ parakeet: String?, recognizer: String = "open spot if I", wakeWords: Int = 0,
                      coucou: Bool = false) -> String {
                VoiceCommandText.pick(parakeet: parakeet, recognizer: recognizer, wakeWords: wakeWords, coucou: coucou)
            }
            check("Parakeet's words win", pick("abre Spotify") == "abre Spotify")
            check("the wake phrase comes off", pick("Ok Jarvis, abre Spotify.") == "abre Spotify.")
            check("a Spanish spelling of the wake word comes off", pick("Yarvis abre Spotify") == "abre Spotify")
            check("only what follows the last wake phrase", pick("no sé Jarvis abre Spotify") == "abre Spotify")
            check("Parakeet heard what the recognizer did not", pick("Jarvis abre Spotify", recognizer: "") == "abre Spotify")
            check("silence stays silence", pick("Jarvis", recognizer: "") == "")
            check("nothing heard keeps the recognizer", pick(nil) == "open spot if I")
            check("blank keeps the recognizer", pick("  \n") == "open spot if I")
            check("only the wake word keeps the recognizer", pick("Jarvis.") == "open spot if I")
            // What Parakeet Ultra really wrote from `say` in Spanish.
            check("a misheard wake word comes off",
                  pick("O Harvis, abrespotiflipó música tranquila.", wakeWords: 2) == "abrespotiflipó música tranquila.")
            check("a wake phrase Parakeet dropped takes no words with it",
                  pick("¿Cómo van las ventas de hispanos de esta semana?", wakeWords: 2)
                      == "¿Cómo van las ventas de hispanos de esta semana?")
            check("no wake phrase in the turn, nothing comes off", pick("Harvis abre Spotify") == "Harvis abre Spotify")
            check("a look-alike further on stays", pick("llama ya mismo a Harvis", wakeWords: 1) == "llama ya mismo a Harvis")
            check("only a misheard wake word keeps the recognizer", pick("Harvis.", wakeWords: 1) == "open spot if I")
            check("wake words: alone", VoiceCommandText.wakeWordCount(in: "Jarvis", coucou: false) == 1)
            check("wake words: with ok and a command",
                  VoiceCommandText.wakeWordCount(in: "ok Jarvis open it", coucou: false) == 2)
            check("wake words: chatter before", VoiceCommandText.wakeWordCount(in: "so yeah Jarvis open", coucou: false) == 3)
            check("wake words: none", VoiceCommandText.wakeWordCount(in: "open it", coucou: false) == 0)
            check("Coucou only comes off when it is on", pick("ok coucou abre Spotify") == "ok coucou abre Spotify")
            check("Coucou comes off when it is on", pick("ok coucou abre Spotify", coucou: true) == "abre Spotify")
        }

        // MARK: 7. Command audio
        do {
            let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let raw48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            func buffer(_ values: [Float], format: AVAudioFormat = mono16k) -> AVAudioPCMBuffer {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
                b.frameLength = AVAudioFrameCount(values.count)
                for (i, v) in values.enumerated() { b.floatChannelData![0][i] = v }
                return b
            }
            let capture = VoiceCommandCapture()
            check("nothing yet", capture.take() == nil)
            capture.begin(preroll: [buffer([1, 2])])
            capture.append(buffer([3]))
            check("preroll then live audio, in order", capture.take() == [1, 2, 3])
            check("taken once", capture.take() == nil)

            capture.append(buffer([9]))
            capture.begin(preroll: [buffer([1])])
            check("a new window drops the old one", capture.take() == [1])

            capture.begin(preroll: [buffer([1])])
            capture.spoil()
            capture.append(buffer([2]))
            check("spoiled gives nothing", capture.take() == nil)
            capture.begin(preroll: [buffer([1])])
            check("the next window starts clean", capture.take() == [1])

            capture.begin(preroll: [])
            capture.append(buffer([1], format: raw48k))
            check("a raw buffer can't go to Parakeet", capture.take() == nil)

            let limit = VoiceCommandCapture.maxSeconds * 16_000
            capture.begin(preroll: [])
            capture.append(buffer([Float](repeating: 1, count: limit)))
            capture.append(buffer([2, 3]))
            let kept = capture.take()
            check("capped at the limit", kept?.count == limit)
            check("the cap keeps the newest audio", kept?.suffix(2) == [2, 3])
        }

        print("\(total - failures)/\(total) tests passed.")
        exit(failures == 0 ? 0 : 1)
    }
}
