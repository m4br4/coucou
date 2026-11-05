import CryptoKit
import Foundation

// MARK: - JarvisApprovals tests (frontmatter parser, report list, APROBADO/RECHAZADO writer,
// huella, what HQ may ask over aprobar.sock)
// Everything happens in a temporary vault: the real vault/aprobaciones/ is never touched.

@main
enum JarvisApprovalsTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var total = 0

    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✓  \(label)") } else { print("✗  \(label) \(detail())"); failures += 1 }
    }

    static func write(_ text: String, _ url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: false, encoding: .utf8)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// name · 0x00 · size · 0x00 · bytes, spelled out here so the test doesn't reuse the app's code.
    static func expected(_ documents: [(name: [UInt8], bytes: [UInt8])]) -> String {
        var all: [UInt8] = []
        for d in documents { all += d.name + [0] + Array(String(d.bytes.count).utf8) + [0] + d.bytes }
        return SHA256.hash(data: all).map { String(format: "%02x", $0) }.joined()
    }

    static func pendingReport(_ extra: String = "", tarea: String = "JV-7") -> String {
        "---\ntarea: \(tarea)\nestado: esperando-aprobacion\nfecha: 2026-11-05\npermite: [\"^a$\"]\n---\n# Título\n\(extra)\n"
    }

    static func huellaTests(root: URL) {
        typealias J = JarvisApprovals
        let fm = FileManager.default

        // MARK: huella: HQ's vector
        let vector = root.appendingPathComponent("vector")
        write("hola", vector.appendingPathComponent("a.md"))
        write("ñ", vector.appendingPathComponent("resumen-gratis.md"))
        let literal = "1c9d662b73a4b94f975d96df41c4c2ce42990ac723f864caaf86aa3611bbc579"
        let vectorHuella = J.huella(of: vector.appendingPathComponent("a.md"), data: Data("hola".utf8))
        check("huella: HQ's vector, literally", vectorHuella == literal, vectorHuella)
        check("short code: 12 characters in groups of 4", J.shortCode(literal) == "1c9d-662b-73a4", J.shortCode(literal))
        check("the test's own arithmetic agrees",
              expected([(Array("a.md".utf8), Array("hola".utf8)), (Array("resumen-gratis.md".utf8), [0xC3, 0xB1])]) == literal)

        // MARK: huella: documents
        func folder(_ name: String) -> URL {
            let dir = root.appendingPathComponent(name)
            write("x", dir.appendingPathComponent("a.md"))
            return dir
        }
        func huella(_ dir: URL, _ name: String = "a.md") -> String {
            let url = dir.appendingPathComponent(name)
            return J.huella(of: url, data: J.readRegular(url)?.data ?? Data())
        }
        let doc = (name: Array("a.md".utf8), bytes: Array("x".utf8))
        let resumen = Array("resumen-gratis.md".utf8), completo = Array("informe-completo.md".utf8)

        let alone = folder("alone")
        check("huella: the report alone", huella(alone) == expected([doc]))

        let both = folder("both")
        write("r", both.appendingPathComponent("resumen-gratis.md"))
        write("c", both.appendingPathComponent("informe-completo.md"))
        check("huella: report, resumen, completo, in that order",
              huella(both) == expected([doc, (resumen, [0x72]), (completo, [0x63])]))

        let empty = folder("empty")
        write("", empty.appendingPathComponent("resumen-gratis.md"))
        check("huella: an empty sibling counts, with size 0", huella(empty) == expected([doc, (resumen, [])]))
        check("huella: empty is not the same as missing", huella(empty) != huella(alone))

        let linked = folder("linked")
        write("otro", root.appendingPathComponent("fuera.md"))
        try! fm.createSymbolicLink(at: linked.appendingPathComponent("resumen-gratis.md"), withDestinationURL: root.appendingPathComponent("fuera.md"))
        check("huella: a symlinked sibling is skipped", huella(linked) == expected([doc]))

        let folderSibling = folder("folder-sibling")
        try! fm.createDirectory(at: folderSibling.appendingPathComponent("informe-completo.md"), withIntermediateDirectories: true)
        check("huella: a folder sibling is skipped", huella(folderSibling) == expected([doc]))

        let same = root.appendingPathComponent("same")
        write("r", same.appendingPathComponent("resumen-gratis.md"))
        write("c", same.appendingPathComponent("informe-completo.md"))
        check("huella: a report named like a sibling counts once",
              huella(same, "resumen-gratis.md") == expected([(resumen, [0x72]), (completo, [0x63])]))
        check("huella: the same for the other sibling",
              huella(same, "informe-completo.md") == expected([(completo, [0x63]), (resumen, [0x72])]))

        let big = folder("big")
        let large = [UInt8](repeating: 0x61, count: 1_100_000)
        try! Data(large).write(to: big.appendingPathComponent("informe-completo.md"))
        check("huella: a sibling over 1 MB counts whole", huella(big) == expected([doc, (completo, large)]))

        // MARK: huella: names that aren't ASCII, as they are on disk
        for (label, bytes) in [("composed", Array("informe-a\u{F1}o.md".utf8)), ("decomposed", Array("informe-an\u{303}o.md".utf8))] {
            let dir = root.appendingPathComponent("vault-\(label)/informes")
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let content = Array(pendingReport(tarea: "NAME-1").utf8)
            let path = Array(dir.path.utf8) + [0x2F] + bytes + [0]
            let fd = path.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: path.count) { open($0, O_WRONLY | O_CREAT, 0o600) }
            }
            _ = content.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
            let listed = J.listPending(vault: root.appendingPathComponent("vault-\(label)")).first
            check("huella: \(label) name hashed as its bytes on disk", listed?.huella == expected([(bytes, content)]), listed?.huella ?? "nil")
        }

        // MARK: one read
        check("read: a plain file", J.readRegular(alone.appendingPathComponent("a.md"))?.data == Data("x".utf8))
        check("read: a symlink is nil", J.readRegular(linked.appendingPathComponent("resumen-gratis.md")) == nil)
        check("read: a folder is nil", J.readRegular(folderSibling.appendingPathComponent("informe-completo.md")) == nil)
        let pipe = root.appendingPathComponent("pipe")
        mkfifo(pipe.path, 0o600)
        check("read: a pipe is nil, and doesn't hang", J.readRegular(pipe) == nil)

        // MARK: huella in the reports
        let vault = root.appendingPathComponent("vault")
        let dir = J.informesDir(vault).appendingPathComponent("hq")
        let report = dir.appendingPathComponent("informe.md")
        write(pendingReport(), report)
        func listed() -> J.Report { J.listPending(vault: vault).first! }
        let first = listed()
        check("the report carries its huella", first.huella.count == 64 && first.huella == J.huella(of: report, data: Data(pendingReport().utf8)))

        let future = Date().addingTimeInterval(3600)
        try! fm.setAttributes([.modificationDate: future], ofItemAtPath: report.path)
        let touched = listed()
        check("age: the latest of creation and modification", abs(touched.changedAt.timeIntervalSince(future)) < 1)
        check("touching a file changes nothing", touched == first && touched.hashValue == first.hashValue)
        let born = Date().addingTimeInterval(7200)
        try! fm.setAttributes([.creationDate: born], ofItemAtPath: report.path)
        check("age: a later creation date wins", abs(listed().changedAt.timeIntervalSince(born)) < 1)

        write("resumen", dir.appendingPathComponent("resumen-gratis.md"))
        let withSibling = listed()
        check("a new sibling changes the huella", withSibling.huella != first.huella)
        check("so the report is another one", withSibling != first && !J.mayApprove(seen: first, current: withSibling))

        var failure: J.Failure?
        do { try J.approve(first, vault: vault) } catch let f as J.Failure { failure = f } catch {}
        check("approve refused when only the sibling changed", failure == .changed, "\(String(describing: failure))")
        check("nothing written", !J.exists(J.aprobacionesDir(vault).appendingPathComponent("APROBADO-JV-7.md")))
        failure = nil
        write(pendingReport("una línea más"), report)
        do { try J.approve(withSibling, vault: vault) } catch let f as J.Failure { failure = f } catch {}
        check("approve refused when the text changed, title and permite equal", failure == .changed, "\(String(describing: failure))")
        failure = nil
        do { try J.reject(withSibling, motivo: "no va", vault: vault) } catch let f as J.Failure { failure = f } catch {}
        check("reject refused too", failure == .changed, "\(String(describing: failure))")
        check("approve goes through with the current huella", (try? J.approve(listed(), vault: vault)) == "APROBADO-JV-7.md")

        // MARK: two files, one id
        let a = J.Report(id: "X", titulo: "t", informe: "a.md", permite: ["^a$"], decision: .pendiente, huella: "1")
        let b = J.Report(id: "X", titulo: "t", informe: "b.md", permite: ["^a$"], decision: .pendiente, huella: "2")
        check("same id, two files, two keys", a.key != b.key)

        // MARK: what a request allows
        check("request: the same huella goes", J.requestAllows(requested: a, current: a))
        check("request: another huella of the same file doesn't",
              !J.requestAllows(requested: a, current: J.Report(id: "X", titulo: "t", informe: "a.md", permite: ["^a$"], decision: .pendiente, huella: "9")))
        check("request: another report is another matter", J.requestAllows(requested: a, current: b))
        check("request: none, nothing to compare", J.requestAllows(requested: nil, current: a))

        // MARK: Approve waits
        let shown = Date(timeIntervalSince1970: 1000)
        check("armed: not at once", !J.isArmed(shownAt: shown, now: shown))
        check("armed: not before 1.5 s", !J.isArmed(shownAt: shown, now: shown.addingTimeInterval(1.49)))
        check("armed: at 1.5 s", J.isArmed(shownAt: shown, now: shown.addingTimeInterval(1.5)))

        // MARK: age
        let now = Date(timeIntervalSince1970: 100_000)
        func age(_ seconds: TimeInterval) -> String { J.ageText(since: now.addingTimeInterval(-seconds), now: now) }
        check("age: seconds", age(40) == "informe de hace 40 s", age(40))
        check("age: minutes", age(150) == "informe de hace 2 min", age(150))
        check("age: hours", age(7300) == "informe de hace 2 h", age(7300))
        check("age: days", age(200_000) == "informe de hace 2 d", age(200_000))
        check("age: a date from the future is now", age(-500) == "informe de hace 0 s", age(-500))

        check("id: a final line break is not valid", !J.isValidId("JV-1\n"))
        check("id: the usual ones are", J.isValidId("JV-1.a_b"))
    }

    static func requestTests() {
        typealias R = JarvisRequest
        typealias J = JarvisApprovals
        func line(_ text: String) -> R.Parsed { R.parse(Data(text.utf8)) }
        let hash = String(repeating: "a", count: 64)

        // MARK: the line
        check("line: estado", line(#"{"v":1,"op":"estado"}"#) == .estado)
        check("line: solicitar", line(#"{"v":1,"op":"solicitar","id":"JV-1","huella":"\#(hash)"}"#) == .solicitar(id: "JV-1", huella: hash))
        check("line: not JSON closes", line("hola") == .close)
        check("line: JSON that isn't an object closes", line("[1]") == .close)
        check("line: invalid UTF-8 closes", R.parse(Data([0x7B, 0xFF, 0x7D])) == .close)
        check("line: another v closes", line(#"{"v":2,"op":"estado"}"#) == .close)
        check("line: v as text closes", line(#"{"v":"1","op":"estado"}"#) == .close)
        check("line: v true closes", line(#"{"v":true,"op":"estado"}"#) == .close)
        check("line: v 1.5 closes", line(#"{"v":1.5,"op":"estado"}"#) == .close)
        check("line: no v closes", line(#"{"op":"estado"}"#) == .close)
        check("line: unknown operation closes", line(#"{"v":1,"op":"aprobar","id":"JV-1"}"#) == .close)
        check("line: unknown field closes", line(#"{"v":1,"op":"estado","x":1}"#) == .close)
        check("line: a title is an unknown field",
              line(#"{"v":1,"op":"solicitar","id":"JV-1","huella":"\#(hash)","titulo":"t"}"#) == .close)
        check("line: permite is an unknown field",
              line(#"{"v":1,"op":"solicitar","id":"JV-1","huella":"\#(hash)","permite":[".*"]}"#) == .close)
        check("line: no id is formato", line(#"{"v":1,"op":"solicitar","huella":"\#(hash)"}"#) == .formato)
        check("line: no huella is formato", line(#"{"v":1,"op":"solicitar","id":"JV-1"}"#) == .formato)
        check("line: bad id is formato", line(#"{"v":1,"op":"solicitar","id":"a/b","huella":"\#(hash)"}"#) == .formato)
        check("line: id with a final line break is formato", line(#"{"v":1,"op":"solicitar","id":"a\n","huella":"\#(hash)"}"#) == .formato)
        check("line: id of 65 is formato", line(#"{"v":1,"op":"solicitar","id":"\#(String(repeating: "a", count: 65))","huella":"\#(hash)"}"#) == .formato)
        check("line: short huella is formato", line(#"{"v":1,"op":"solicitar","id":"a","huella":"abc"}"#) == .formato)
        check("line: capitals in the huella are formato", line(#"{"v":1,"op":"solicitar","id":"a","huella":"\#(hash.uppercased())"}"#) == .formato)
        check("line: huella with a final line break is formato", line(#"{"v":1,"op":"solicitar","id":"a","huella":"\#(hash)\n"}"#) == .formato)

        // MARK: the answers
        check("reply: open", R.opened == "{\"v\":1,\"ok\":true,\"estado\":\"en-tarjeta\"}\n")
        check("reply: watching", R.stateReply(watching: true) == "{\"v\":1,\"ok\":true}\n")
        check("reply: no vault", R.stateReply(watching: false) == "{\"v\":1,\"ok\":false}\n")
        let codes: [(R.Failure, String)] = [(.formato, "formato"), (.noExiste, "no-existe"), (.huella, "huella"), (.yaDecidido, "ya-decidido"),
                                            (.sinPermite, "sin-permite"), (.ocupado, "ocupado"), (.espera, "espera"), (.limite, "limite")]
        for (failure, code) in codes {
            check("reply: \(code)", R.reply(failure) == "{\"v\":1,\"ok\":false,\"error\":\"\(code)\"}\n")
        }

        // MARK: finding the report
        func report(_ id: String = "JV-1", informe: String = "a.md", huella: String = hash, permite: [String] = ["^a$"],
                    decision: J.Decision = .pendiente) -> J.Report {
            J.Report(id: id, titulo: "t", informe: informe, permite: permite, decision: decision, huella: huella)
        }
        func failure(_ result: Result<J.Report, R.Failure>) -> R.Failure? {
            if case .failure(let f) = result { return f }
            return nil
        }
        check("find: no such id", failure(R.find([report()], id: "JV-2", huella: hash)) == .noExiste)
        check("find: nothing pending", failure(R.find([], id: "JV-1", huella: hash)) == .noExiste)
        check("find: other huella", failure(R.find([report()], id: "JV-1", huella: String(repeating: "b", count: 64))) == .huella)
        let lookalike = String(hash.prefix(12)) + String(repeating: "b", count: 52)
        check("find: the same short code is not enough", failure(R.find([report()], id: "JV-1", huella: lookalike)) == .huella)
        check("find: approved", failure(R.find([report(decision: .aprobado)], id: "JV-1", huella: hash)) == .yaDecidido)
        check("find: rejected", failure(R.find([report(decision: .rechazado)], id: "JV-1", huella: hash)) == .yaDecidido)
        check("find: decided comes before the huella", failure(R.find([report(decision: .aprobado)], id: "JV-1", huella: lookalike)) == .yaDecidido)
        check("find: no permite", failure(R.find([report(permite: [])], id: "JV-1", huella: hash)) == .sinPermite)
        check("find: a bad permite", failure(R.find([report(permite: ["a\u{200B}b"])], id: "JV-1", huella: hash)) == .sinPermite)
        let twin = report(informe: "b.md", huella: lookalike, permite: ["^b$"])
        if case .success(let found) = R.find([report(), twin], id: "JV-1", huella: lookalike) {
            check("find: two files with one id, the one with that huella", found == twin)
        } else { check("find: two files with one id, the one with that huella", false) }

        // MARK: limits
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = R.Limiter()
        check("limit: the first one goes", limiter.wait(for: "a", now: start) == nil)
        limiter.record("a", now: start)
        check("limit: not within 30 s", limiter.wait(for: "b", now: start.addingTimeInterval(29)) == start.addingTimeInterval(30))
        check("limit: after 30 s", limiter.wait(for: "b", now: start.addingTimeInterval(30)) == nil)

        var hourly = R.Limiter()
        for i in 0..<10 { hourly.record("id-\(i)", now: start.addingTimeInterval(Double(i) * 30)) }
        let later = start.addingTimeInterval(400)
        check("limit: 10 in an hour is all", hourly.wait(for: "otro", now: later) == start.addingTimeInterval(3600))
        check("limit: the oldest falling out of the hour frees one", hourly.wait(for: "otro", now: start.addingTimeInterval(3600)) == nil)

        var oneId = R.Limiter()
        for i in 0..<3 { oneId.record("a", now: start.addingTimeInterval(Double(i) * 40)) }
        let after = start.addingTimeInterval(200)
        check("limit: one id can't use it all", oneId.wait(for: "a", now: after) == start.addingTimeInterval(3600))
        check("limit: other ids still go", oneId.wait(for: "b", now: after) == nil)

        var socketSide = R.Limiter(), vaultSide = R.Limiter()
        socketSide.record("a", now: start)
        check("limit: socket and vault count apart", socketSide.wait(for: "a", now: start) != nil && vaultSide.wait(for: "a", now: start) == nil)

        var cooldown = R.Cooldown()
        cooldown.add(id: "a", huella: hash, now: start)
        check("espera: within 10 minutes", cooldown.isWaiting(id: "a", huella: hash, now: start.addingTimeInterval(599)))
        check("espera: over after 10 minutes", !cooldown.isWaiting(id: "a", huella: hash, now: start.addingTimeInterval(600)))
        check("espera: another huella is another report", !cooldown.isWaiting(id: "a", huella: lookalike, now: start))
        check("espera: another id too", !cooldown.isWaiting(id: "b", huella: hash, now: start))

        // MARK: a request given up on
        let taken = R.Ticket()
        check("ticket: the card goes first", taken.take())
        check("ticket: then the wait can't give up", !taken.abandon())
        let abandoned = R.Ticket()
        check("ticket: the wait gives up first", abandoned.abandon())
        check("ticket: then no card", !abandoned.take())

        // MARK: admitting
        func admit(_ reports: [J.Report], busy: Bool = false, cooldown: R.Cooldown = R.Cooldown(), limiter: R.Limiter = R.Limiter()) -> R.Failure? {
            var limiter = limiter
            return failure(R.admit(reports, id: "JV-1", huella: hash, busy: busy, cooldown: cooldown, limiter: &limiter, now: start))
        }
        var held = R.Cooldown()
        held.add(id: "JV-1", huella: hash, now: start)
        var spent = R.Limiter()
        spent.record("JV-1", now: start)
        check("admit: all clear", admit([report()]) == nil)
        check("admit: something in the notch", admit([report()], busy: true) == .ocupado)
        check("admit: put away", admit([report()], cooldown: held) == .espera)
        check("admit: over the limit", admit([report()], limiter: spent) == .limite)
        check("admit: busy comes first", admit([report()], busy: true, cooldown: held, limiter: spent) == .ocupado)
        check("admit: espera before the limit", admit([report()], cooldown: held, limiter: spent) == .espera)
        check("admit: rejected is ya-decidido, not espera", admit([report(decision: .rechazado)], cooldown: held) == .yaDecidido)
        check("admit: a wrong request doesn't reach the limits", admit([], busy: true, cooldown: held, limiter: spent) == .noExiste)
    }

    // MARK: the real socket, on a temporary path

    /// Sends bytes and returns what comes back; nil when the app closes without a word.
    static func ask(_ path: String, _ bytes: [UInt8], hold: Bool = false) -> String? {
        let fd = connectTo(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &buffer, buffer.count)
        return n > 0 ? String(decoding: buffer[..<n], as: UTF8.self) : nil
    }

    static func connectTo(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, c) in bytes.enumerated() { raw[i] = UInt8(bitPattern: c) } }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
    }

    static func mode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode : nil
    }

    /// sun_path is short: TMPDIR may not fit.
    static func shortFolder() -> String {
        let name = "jv13-\(UUID().uuidString.prefix(8))"
        for base in ["/tmp/claude", "/tmp", ProcessInfo.processInfo.environment["TMPDIR"] ?? ""] where !base.isEmpty {
            let dir = (base as NSString).appendingPathComponent(name)
            if (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil { return dir }
        }
        return NSTemporaryDirectory()
    }

    static func refusal(_ socket: JarvisApprovalSocket) -> JarvisApprovalSocket.Refusal? {
        do { try socket.start(); return nil }
        catch let refusal as JarvisApprovalSocket.Refusal { return refusal }
        catch { return .system(-1) }
    }

    static func socketTests(vault: URL) {
        typealias R = JarvisRequest
        typealias J = JarvisApprovals
        typealias S = JarvisApprovalSocket
        let fm = FileManager.default
        let base = shortFolder()
        defer { try? fm.removeItem(atPath: base) }
        let echo: @Sendable (Data) -> String? = { line in
            switch R.parse(line) {
            case .close: return nil
            case .formato: return R.reply(.formato)
            case .estado: return R.stateReply(watching: true)
            case .solicitar: return R.opened
            }
        }

        // MARK: creating it
        let dir = base + "/Jarvis"
        let path = dir + "/aprobar.sock"
        let server = S(path: path, answer: echo)
        check("socket: starts", refusal(server) == nil)
        check("socket: folder 700", (mode(dir) ?? 0) & 0o777 == 0o700)
        check("socket: is a socket", (mode(path) ?? 0) & S_IFMT == S_IFSOCK)
        check("socket: mode 600", (mode(path) ?? 0) & 0o777 == 0o600)
        check("socket: the process's umask is back", { let m = umask(0o022); umask(m); return m != 0o177 }())

        // MARK: the line, for real
        check("estado answers", ask(path, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) == "{\"v\":1,\"ok\":true}\n")
        check("unknown field: closed without a word", ask(path, Array("{\"v\":1,\"op\":\"estado\",\"x\":1}\n".utf8)) == nil)
        check("bad id: formato", ask(path, Array("{\"v\":1,\"op\":\"solicitar\",\"id\":\"a/b\"}\n".utf8))?.contains("formato") == true)
        let padded = "{\"v\":1,\"op\":\"estado\"}" + String(repeating: " ", count: 1024 - 21 - 1) + "\n"
        check("a line of 1024 bytes is read", padded.utf8.count == 1024 && ask(path, Array(padded.utf8)) != nil)
        let long = "{\"v\":1,\"op\":\"estado\"}" + String(repeating: " ", count: 1024 - 21) + "\n"
        check("a line of 1025 bytes is closed", long.utf8.count == 1025 && ask(path, Array(long.utf8)) == nil)
        let t0 = Date()
        check("no line end: closed", ask(path, Array("{\"v\":1,\"op\":\"estado\"}".utf8)) == nil)
        let waited = Date().timeIntervalSince(t0)
        check("after 2 s", waited > 1.8 && waited < 3, "\(waited)")

        // MARK: connections
        let held = (0..<4).map { _ in connectTo(path) }
        Thread.sleep(forTimeInterval: 0.1)
        check("4 connections are taken", held.allSatisfy { $0 >= 0 })
        check("the 5th is closed", ask(path, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) == nil)
        held.forEach { close($0) }
        Thread.sleep(forTimeInterval: 2.3)
        check("the slots come back", ask(path, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) != nil)
        for _ in 0..<20 {
            let gone = connectTo(path)
            _ = "{\"v\":1,\"op\":\"estado\"}\n".withCString { Darwin.write(gone, $0, 22) }
            close(gone)
        }
        Thread.sleep(forTimeInterval: 0.1)
        check("clients that leave at once don't take the app down", ask(path, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) != nil)

        // MARK: not stealing it
        check("a socket someone answers on is left alone", refusal(S(path: path, answer: echo)) == .inUse)
        check("and keeps answering", ask(path, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) != nil)
        server.stop()

        let staleDir = base + "/stale"
        try! fm.createDirectory(atPath: staleDir, withIntermediateDirectories: true)
        chmod(staleDir, 0o700)
        let stale = staleDir + "/s.sock"
        let old = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, c) in Array(stale.utf8CString).enumerated() { raw[i] = UInt8(bitPattern: c) } }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(old, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(old)
        let fresh = S(path: stale, answer: echo)
        check("an old socket nobody answers on is replaced", refusal(fresh) == nil)
        check("and answers", ask(stale, Array("{\"v\":1,\"op\":\"estado\"}\n".utf8)) != nil)
        fresh.stop()

        // MARK: refusing what isn't ours
        let plainDir = base + "/plain"
        try! fm.createDirectory(atPath: plainDir, withIntermediateDirectories: true)
        chmod(plainDir, 0o700)
        write("mío", URL(fileURLWithPath: plainDir + "/s.sock"))
        check("a file at the path: refused", refusal(S(path: plainDir + "/s.sock", answer: echo)) == .unsafeSocket)
        check("and left in place", read(URL(fileURLWithPath: plainDir + "/s.sock")) == "mío")

        let linkDir = base + "/link"
        try! fm.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
        chmod(linkDir, 0o700)
        write("mío", URL(fileURLWithPath: base + "/target"))
        symlink(base + "/target", linkDir + "/s.sock")
        check("a symlink at the path: refused", refusal(S(path: linkDir + "/s.sock", answer: echo)) == .unsafeSocket)
        check("its target untouched", read(URL(fileURLWithPath: base + "/target")) == "mío")

        let openDir = base + "/open"
        try! fm.createDirectory(atPath: openDir, withIntermediateDirectories: true)
        chmod(openDir, 0o755)
        check("a folder that isn't 700: refused", refusal(S(path: openDir + "/s.sock", answer: echo)) == .unsafeFolder)
        check("nothing created there", mode(openDir + "/s.sock") == nil)

        symlink(plainDir, base + "/linked")
        check("a symlink as the folder: refused", refusal(S(path: base + "/linked/s.sock", answer: echo)) == .unsafeFolder)

        let tooLong = base + "/" + String(repeating: "a", count: 120) + "/s.sock"
        check("a path that doesn't fit: refused", refusal(S(path: tooLong, answer: echo)) == .pathTooLong)

        // MARK: socket and vault together: a request writes nothing
        let report = J.informesDir(vault).appendingPathComponent("informe.md")
        write(pendingReport(), report)
        let huella = J.listPending(vault: vault).first!.huella
        let vaultDir = base + "/vault-socket"
        try! fm.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
        chmod(vaultDir, 0o700)
        let vaultPath = vaultDir + "/s.sock"
        let live = S(path: vaultPath, answer: { line in
            guard case .solicitar(let id, let huella) = R.parse(line) else { return nil }
            var limiter = R.Limiter()
            switch R.admit(J.listPending(vault: vault), id: id, huella: huella, busy: false,
                           cooldown: R.Cooldown(), limiter: &limiter, now: Date()) {
            case .success: return R.opened
            case .failure(let failure): return R.reply(failure)
            }
        })
        try! live.start()
        func solicitar(_ id: String, _ huella: String) -> String? {
            ask(vaultPath, Array("{\"v\":1,\"op\":\"solicitar\",\"id\":\"\(id)\",\"huella\":\"\(huella)\"}\n".utf8))
        }
        check("request: the right id and huella", solicitar("JV-7", huella) == R.opened)
        check("request: another id", solicitar("JV-8", huella) == R.reply(.noExiste))
        write(pendingReport("otra cosa"), report)
        check("request: the report changed since", solicitar("JV-7", huella) == R.reply(.huella))
        check("a request writes nothing in aprobaciones", !J.exists(J.aprobacionesDir(vault)))
        live.stop()
    }

    static func main() {
        typealias J = JarvisApprovals
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("jarvis-approvals-\(UUID().uuidString)")
        defer { if ProcessInfo.processInfo.environment["KEEP"] == nil { try? fm.removeItem(at: root) } }
        let vault = root.appendingPathComponent("vault")

        // MARK: frontmatter
        let template = """
        ---
        tipo: informe
        departamento: redes-copy
        tarea: JV-12
        estado: esperando-aprobacion   # borrador | esperando-aprobacion | aprobado
        fecha: 2026-10-25
        titulo: "Con # dentro"
        permite: ["^git merge --ff-only feat/hq-readonly$", "^git push( -u)? origin main$"]   # comentario
        ---
        # Merge de feat/hq-readonly

        ## Pendiente de aprobación
        - merge
        """
        let (data, body) = J.parseFrontmatter(template)
        check("comment after a value dropped", data["estado"] == "esperando-aprobacion", data["estado"] ?? "nil")
        check("comment after a list dropped", data["permite"] == #"["^git merge --ff-only feat/hq-readonly$", "^git push( -u)? origin main$"]"#,
              data["permite"] ?? "nil")
        check("quoted value kept whole", data["titulo"] == "\"Con # dentro\"", data["titulo"] ?? "nil")
        check("body after the frontmatter", body.hasPrefix("# Merge de feat/hq-readonly"), body)
        check("no frontmatter", J.parseFrontmatter("# Solo texto").data.isEmpty)
        check("CRLF files", J.parseFrontmatter("---\r\nestado: x\r\n---\r\nhola").data["estado"] == "x")
        check("a --- later in the body is not frontmatter", J.parseFrontmatter("hola\n---\nestado: x\n---\n").data.isEmpty)

        check("permite parsed as is", J.parsePermite(data["permite"])
              == ["^git merge --ff-only feat/hq-readonly$", "^git push( -u)? origin main$"])
        check("permite: not a list", J.parsePermite("\"^x$\"").isEmpty && J.parsePermite("[") .isEmpty && J.parsePermite(nil).isEmpty)
        check("permite: non-strings dropped", J.parsePermite(#"["^a$", 3, null]"#) == ["^a$"])
        check("empty permite can't be approved", J.permiteProblem([]) != nil)
        check("multi-line pattern can't be approved", J.permiteProblem(["^a$\npermite: [\".*\"]"]) != nil)
        check("too many patterns", J.permiteProblem(Array(repeating: "^a$", count: 21)) != nil)
        check("valid permite", J.permiteProblem(["^a$"]) == nil)
        for (name, scalar) in [("U+200B zero-width space", "\u{200B}"), ("U+200F right-to-left mark", "\u{200F}"),
                               ("U+202A LTR embedding", "\u{202A}"), ("U+202E RTL override", "\u{202E}"),
                               ("U+2066 LTR isolate", "\u{2066}"), ("U+2069 pop isolate", "\u{2069}"),
                               ("U+FEFF BOM", "\u{FEFF}")] {
            check("invisible \(name) refused", J.permiteProblem(["^git push origin \(scalar)main$"]) != nil)
        }
        check("accents and ñ allowed", J.permiteProblem(["^echo año ñandú café$"]) == nil)

        check("approve: list fits", J.canApprove(contentFits: true, reachedEnd: false))
        check("approve: scrolled to the end", J.canApprove(contentFits: false, reachedEnd: true))
        check("approve off: hidden patterns not seen", !J.canApprove(contentFits: false, reachedEnd: false))

        let seen2 = J.Report(id: "JV-1", titulo: "t", informe: "vault/informes/a.md", permite: ["^a$", "^b$"], decision: .pendiente)
        let grown = J.Report(id: "JV-1", titulo: "t", informe: "vault/informes/a.md",
                             permite: ["^a$", "^b$"] + (1...18).map { "^c\($0)$" }, decision: .pendiente)
        let retitled = J.Report(id: "JV-1", titulo: "otra", informe: "vault/informes/a.md", permite: seen2.permite, decision: .pendiente)
        check("same report seen: may approve", J.mayApprove(seen: seen2, current: seen2))
        check("permite grew under the same id: refused", seen2 != grown && seen2.hashValue != grown.hashValue
              && !J.mayApprove(seen: seen2, current: grown))
        check("title changed under the same id: refused", !J.mayApprove(seen: seen2, current: retitled))
        check("nothing seen yet: refused", !J.mayApprove(seen: nil, current: seen2))
        check("no report shown: refused", !J.mayApprove(seen: seen2, current: nil))

        // MARK: report list
        let informes = J.informesDir(vault)
        write(template, informes.appendingPathComponent("devops/2026-10-25-merge.md"))
        write(template.replacingOccurrences(of: "tarea: JV-12", with: "tarea: no valido/../x")
                      .replacingOccurrences(of: "fecha: 2026-10-25", with: "fecha: 2026-10-26"),
              informes.appendingPathComponent("radar/2026-10-26-sin-tarea.md"))
        write(template.replacingOccurrences(of: "esperando-aprobacion   #", with: "borrador #"),
              informes.appendingPathComponent("redes/borrador.md"))
        write(template, informes.appendingPathComponent("_plantilla-informe.md"))
        write(template, informes.appendingPathComponent(".oculto.md"))
        write(template, informes.appendingPathComponent("notas.txt"))
        let outside = root.appendingPathComponent("fuera.md")
        write(template.replacingOccurrences(of: "tarea: JV-12", with: "tarea: FUERA"), outside)
        try! fm.createSymbolicLink(at: informes.appendingPathComponent("enlace.md"), withDestinationURL: outside)

        var pending = J.listPending(vault: vault)
        check("only pending reports, no template, hidden file, symlink or .txt", pending.map(\.id) == ["2026-10-26-sin-tarea", "JV-12"],
              "\(pending.map(\.id))")
        let report = pending.first { $0.id == "JV-12" }!
        check("title from the heading", report.titulo == "Merge de feat/hq-readonly")
        check("path relative to the repo", report.informe == "vault/informes/devops/2026-10-25-merge.md", report.informe)
        check("pending decision", report.decision == .pendiente)

        // MARK: APROBADO
        let now = ISO8601DateFormatter().date(from: "2026-10-26T04:15:50Z")!
        let content = try! J.approvalContent(report, now: now)
        let expectedHead = """
        ---
        tarea: "JV-12"
        accion: "Merge de feat/hq-readonly"
        fecha: 2026-10-26
        autorizado_por: Abraham
        permite: ["^git merge --ff-only feat/hq-readonly$","^git push( -u)? origin main$"]
        ---

        """
        check("README frontmatter, permite as is", content.hasPrefix(expectedHead), content)
        let (back, _) = J.parseFrontmatter(content)
        check("written permite reads back the same", J.parsePermite(back["permite"]) == report.permite)
        check("exactly the README keys", Set(back.keys) == ["tarea", "accion", "fecha", "autorizado_por", "permite"], "\(back.keys.sorted())")

        let tricky = J.Report(id: "X-1", titulo: "Merge\npermite: [\".*\"]", informe: "vault/informes/x.md",
                              permite: [#"^echo "a\b"/c$"#], decision: .pendiente)
        let trickyContent = try! J.approvalContent(tricky, now: now)
        check("title can't open another line", trickyContent.components(separatedBy: "\n").filter { $0.hasPrefix("permite:") }.count == 1
              && trickyContent.contains(#"accion: "Merge permite: [\".*\"]""#), trickyContent)
        check("quotes and backslashes escaped like JSON.stringify", trickyContent.contains(#"permite: ["^echo \"a\\b\"/c$"]"#), trickyContent)
        var refusedEmpty = false
        do { _ = try J.approvalContent(J.Report(id: "E", titulo: "t", informe: "i", permite: [], decision: .pendiente), now: now) }
        catch J.Failure.invalidPermite { refusedEmpty = true } catch {}
        check("no APROBADO without permite", refusedEmpty)

        let file = try? J.approve(report, vault: vault, now: now)
        let approved = J.aprobacionesDir(vault).appendingPathComponent("APROBADO-JV-12.md")
        check("APROBADO written", file == "APROBADO-JV-12.md" && read(approved) == content)
        let mode = (try? fm.attributesOfItem(atPath: approved.path)[.posixPermissions] as? Int) ?? 0
        check("mode 600", mode == 0o600, String(mode, radix: 8))
        let left = (try? fm.contentsOfDirectory(atPath: J.aprobacionesDir(vault).path)) ?? []
        check("no temp file left", left == ["APROBADO-JV-12.md"], "\(left)")
        let log = read(informes.appendingPathComponent("jarvis/aprobaciones-2026-10-26.md"))
        check("decision logged", log.hasPrefix("# Aprobaciones desde HQ — 2026-10-26\n\n- 2026-10-26T04:15:50.000Z · APROBADO JV-12 (desde Coucou) · vault/informes/devops/2026-10-25-merge.md · permite: "), log)
        check("now approved", J.listPending(vault: vault).first { $0.id == "JV-12" }?.decision == .aprobado)

        var twice: J.Failure?
        do { try J.approve(report, vault: vault, now: now) } catch let f as J.Failure { twice = f } catch {}
        check("second approval refused, file untouched", twice == .notPending && read(approved) == content, "\(String(describing: twice))")

        // MARK: changed or gone
        pending = J.listPending(vault: vault)
        let other = pending.first { $0.id == "2026-10-26-sin-tarea" }!
        let widened = J.Report(id: other.id, titulo: other.titulo, informe: other.informe, permite: other.permite, decision: .pendiente,
                               huella: other.huella)
        write(template.replacingOccurrences(of: "tarea: JV-12", with: "tarea: no valido/../x")
                      .replacingOccurrences(of: #"permite: ["#, with: #"permite: [".*", "#),
              informes.appendingPathComponent("radar/2026-10-26-sin-tarea.md"))
        var changed: J.Failure?
        do { try J.approve(widened, vault: vault, now: now) } catch let f as J.Failure { changed = f } catch {}
        check("permite widened after it was shown: refused", changed == .changed, "\(String(describing: changed))")
        check("nothing written for it", !J.exists(J.aprobacionesDir(vault).appendingPathComponent("APROBADO-2026-10-26-sin-tarea.md")))

        let ghost = J.Report(id: "NO-EXISTE", titulo: "t", informe: "vault/informes/x.md", permite: ["^a$"], decision: .pendiente)
        var gone: J.Failure?
        do { try J.approve(ghost, vault: vault, now: now) } catch let f as J.Failure { gone = f } catch {}
        check("unknown report refused", gone == .notPending)

        // MARK: RECHAZADO
        let current = J.listPending(vault: vault).first { $0.id == "2026-10-26-sin-tarea" }!
        var short: J.Failure?
        do { try J.reject(current, motivo: " no ", vault: vault, now: now) } catch let f as J.Failure { short = f } catch {}
        check("reject needs a reason", short == .motivo)
        let rejected = try? J.reject(current, motivo: "Abre demasiado.\nQuita .*", vault: vault, now: now)
        let rejectedFile = J.aprobacionesDir(vault).appendingPathComponent("RECHAZADO-2026-10-26-sin-tarea.md")
        check("RECHAZADO written like HQ", rejected == "RECHAZADO-2026-10-26-sin-tarea.md" && read(rejectedFile) == """
        ---
        tarea: "2026-10-26-sin-tarea"
        accion: "Merge de feat/hq-readonly"
        fecha: 2026-10-26
        rechazado_por: Abraham (desde Coucou)
        informe: "vault/informes/radar/2026-10-26-sin-tarea.md"
        ---
        Abre demasiado.
        Quita .*

        """, read(rejectedFile))
        check("rejection logged on one line", read(informes.appendingPathComponent("jarvis/aprobaciones-2026-10-26.md"))
              .contains("· RECHAZADO 2026-10-26-sin-tarea (desde Coucou) · vault/informes/radar/2026-10-26-sin-tarea.md · motivo: Abre demasiado. Quita .*\n"))
        check("now rejected", J.listPending(vault: vault).first { $0.id == "2026-10-26-sin-tarea" }?.decision == .rechazado)

        // A used approval counts as approved.
        write(template.replacingOccurrences(of: "tarea: JV-12", with: "tarea: JV-9"), informes.appendingPathComponent("a/jv9.md"))
        write("x", J.aprobacionesDir(vault).appendingPathComponent("_usado-APROBADO-JV-9.md.txt"))
        check("_usado-APROBADO counts as approved", J.listPending(vault: vault).first { $0.id == "JV-9" }?.decision == .aprobado)

        huellaTests(root: root.appendingPathComponent("huella"))
        requestTests()
        socketTests(vault: root.appendingPathComponent("socket-vault"))

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
