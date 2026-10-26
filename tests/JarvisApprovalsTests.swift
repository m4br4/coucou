import Foundation

// MARK: - JarvisApprovals tests (frontmatter parser, report list, APROBADO/RECHAZADO writer)
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
        let widened = J.Report(id: other.id, titulo: other.titulo, informe: other.informe, permite: other.permite, decision: .pendiente)
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

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
