import Foundation

// MARK: - JarvisLink tests (pure Foundation: estado runner, HQ message, reply reader)

@main
enum JarvisLinkTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var total = 0

    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✓  \(label)") } else { print("✗  \(label) \(detail())"); failures += 1 }
    }

    static func main() async {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("jarvis-link-\(UUID().uuidString)")
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // MARK: brand and question
        check("brand as said", JarvisLink.cleanBrand(" HispanoHost ") == "HispanoHost")
        check("brand with space and accent", JarvisLink.cleanBrand("Resultados al Día") == "Resultados al Día")
        check("brand: leading dash refused", JarvisLink.cleanBrand("--voz") == nil)
        check("brand: shell characters refused", JarvisLink.cleanBrand("a; rm -rf ~") == nil)
        check("brand: empty refused", JarvisLink.cleanBrand("  ") == nil)
        check("brand: too long refused", JarvisLink.cleanBrand(String(repeating: "a", count: 61)) == nil)
        check("question on one line", JarvisLink.cleanQuestion("¿cómo va\n el alcance\u{0007}?") == "¿cómo va el alcance?")
        check("question: leading dashes dropped", JarvisLink.cleanQuestion("--help me") == "help me")
        check("question: too long refused", JarvisLink.cleanQuestion(String(repeating: "a", count: 501)) == nil)
        check("estado arguments", JarvisLink.estadoArguments(brand: "hispanohost", question: "¿qué tal?")
              == ["-s", "estado", "hispanohost", "¿qué tal?", "--voz"])

        // MARK: spoken lines
        let eight = (1...8).map { "Línea \($0)" }.joined(separator: "\n")
        let spoken = JarvisLink.spokenLines("\n\n" + eight + "\n")
        check("at most 6 lines, punctuated", spoken == "Línea 1. Línea 2. Línea 3. Línea 4. Línea 5. Línea 6.", spoken)
        check("punctuation kept", JarvisLink.spokenLines("¿Sin dato?\nFalta: GHL (token)") == "¿Sin dato? Falta: GHL (token).")
        check("empty output", JarvisLink.spokenLines(" \n\n") == "")

        // MARK: HQ message
        let now = ISO8601DateFormatter().date(from: "2026-10-26T04:15:50Z")!.addingTimeInterval(0.843)
        let id = JarvisLink.messageId(now: now, rand: "abc123")
        check("message id like HQ", id == "2026-10-26T04-15-50-843Z-hq-abc123", id)
        check("message id matches reply pattern", id.range(of: JarvisLink.replyIdPattern, options: .regularExpression) != nil)
        check("random id matches reply pattern",
              JarvisLink.messageId(now: Date()).range(of: JarvisLink.replyIdPattern, options: .regularExpression) != nil)

        check("normalize: CRLF and controls", JarvisLink.normalizeText(" a\r\nb\u{0000}\u{2028}c\t ") == "a\nbc")
        check("normalize: NFC", JarvisLink.normalizeText("e\u{0301}") == "\u{00E9}")
        check("normalize: empty is nil", JarvisLink.normalizeText(" \n ") == nil)
        check("normalize: over 4000 is nil", JarvisLink.normalizeText(String(repeating: "a", count: 4001)) == nil)

        let long = "Pide el informe de alcance de HispanoHost de la última semana\ncon detalle"
        let msg = JarvisLink.buildMessage(text: long, now: now, id: id)
        check("subject: HQ prefix, one line, 60 chars",
              msg.subject == "HQ: " + String("Pide el informe de alcance de HispanoHost de la última semana con detalle".prefix(60)), msg.subject)
        check("fixed fields", msg.conversation == "hq-chat" && msg.from == "hq" && msg.to == "god" && msg.act == "request"
              && msg.hops == 0 && msg.requires_reply && !msg.needs_human && msg.in_reply_to == nil && msg.body == long)
        check("created_at ISO", msg.created_at == "2026-10-26T04:15:50.843Z", msg.created_at)

        let json = (try? JSONSerialization.jsonObject(with: JarvisLink.encoded(msg))) as? [String: Any] ?? [:]
        let keys: Set<String> = ["id", "conversation", "in_reply_to", "from", "to", "act", "subject", "body",
                                 "hops", "requires_reply", "needs_human", "created_at"]
        check("JSON has HQ's keys exactly", Set(json.keys) == keys, "\(json.keys.sorted())")
        check("in_reply_to is null", json["in_reply_to"] is NSNull)

        // MARK: delivery
        let inbox = tmp.appendingPathComponent("inbox")
        try! fm.createDirectory(at: inbox, withIntermediateDirectories: false)
        var delivered = true
        do { try JarvisLink.deliver(msg, inbox: inbox) } catch { delivered = false }
        let file = inbox.appendingPathComponent("\(id).json")
        check("delivered", delivered && fm.fileExists(atPath: file.path))
        let mode = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        check("mode 600", mode == 0o600, String(mode, radix: 8))
        let leftovers = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        check("no temp file left", leftovers == ["\(id).json"], "\(leftovers)")
        let back = (try? JSONDecoder().decode(JarvisLink.HQMessage.self, from: Data(contentsOf: file)))
        check("round trip", back == msg)

        let other = JarvisLink.buildMessage(text: "otro", now: now, id: id)
        var refused = false
        do { try JarvisLink.deliver(other, inbox: inbox) } catch JarvisLink.DeliveryError.exists { refused = true } catch {}
        check("same id: never overwrites", refused
              && (try? JSONDecoder().decode(JarvisLink.HQMessage.self, from: Data(contentsOf: file)))?.body == long)

        let missing = tmp.appendingPathComponent("no-inbox")
        var noInbox = false
        do { try JarvisLink.deliver(msg, inbox: missing) } catch JarvisLink.DeliveryError.noInbox { noInbox = true } catch {}
        check("missing inbox: error, no folder created", noInbox && !fm.fileExists(atPath: missing.path))

        // MARK: reply
        let replies = tmp.appendingPathComponent("hq-replies")
        try! fm.createDirectory(at: replies, withIntermediateDirectories: false)
        let replyFile = replies.appendingPathComponent("\(id).md")
        try! "# Re: HQ: Pide el informe\n\nHecho, te lo mando en 10 minutos.\n".write(to: replyFile, atomically: false, encoding: .utf8)
        check("reply read, heading dropped", JarvisLink.readReply(id: id, in: replies) == "Hecho, te lo mando en 10 minutos.")
        check("bad id refused", JarvisLink.readReply(id: "../\(id)", in: replies) == nil)

        let linkedId = JarvisLink.messageId(now: now, rand: "def456")
        let outside = tmp.appendingPathComponent("secret.md")
        try! "secreto".write(to: outside, atomically: false, encoding: .utf8)
        try! fm.createSymbolicLink(at: replies.appendingPathComponent("\(linkedId).md"), withDestinationURL: outside)
        check("symlink refused", JarvisLink.readReply(id: linkedId, in: replies) == nil)

        let bigId = JarvisLink.messageId(now: now, rand: "0000aa")
        try! String(repeating: "a", count: JarvisLink.replyMax + 1)
            .write(to: replies.appendingPathComponent("\(bigId).md"), atomically: false, encoding: .utf8)
        check("oversized refused", JarvisLink.readReply(id: bigId, in: replies) == nil)

        let emptyId = JarvisLink.messageId(now: now, rand: "0000bb")
        try! "# Re: nada\n\n".write(to: replies.appendingPathComponent("\(emptyId).md"), atomically: false, encoding: .utf8)
        check("empty reply is nil", JarvisLink.readReply(id: emptyId, in: replies) == nil)

        let lateId = JarvisLink.messageId(now: now, rand: "0000cc")
        let lateURL = replies.appendingPathComponent("\(lateId).md")
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? "Listo.".write(to: lateURL, atomically: false, encoding: .utf8)
        }
        let late = await JarvisLink.waitForReply(id: lateId, in: replies, timeout: 3, poll: 0.1)
        check("reply that comes later", late == "Listo.", late ?? "nil")
        let none = await JarvisLink.waitForReply(id: JarvisLink.messageId(now: now, rand: "0000dd"), in: replies,
                                                  timeout: 0.4, poll: 0.1)
        check("no reply: nil after the timeout", none == nil)

        let cut = JarvisLink.spokenReply(String(repeating: "Frase corta de prueba. ", count: 60))
        check("long reply cut at a sentence", cut.cut && cut.text.hasSuffix(".") && cut.text.count <= 600)
        check("short reply kept", JarvisLink.spokenReply("Hecho.") == ("Hecho.", false))

        // MARK: estado runner (a fake pnpm)
        func fake(_ name: String, _ body: String) -> String {
            let url = tmp.appendingPathComponent(name)
            try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: false, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        }
        let fabrica = tmp.appendingPathComponent("fabrica")
        try! fm.createDirectory(at: fabrica, withIntermediateDirectories: false)
        let args = JarvisLink.estadoArguments(brand: "hispanohost", question: "¿cómo va?")

        let ok = fake("ok.sh", #"[ "$(basename "$PWD")" = fabrica ] || exit 9; echo "Alcance: 1200"; echo "$4"; echo "Falta: GHL (token)" >&2; for i in 1 2 3 4 5 6; do echo "extra $i"; done"#)
        let answer = await JarvisLink.runEstado(executable: ok, arguments: args, directory: fabrica, timeout: 5)
        check("answer: stdout only, 6 lines, cwd = fabrica",
              answer == .answer("Alcance: 1200. ¿cómo va? extra 1. extra 2. extra 3. extra 4."), "\(answer)")
        let unknown = await JarvisLink.runEstado(executable: fake("two.sh", "echo 'no conozco' >&2; exit 2"),
                                                 arguments: args, directory: fabrica, timeout: 5)
        check("exit 2: unknown brand", unknown == .unknownBrand, "\(unknown)")
        let failed = await JarvisLink.runEstado(executable: fake("one.sh", "exit 1"), arguments: args, directory: fabrica, timeout: 5)
        check("exit 1: failed", failed == .failed(1), "\(failed)")
        let silent = await JarvisLink.runEstado(executable: fake("silent.sh", "exit 0"), arguments: args, directory: fabrica, timeout: 5)
        check("no output: failed", silent == .failed(0), "\(silent)")
        let t0 = Date()
        let slow = await JarvisLink.runEstado(executable: fake("slow.sh", "exec sleep 10"), arguments: args, directory: fabrica, timeout: 0.5)
        check("timeout", slow == .timedOut && Date().timeIntervalSince(t0) < 5, "\(slow)")
        let missingExe = await JarvisLink.runEstado(executable: tmp.appendingPathComponent("nope").path,
                                                    arguments: args, directory: fabrica, timeout: 5)
        check("missing executable", missingExe == .notRunnable, "\(missingExe)")

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
