#if !APPSTORE
import Foundation
import os
import SwiftUI

// MARK: - JarvisTurn
//
// The last wake word was "Jarvis" (not "OK Coucou"), or the jarvis tool answered: Claude
// gets the Spanish prompt and Coucou answers with a Spanish voice. Set at each wake, so
// the next "OK Coucou" goes back to the usual language.
enum JarvisTurn {
    private static let flag = OSAllocatedUnfairLock(initialState: false)
    static var isActive: Bool { flag.withLock { $0 } }
    static func set(_ on: Bool) { flag.withLock { $0 = on } }

    static let locale = Locale(identifier: "es-MX")
}

// MARK: - Settings

enum JarvisSettings {
    static let fabricaKey = "jarvisFabricaPath"
    static let vaultKey = "jarvisVaultPath"

    /// Jarvis's fabrica folder, where `pnpm estado` runs (Settings → Voice → Jarvis).
    static var fabricaPath: String {
        let v = UserDefaults.standard.string(forKey: fabricaKey) ?? ""
        return v.trimmingCharacters(in: .whitespaces).isEmpty ? JarvisLink.defaultFabricaPath : v
    }

    /// Jarvis's vault, watched for reports waiting for approval (Settings → Voice → Jarvis).
    static var vaultPath: String {
        let v = UserDefaults.standard.string(forKey: vaultKey) ?? ""
        return v.trimmingCharacters(in: .whitespaces).isEmpty ? JarvisApprovals.defaultVaultPath : v
    }

    static var godInbox: URL { JarvisLink.expand(JarvisLink.defaultHivePath).appendingPathComponent("agents/god/inbox") }
    static var replies: URL { JarvisLink.expand(JarvisLink.defaultHivePath).appendingPathComponent("agents/god/hq-replies") }
}

struct JarvisSettingsBox: View {
    @AppStorage(JarvisSettings.fabricaKey) private var fabricaPath = JarvisLink.defaultFabricaPath
    @AppStorage(JarvisSettings.vaultKey) private var vaultPath = JarvisApprovals.defaultVaultPath
    @ObservedObject private var approvals = JarvisApprovalStore.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Di «Jarvis, …» para preguntar cómo va una marca o pedirle algo a Michael. Contesta en español. Necesita la API key de Anthropic.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(verbatim: "Carpeta fabrica")
                        .frame(width: 130, alignment: .leading)
                    TextField(JarvisLink.defaultFabricaPath, text: $fabricaPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
                HStack(spacing: 10) {
                    Text(verbatim: "Carpeta vault")
                        .frame(width: 130, alignment: .leading)
                    TextField(JarvisApprovals.defaultVaultPath, text: $vaultPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { approvals.start() }
                }
                Text(verbatim: "Los informes «esperando-aprobacion» del vault abren «Aprobación de Jarvis» en el notch. Aprobar pide Touch ID o la contraseña del Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    approvals.start()
                    approvals.show()
                } label: {
                    Text(verbatim: approvals.pending.isEmpty ? "Ver aprobaciones" : "Ver aprobaciones (\(approvals.pending.count))")
                }
            }
            .padding(6)
        } label: {
            Text(verbatim: "«Jarvis» — agentes de Abraham")
        }
    }
}

// MARK: - JarvisVoice

@MainActor
enum JarvisVoice {
    static let estadoTimeout: TimeInterval = 45
    static let replyTimeout: TimeInterval  = 60
    static let minInterval: TimeInterval   = 10   // HQ's MIN_INTERVAL_MS
    static let dailyMax = 50                       // HQ's DAILY_MAX

    private static var lastSent: Date?
    private static var sentToday = (day: "", count: 0)

    static let tool: [String: Any] = [
        "name": "jarvis",
        "description": "Ask Jarvis, Abraham's agent team. action=status: a question about how a brand or client is doing (social reach, followers, sales, ads, web traffic, leads…); give the brand as said (e.g. HispanoHost) and the question. The answer is read aloud as is. action=message: anything else for Jarvis or Michael (ask for a report, give an order, a question that is not about a brand's numbers); give the whole request in text. Michael's reply is read aloud if it comes within a minute.",
        "input_schema": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["status", "message"]],
                "brand": ["type": "string", "description": "Brand or client for status (HispanoHost, Social Space…)."],
                "question": ["type": "string", "description": "The status question, in Spanish, as the user said it."],
                "text": ["type": "string", "description": "For message: the full request for Michael, in Spanish."],
            ],
            "required": ["action"],
        ],
    ]

    struct Answer {
        let toolResult: String   // sent back to Claude
        let spoken: String       // read aloud as is: the turn ends with it
        var forgetHistory = false // drop the conversation (it held third-party text)
    }

    /// `thirdParty`: web search results or service data already reached Claude in this
    /// conversation; a message for Michael is then refused (see JarvisLink.hasThirdPartyText).
    static func handle(_ input: [String: Any], thirdParty: Bool) async -> Answer {
        JarvisTurn.set(true)
        switch input["action"] as? String ?? "" {
        case "status":  return await status(brand: input["brand"] as? String ?? "",
                                            question: input["question"] as? String ?? "")
        case "message":
            guard !thirdParty else {
                // The history is dropped too, so asking again starts clean.
                log("message: refused, third-party text in the conversation")
                var answer = said("Pídemelo otra vez.")
                answer.forgetHistory = true
                return answer
            }
            return await message(input["text"] as? String ?? "")
        default:        return said("No te entendí qué le pido a Jarvis.")
        }
    }

    private static func said(_ text: String) -> Answer {
        Answer(toolResult: "Already read aloud to the user: \(text)", spoken: text)
    }

    // MARK: Status

    private static func status(brand rawBrand: String, question rawQuestion: String) async -> Answer {
        guard let brand = JarvisLink.cleanBrand(rawBrand) else { return said("¿De qué marca?") }
        guard let question = JarvisLink.cleanQuestion(rawQuestion) else { return said("¿Qué quieres saber de \(brand)?") }
        let fabrica = JarvisLink.expand(JarvisSettings.fabricaPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fabrica.path, isDirectory: &isDir), isDir.boolValue else {
            log("status: fabrica folder missing")
            return said("No encuentro la carpeta de Jarvis. Revisa la ruta en Ajustes, Voz.")
        }
        guard let pnpm = JarvisLink.pnpmExecutable() else {
            log("status: pnpm not found")
            return said("No encuentro pnpm en este Mac.")
        }
        let t0 = Date()
        let outcome = await JarvisLink.runEstado(executable: pnpm,
                                                 arguments: JarvisLink.estadoArguments(brand: brand, question: question),
                                                 directory: fabrica, timeout: estadoTimeout)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        switch outcome {
        case .answer(let text):
            log("status: ok, \(ms) ms")
            return said(text)
        case .unknownBrand:
            log("status: unknown brand, \(ms) ms")
            return said("No conozco la marca \(brand).")
        case .timedOut:
            log("status: timed out")
            return said("Jarvis tarda demasiado. Prueba en un rato.")
        case .failed(let code):
            log("status: exit \(code), \(ms) ms")
            return said("Jarvis no pudo mirar el estado.")
        case .notRunnable:
            log("status: couldn't start pnpm")
            return said("No pude arrancar Jarvis.")
        }
    }

    // MARK: Message for Michael

    private static func message(_ raw: String) async -> Answer {
        guard let text = JarvisLink.normalizeText(raw, max: JarvisLink.voiceTextMax) else {
            return said("¿Qué le digo a Michael?")
        }
        let now = Date()
        if let last = lastSent, now.timeIntervalSince(last) < minInterval {
            return said("Espera unos segundos antes de otro mensaje.")
        }
        let day = now.formatted(.iso8601.year().month().day())
        if sentToday.day != day { sentToday = (day, 0) }
        guard sentToday.count < dailyMax else { return said("Ya mandé muchos mensajes hoy. Usa HQ.") }
        // Counted before delivering, like HQ: a half failure doesn't open endless retries.
        lastSent = now
        sentToday.count += 1

        let id = JarvisLink.messageId(now: now)
        do {
            try JarvisLink.deliver(JarvisLink.buildMessage(text: text, now: now, id: id), inbox: JarvisSettings.godInbox)
        } catch {
            log("message: delivery failed (\(error))")
            return said("No pude dejarle el mensaje a Michael.")
        }
        log("message: delivered, waiting for the reply")
        // The wait can be long: say so instead of going quiet.
        VoiceSpeaker.shared.speak("Se lo paso a Michael.", locale: JarvisTurn.locale)

        guard let reply = await JarvisLink.waitForReply(id: id, in: JarvisSettings.replies, timeout: replyTimeout) else {
            log("message: no reply within \(Int(replyTimeout)) s")
            return said("Michael lo tiene, te aviso.")
        }
        log("message: reply read")
        let (spoken, cut) = JarvisLink.spokenReply(VoiceQuery.spokenText(reply))
        return said("Michael dice: \(spoken)\(cut ? " El resto está en HQ." : "")")
    }

    private static func log(_ message: String) {
        appendAppLog("nb.log", "[Jarvis] \(message)")
    }

    // MARK: Prompt (Spanish)

    /// Claude's system prompt when woken by "Jarvis": the same rules as Coucou's, in Spanish.
    static func systemPrompt(active: [String], available: String) -> String {
        let today = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
            .locale(Locale(identifier: "es_MX")))
        return """
        Eres Jarvis, el asistente de voz de Abraham. Vives en el notch de su Mac, dentro de la app Coucou: \
        rápido, cercano y al grano. Hoy es \(today).
        Todo lo que escribes se lee en voz alta: contesta siempre en español, en una o dos frases cortas, \
        sin markdown, listas, emojis ni enlaces.
        Cuando Abraham pregunte cómo va una marca o un cliente (alcance de redes, seguidores, ventas, anuncios, \
        tráfico, leads…), llama a jarvis con action status, la marca y la pregunta tal como la dijo. \
        Cuando pida un informe, dé una orden o quiera hablar con Michael o con el equipo, llama a jarvis con \
        action message y su petición completa en text. Lo que devuelve jarvis ya se ha leído en voz alta: no lo repitas.
        Para lo demás, actúa con las herramientas en vez de describir: pills, music, service_info para sus datos \
        (ventas de Stripe, GitHub, Vercel, Resend, n8n, Notion, Cal.com, sesiones de agentes como Claude Code, \
        uso del plan, música), open_app, prepare_email y web_search para lo actual (tiempo, noticias, precios, \
        datos de los que no estés seguro). Nunca inventes sus datos.
        Correo: reúne destinatario, asunto y lo que quiere decir (redacta tú el texto, en el idioma que usó), \
        preguntando lo que falte con una pregunta corta cada vez, y luego llama a prepare_email. Tú nunca lo envías: \
        él revisa la tarjeta y pulsa Enviar. Si quiere adjuntar un archivo sin decir cuál, pon wants_attachment \
        y dile que lo suelte en el notch.
        Si necesitas una respuesta suya, termina con una pregunta corta. Si no, nunca termines con pregunta.
        Pills del notch (como mucho 4 además de la principal). Activas: \(active.joined(separator: ", ")). \
        Disponibles: \(available).
        """
    }
}
#endif
