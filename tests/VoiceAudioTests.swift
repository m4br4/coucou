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
            check("auto with Parakeet hears both languages",
                  plan("auto", parakeet: true, mac("es-MX", "en-US"))
                      == Plan(locale: "es-MX", parakeetCommand: true, bothLanguages: true))
            check("auto with Parakeet and only English installed still hears both",
                  plan("auto", parakeet: true, mac("en-US")) == Plan(locale: "en-US", parakeetCommand: true, bothLanguages: true))
            check("a recognizer alone can't hear both", plan("auto", mac("es-MX"))?.isWakeOnly == false)
            check("both languages leaves the recognizer to the wake word",
                  plan("auto", parakeet: true, mac("es-MX"))?.isWakeOnly == true)
            check("one language with its model is no wake only", plan("es", parakeet: true, mac("es-MX"))?.isWakeOnly == false)
            check("no model is wake only", plan("es", parakeet: true, mac("en-US"))?.isWakeOnly == true)
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
            check("line: both languages",
                  Plan(locale: "en-US", parakeetCommand: true, bothLanguages: true).statusText
                      == "wake en-US · comando con Parakeet (es y en)")
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

        // MARK: 6b. What a finished turn runs
        do {
            let english = "open spot if I"
            func outcome(_ parakeet: String?, recognizer: String = english, wakeOnly: Bool = true,
                         stopPhrase: Bool = false, wakeWords: Int = 0) -> VoiceCommandOutcome {
                VoiceCommandText.outcome(parakeet: parakeet, recognizer: recognizer, wakeOnly: wakeOnly,
                                         stopPhrase: stopPhrase, wakeWords: wakeWords, coucou: false)
            }
            check("wake only: Parakeet's words run", outcome("abre Spotify") == .command("abre Spotify"))
            check("wake only: the wake phrase comes off",
                  outcome("O Harvis, abre Spotify", wakeWords: 2) == .command("abre Spotify"))
            check("wake only: failure or timeout never runs the recognizer", outcome(nil) == .unwritten)
            check("wake only: spoke, Parakeet failed, recognizer silent is still said", outcome(nil, recognizer: "") == .unwritten)
            check("wake only: Parakeet wrote nothing", outcome("") == .unwritten)
            check("wake only: only the wake word", outcome("Jarvis.") == .unwritten)
            check("wake only: only a misheard wake word", outcome("Harvis.", wakeWords: 1) == .unwritten)
            check("wake only: nobody heard words", outcome("", recognizer: "") == .command(""))
            check("wake only: the wake word alone, then silence", outcome("Jarvis", recognizer: "") == .command(""))
            check("wake only: cancelling still works", outcome("", recognizer: "cancel", stopPhrase: true) == .command("cancel"))
            check("wake only: a stop word beats Parakeet", outcome("abre Spotify", recognizer: "cancel", stopPhrase: true) == .command("cancel"))
            check("same language: failure keeps the recognizer", outcome(nil, wakeOnly: false) == .command(english))
            check("same language: empty keeps the recognizer", outcome("", wakeOnly: false) == .command(english))
            check("same language: Parakeet's words run", outcome("abre Spotify", wakeOnly: false) == .command("abre Spotify"))
            check("same language: silence", outcome(nil, recognizer: "", wakeOnly: false) == .command(""))

            check("unwritten in Spanish", VoiceCommandText.unwrittenMessage(language: "es") == "No pude escribir el comando. Repítelo.")
            check("unwritten in French", VoiceCommandText.unwrittenMessage(language: "fr").hasPrefix("Je n'ai pas pu"))
            check("unwritten falls back to English", VoiceCommandText.unwrittenMessage(language: "en").hasPrefix("I couldn't"))
        }

        // MARK: 6c. Turns waiting for Parakeet
        do {
            var pending = PendingCommands()
            let first = pending.add()
            check("the first answer finishes the turn", pending.finish(first))
            check("the timeout after it does nothing", !pending.finish(first))
            let second = pending.add()
            let third = pending.add()
            check("turns are told apart", second != third)
            pending.dropAll()
            check("a dropped turn gets no answer", !pending.finish(second))
            check("a dropped turn gets no timeout", !pending.finish(third))
            let fourth = pending.add()
            check("an id is never reused", fourth != first && fourth != second && fourth != third)
            check("a new turn after a drop works", pending.finish(fourth))
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

        // MARK: 8. Speech speed
        do {
            typealias S = VoiceSpeech
            check("the default is 0.85", S.defaultRate == 0.85)
            check("the range is 0.6 to 1.2", S.rateRange == 0.6...1.2)
            check("never saved gives the default", S.rate(stored: 0) == 0.85)
            check("a saved value stays", S.rate(stored: 1.1) == 1.1)
            check("too slow is clamped", S.rate(stored: 0.2) == 0.6)
            check("too fast is clamped", S.rate(stored: 3) == 1.2)
            let base = AVSpeechUtteranceDefaultSpeechRate
            check("applied to the system's default rate", S.utteranceRate(multiplier: 0.85, base: base) == base * 0.85)
            check("1× is the system's rate", S.utteranceRate(multiplier: 1, base: base) == base)
            check("the extremes stay inside what AVSpeech takes",
                  S.utteranceRate(multiplier: 0.6, base: base) >= AVSpeechUtteranceMinimumSpeechRate
                      && S.utteranceRate(multiplier: 1.2, base: base) <= AVSpeechUtteranceMaximumSpeechRate)
        }

        // MARK: 9. Pauses
        do {
            typealias S = VoiceSpeech
            func texts(_ text: String) -> [String] { S.chunks(text).map(\.text) }
            check("one sentence stays whole", S.chunks("Abrí Spotify") == [.init(text: "Abrí Spotify", pause: 0)])
            check("sentences are cut",
                  S.chunks("Listo. Ya lo abrí.") == [.init(text: "Listo.", pause: S.sentencePause),
                                                     .init(text: "Ya lo abrí.", pause: S.sentencePause)])
            check("a long comma gets the short pause",
                  S.chunks("Revisé las ventas de hoy, y todo va muy bien") ==
                      [.init(text: "Revisé las ventas de hoy,", pause: S.commaPause),
                       .init(text: "y todo va muy bien", pause: 0)])
            check("the comma pause is shorter", S.commaPause < S.sentencePause)
            check("a short comma stays", texts("Sí, claro que lo hago") == ["Sí, claro que lo hago"])
            check("a short end stays", texts("Lo hice hoy mismo, claro") == ["Lo hice hoy mismo, claro"])
            check("a list stays whole", texts("Uno, dos, tres y cuatro") == ["Uno, dos, tres y cuatro"])
            check("numbers stay whole", texts("Son 1,500 pesos y 3.5 por ciento") == ["Son 1,500 pesos y 3.5 por ciento"])
            check("hours stay whole", texts("La cita es a las 10:30 hoy") == ["La cita es a las 10:30 hoy"])
            check("questions and exclamations", texts("¿Qué hago? ¡Listo!") == ["¿Qué hago?", "¡Listo!"])
            check("ellipsis stays with its sentence", texts("Pues... sí") == ["Pues...", "sí"])
            check("closing quote stays with its sentence", texts("Dijo «listo.» Y ya") == ["Dijo «listo.»", "Y ya"])
            check("an abbreviation is no sentence", texts("Llamé al Sr. García hoy") == ["Llamé al Sr. García hoy"])
            check("new lines cut", texts("Uno\nDos") == ["Uno", "Dos"])
            check("nothing is lost, in order",
                  texts("Primero esto, luego lo otro también. Y al final, si quieres, aquello.").joined(separator: " ")
                      == "Primero esto, luego lo otro también. Y al final, si quieres, aquello.")
            check("blank comes back as it is", S.chunks("  ") == [.init(text: "  ", pause: 0)])
            check("empty comes back as it is", S.chunks("") == [.init(text: "", pause: 0)])
        }

        // MARK: 10. Mac voices
        do {
            typealias S = VoiceSpeech
            typealias V = VoiceSpeech.Voice
            let paulina    = V(id: "e.paulina", name: "Paulina (Enhanced)", language: "es-MX", quality: .enhanced)
            let paulinaStd = V(id: "c.paulina", name: "Paulina", language: "es-MX", quality: .standard)
            let monica     = V(id: "e.monica", name: "Mónica", language: "es-ES", quality: .premium)
            let monicaStd  = V(id: "c.monica", name: "Mónica", language: "es-ES", quality: .standard)
            let spanish    = V(id: "e.ar", name: "Diego", language: "es-AR", quality: .enhanced)
            let ava        = V(id: "p.ava", name: "Ava (Premium)", language: "en-US", quality: .premium)
            let samantha   = V(id: "c.sam", name: "Samantha", language: "en-US", quality: .standard)
            let thomas     = V(id: "c.tho", name: "Thomas", language: "fr-FR", quality: .standard)
            let anna       = V(id: "p.anna", name: "Anna", language: "de-DE", quality: .premium)
            let all = [samantha, thomas, monicaStd, paulinaStd, ava, spanish, monica, paulina, anna]

            check("Spanish: good voices first, Mexico and Spain ahead",
                  S.offered(all, language: "es") == [paulina, monica, spanish, paulinaStd, monicaStd])
            check("English: only English", S.offered(all, language: "en") == [ava, samantha])
            check("a Mexican Enhanced goes before a Spanish Premium",
                  S.offered([monica, paulina], language: "es") == [paulina, monica])
            check("a language with no voices", S.offered(all, language: "it").isEmpty)
            check("a locale works as the language", S.offered(all, language: "en-GB") == [ava, samantha])
            check("same language, Premium before Enhanced",
                  S.offered([V(id: "a", name: "A", language: "es-MX", quality: .enhanced),
                             V(id: "b", name: "B", language: "es-MX", quality: .premium)], language: "es").first?.id == "b")
            check("same quality and language: by name",
                  S.offered([V(id: "b", name: "Z", language: "es-MX", quality: .standard),
                             V(id: "a", name: "A", language: "es-MX", quality: .standard)], language: "es").first?.id == "a")

            check("label with quality", paulina.label == "Paulina · es-MX · Enhanced")
            check("label of a standard voice", paulinaStd.label == "Paulina · es-MX · Estándar")
            check("label of a Premium", ava.label == "Ava · en-US · Premium")
            check("a good voice in the list", S.hasGoodVoice([paulinaStd, paulina]))
            check("no good voice: the notice shows", !S.hasGoodVoice([paulinaStd, samantha]))
            check("no voices at all: the notice shows", !S.hasGoodVoice([]))

            check("a voice speaks its region's sibling", S.voice(language: "es-MX", speaks: "es-ES"))
            check("underscores count", S.voice(language: "es-MX", speaks: "es_MX"))
            check("a voice doesn't speak another language", !S.voice(language: "es-MX", speaks: "fr-FR"))
        }

        // MARK: 10b. Language of an answer
        do {
            func language(_ text: String, _ fallback: String = "es-MX") -> String {
                VoiceSpeech.language(of: text, fallback: fallback)
            }
            check("Spanish stays", language("Tienes tres reuniones pendientes para esta tarde") == "es-MX")
            check("English in a Spanish turn", language("You have three meetings left this afternoon") == "en-US")
            check("Spanish in an English turn", language("Tienes tres reuniones pendientes para esta tarde", "en-US") == "es-MX")
            check("English stays", language("You have three meetings left this afternoon", "en-US") == "en-US")
            check("the region of the fallback stays", language("Tienes tres reuniones pendientes para esta tarde", "es-ES") == "es-ES")
            check("too short keeps the fallback", language("Hello there") == "es-MX")
            check("one word keeps the fallback", language("Done") == "es-MX")
            check("empty keeps the fallback", language("") == "es-MX")
            check("numbers keep the fallback", language("10 20 30 40") == "es-MX")
            check("French keeps its own voice", language("You have three meetings left this afternoon", "fr-FR") == "fr-FR")
            check("a correction in English", language("Correction: say I went, not I go.") == "en-US")
            check("a Jarvis answer in Spanish", language("Las ventas de HispanoHost subieron esta semana.") == "es-MX")
            check("brand names don't flip Spanish", language("Abrí Spotify y puse tu playlist de Chill Vibes.") == "es-MX")
        }

        // MARK: 11. Local voices
        do {
            typealias S = VoiceSpeech
            func voice(_ language: String, chosen: String = "", gender: String = "female") -> String? {
                S.localVoice(language: language, chosen: chosen, gender: gender)?.id
            }
            check("Spanish, female", voice("es-MX") == "ef_dora")
            check("Spanish, male", voice("es-ES", gender: "male") == "em_alex")
            check("English, female", voice("en-US") == "af_heart")
            check("English, male", voice("en-GB", gender: "male") == "am_michael")
            check("French stays with the Mac voice", voice("fr-FR") == nil)
            check("a picked voice beats the gender", voice("es-MX", chosen: "em_alex") == "em_alex")
            check("a voice of another language is not picked", voice("es-MX", chosen: "af_heart") == "ef_dora")
            check("an unknown voice is not picked", voice("en-US", chosen: "gone") == "af_heart")
            check("each language has both genders",
                  ["es", "en"].allSatisfy { l in Set(S.localVoices.filter { $0.language == l }.map(\.male)).count == 2 })
            check("seseo", S.seseo("las θˈinko") == "las sˈinko")
            check("seseo leaves the rest", S.seseo("ˈola") == "ˈola")
        }

        // MARK: 12. English practice
        do {
            typealias E = EnglishPractice
            func off(_ text: String) -> E.Command { E.command(for: text, active: false) }
            func on(_ text: String) -> E.Command { E.command(for: text, active: true) }
            check("the phrase starts it", off("practiquemos inglés") == .start)
            check("with accents, capitals and a period", off("Practiquemos Inglés.") == .start)
            check("without the accent, as dictation may write it", off("practiquemos ingles") == .start)
            check("inside a sentence", off("oye, vamos a practicar inglés un rato") == .start)
            check("Parakeet may write it in English", off("let's practice English") == .start)
            check("another command doesn't start it", off("abre Spotify") == .none)
            check("just the language doesn't start it", off("¿cómo se dice perro en inglés?") == .none)
            check("«ya» means nothing outside of practice", off("ya") == .none)
            check("leaving means nothing outside of practice", off("volvamos al español") == .none)
            check("«ya» leaves", on("ya") == .stop)
            check("«Ya.» leaves", on("Ya.") == .stop)
            check("«volvamos al español» leaves", on("Volvamos al español.") == .stop)
            check("inside a sentence too", on("creo que ya, volvamos al español") == .stop)
            check("«ya» inside a sentence stays practice", on("ya comí hoy") == .turn)
            check("English goes on", on("I went to the market yesterday") == .turn)
            check("«stop» is just English here", on("stop") == .turn)
            check("asking again doesn't restart it", on("practiquemos inglés") == .turn)

            for level in E.Level.allCases {
                let prompt = E.systemPrompt(level: level)
                check("\(level.rawValue): ends with a correction", prompt.contains("Correction:"))
                check("\(level.rawValue): not about pronunciation", prompt.contains("never comment on pronunciation"))
                check("\(level.rawValue): grammar and vocabulary", prompt.contains("grammar or vocabulary"))
                check("\(level.rawValue): no tools", prompt.contains("You can only talk"))
                check("\(level.rawValue): for reading aloud", prompt.contains("read aloud"))
            }
            check("levels differ", E.systemPrompt(level: .basic) != E.systemPrompt(level: .intermediate))
            check("basic is for beginners", E.systemPrompt(level: .basic).contains("beginner"))
            check("intermediate is intermediate", E.systemPrompt(level: .intermediate).contains("intermediate"))

            check("off by default", !E.isActive)
            E.set(true)
            check("set on", E.isActive)
            check("in practice, a command is a practice turn", E.command(for: "abre Spotify", active: E.isActive) == .turn)
            E.set(false)
            check("set off", !E.isActive)
            check("after the end, the next command is Jarvis's", E.command(for: "abre Spotify", active: E.isActive) == .none)

            var history = E.History()
            history.begin()
            check("the history starts with the opening", history.messages.count == 2
                  && history.messages[1]["content"] as? String == E.opening)
            history.add(turn: "hello")
            history.takeBack(turn: "hello")
            check("a failed turn is taken back", history.messages.count == 2)
            history.add(turn: "hello")
            history.clear()
            history.takeBack(turn: "hello")
            check("the session ended during the call: nothing to take back, no crash", history.messages.isEmpty)
            history.begin()
            history.add(turn: "new turn")
            history.takeBack(turn: "old turn")
            check("another turn is not taken back", history.messages.count == 3)
            history.begin()
            history.takeBack(turn: E.opening)
            check("an answer with the same words is not taken back", history.messages.count == 2)
            history.begin()
            for i in 0..<30 {
                history.add(turn: "turn \(i)")
                history.add(answer: "answer \(i)")
            }
            check("the history is capped", history.messages.count <= 21)
            check("it still starts with the user", history.messages.first?["role"] as? String == "user")
            check("it keeps the newest", history.messages.last?["content"] as? String == "answer 29")
            UserDefaults.standard.removeObject(forKey: E.levelKey)
            check("basic by default", E.level == .basic)
            UserDefaults.standard.set("intermediate", forKey: E.levelKey)
            check("the saved level", E.level == .intermediate)
            UserDefaults.standard.set("expert", forKey: E.levelKey)
            check("an unknown level is basic", E.level == .basic)
            UserDefaults.standard.removeObject(forKey: E.levelKey)
        }

        print("\(total - failures)/\(total) tests passed.")
        exit(failures == 0 ? 0 : 1)
    }
}
