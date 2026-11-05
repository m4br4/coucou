import Foundation

// MARK: - JarvisVault tests (no screen: routing, index, search, answer; fixtures only)

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

@main
enum JarvisVaultTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var total = 0

    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✓  \(label)") } else { print("✗  \(label) \(detail())"); failures += 1 }
    }

    static let question = "¿Qué hay de la auditoría de seguridad y lo relacionado a redes de HispanoHost?"
    static let audit = "informes/radar/2026-10-25-auditoria-hispanohost/informe.md"
    static let inventory = "informes/seguridad/2026-10-25-inventario.md"

    static func write(_ vault: URL, _ path: String, _ text: String) {
        let url = vault.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    /// The vault of hive/projects/coucou/JV-5m-vault.md: the two reports of the request, and
    /// more HispanoHost reports than fit in the answer, so a search by brand alone loses one.
    static func makeVault(_ root: URL) -> URL {
        let vault = root.appendingPathComponent("vault")
        write(vault, audit, """
        ---
        tipo: informe
        departamento: radar
        empresa: hispanohost
        dominio: hispanohost.net
        estado: esperando-aprobacion
        medido: 2026-10-25
        ---
        # Auditoría de hispanohost.net

        Tres cabeceras faltan en el sitio.
        El certificado vence en enero.
        Sin hallazgos críticos.
        Esta cuarta línea no entra.
        """)
        write(vault, inventory, """
        ---
        tipo: informe
        departamento: seguridad
        empresa: space-technology
        tarea: JV-sec
        estado: esperando-aprobacion
        fecha: 2026-10-25
        ---
        ## Resumen (3 líneas, en cristiano)
        - Inventario de 14 servidores.
        - Dos sin parches.
        - Nadie fuera de la VPN.

        ## Detalle
        Puertos abiertos: 22 y 443.
        """)
        for (i, dep) in ["redes-copy", "redes-copy", "redes-copy", "desarrollo", "cobranza-ventas"].enumerated() {
            write(vault, "informes/\(dep)/2026-10-2\(i)-hispano-\(i).md", """
            ---
            tipo: informe
            departamento: \(dep)
            empresa: hispanohost
            fecha: 2026-10-2\(i)
            ---
            # Parte \(i) de \(dep)

            Texto del informe \(i).
            """)
        }
        write(vault, "informes/cobranza-ventas/2026-10-20-social.md", """
        ---
        departamento: cobranza-ventas
        empresa: socialspace
        fecha: 2026-10-20
        ---
        # Ventas de Social Space

        Subieron un 4 %.
        """)
        write(vault, "conocimiento/sin-frontmatter.md", "Línea suelta sobre tarifas.\n\nOtra línea.\n")
        write(vault, "conocimiento/informe-diario.json", """
        {"marcas":[{"slug":"hispanohost","nombre":"HispanoHost","dominio":"hispanohost.net"},
        {"slug":"resultadosaldia","nombre":"ResultadosAlDía","dominio":"resultadosaldia.com"},
        {"slug":"socialspace","nombre":"Social Space","dominio":"social.space"}]}
        """)
        write(vault, "informes/radar/captura.png", "png auditoria")
        write(vault, "informes/.DS_Store", "x")
        write(vault, "informes/.gitkeep", "")
        write(vault, "informes/.borrador.md", "# Auditoría a medias\n")
        write(vault, "informes/.oculta/nota.md", "# Auditoría oculta\n")
        write(vault, "informes/notas.json", "{\"auditoria\":1}")
        write(vault, "aprobaciones/APROBADO-x.md", "# Auditoría secreta aprobada\n")
        write(vault, "clientes/demo-cafe/ficha.md", "# Auditoría del café\n")
        write(vault, "clientes/_plantilla/ficha.md", "# Plantilla\n")
        write(vault, "otros/fuera.md", "# Auditoría fuera\n")
        return vault
    }

    static func tree(_ dir: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.subpathsOfDirectory(atPath: dir.path)) ?? []).sorted().map { path in
            let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(path).path)
            return "\(path) \(a?[.size] ?? 0) \(a?[.modificationDate] ?? 0)"
        }
    }

    static func deps(brands: [JarvisVault.Brand], docs: [JarvisVault.Doc], calls: Calls, estado: String? = nil,
                     send: @escaping @Sendable (String) async -> (shown: String, spoken: String) = { ($0, $0) }) -> JarvisVault.Deps {
        JarvisVault.Deps(
            vaultName: "vault",
            brands: { brands },
            search: { q, b, list in calls.add("search"); return JarvisVault.search(q, brand: b, brands: list, docs: docs) },
            estado: { b, _ in calls.add("estado \(b)"); return estado },
            send: { calls.add("send"); return await send($0) })
    }

    static func main() async {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("jarvis-vault-\(UUID().uuidString)")
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let vault = makeVault(tmp)
        let index = JarvisVault.scan(vault: vault, previous: .init())
        let docs = index.docs
        let brands = JarvisVault.brands(vault: vault, docs: docs)
        func doc(_ path: String) -> JarvisVault.Doc? { docs.first { $0.path == path } }
        func paths(_ q: String, _ brand: JarvisVault.Brand? = nil) -> [String] {
            JarvisVault.search(q, brand: brand ?? JarvisVault.mentioned(in: q, brands: brands), brands: brands, docs: docs).map(\.doc.path)
        }
        func route(_ q: String, awaiting: Bool = false) -> JarvisVault.Route {
            JarvisVault.route(q, brands: brands, awaitingAnswer: awaiting)
        }
        func isVault(_ r: JarvisVault.Route) -> Bool { if case .vault = r { return true }; return false }

        // MARK: brands
        let names = brands.map(\.name)
        check("brands of informe-diario.json", names.contains("HispanoHost") && names.contains("Social Space"))
        check("client folder is a brand", names.contains("demo-cafe"))
        check("_plantilla is no client", !names.contains("_plantilla"))
        check("empresa of a report is a brand", names.contains("space-technology"))
        check("said in two words", JarvisVault.mentioned(in: "cómo va hispano host", brands: brands)?.name == "HispanoHost")
        check("by domain", JarvisVault.mentioned(in: "mira hispanohost.net", brands: brands)?.name == "HispanoHost")
        check("with accent", JarvisVault.mentioned(in: "Resultados al Día", brands: brands)?.name == "ResultadosAlDía")
        check("client said with spaces", JarvisVault.mentioned(in: "qué tal demo cafe", brands: brands)?.name == "demo-cafe")
        check("no brand inside another word", JarvisVault.mentioned(in: "hispanohosting barato", brands: brands) == nil)
        check("jarvis is no brand", JarvisVault.brands(vault: tmp, docs: [JarvisVault.parse(path: "conocimiento/j.md", data: Data("---\nempresa: jarvis\n---\n".utf8), modified: 0)]).isEmpty)

        // MARK: routing
        check("brand without prefix goes to the vault", isVault(route("¿Cómo va HispanoHost?")))
        check("client goes to the vault", isVault(route("¿qué sabemos de demo cafe?")))
        for word in ["auditoría", "Auditorias", "seguridad", "redes", "informe", "informes", "estado", "ventas"] {
            check("word «\(word)» goes to the vault", isVault(route("dime algo de \(word) por favor")))
        }
        check("with the Jarvis prefix too", isVault(route("Jarvis, ¿cómo van las ventas?")))
        for q in ["¿Qué tiempo hace mañana?", "pon música", "hola", "explícame qué es un closure en Swift",
                  "Jarvis, ¿qué hora es?", "el estadounidense red", ""] {
            check("«\(q)» stays out", route(q) == .normal)
        }
        check("ventas de Stripe stay with service_info", route("¿cuántas ventas hay en Stripe?") == .normal)
        check("estado de GitHub stays with service_info", route("estado de GitHub") == .normal)
        check("estado de Cal.com stays with service_info", route("estado de cal.com") == .normal)
        check("a service inside a word is no service", isVault(route("informe de calidad cal2")))
        check("brand wins over a service", isVault(route("ventas de HispanoHost en Stripe")))
        for q in ["Haz un informe de HispanoHost", "pídele a Michael el informe de ventas", "Programa un post para Social Space",
                  "Oye, programa la auditoría de hispanohost", "Jarvis, pídele a redes un copy", "¿Puedes pedirle a Michael que lo mire?",
                  "¿me puedes hacer un informe?", "quiero que prepares un informe de HispanoHost", "Dile a Michael que estoy"] {
            check("order: «\(q)»", route(q) == .order, "\(route(q))")
        }
        check("order without brand or word stays out", route("haz un resumen de este texto") == .normal)
        check("programa, the noun", isVault(route("¿Qué programa usa HispanoHost?")))
        check("question about an order word", isVault(route("¿agenda HispanoHost sus informes?")))
        check("wanting to know is no order", isVault(route("quiero saber el estado de HispanoHost")))
        check("a mail stays with the mail card", route("prepara un correo para HispanoHost") == .normal)
        check("the answer to a question stays with it", route("informe de ventas", awaiting: true) == .normal)
        check("approving by voice is no order", isVault(route("aprueba el informe de HispanoHost")))
        check("asks back", JarvisVault.asksBack([["role": "assistant", "content": [["type": "text", "text": "¿Asunto?\n"]]]]))
        check("asks back: plain text", JarvisVault.asksBack([["role": "assistant", "content": "¿Asunto?"]]))
        check("doesn't ask back", !JarvisVault.asksBack([["role": "assistant", "content": [["type": "text", "text": "Listo."]]]]))
        check("user's question isn't asking back", !JarvisVault.asksBack([["role": "user", "content": "¿Qué?"]]))

        // MARK: parsing
        check("title: first heading", doc(audit)?.titulo == "Auditoría de hispanohost.net")
        check("title: file name without heading", doc(inventory)?.titulo == "2026-10-25-inventario")
        check("date from medido", doc(audit)?.fecha == "2026-10-25")
        check("date from fecha", doc(inventory)?.fecha == "2026-10-25")
        let dated = { (front: String, path: String) in
            JarvisVault.parse(path: path, data: Data("---\n\(front)\n---\ntexto\n".utf8), modified: 0).fecha
        }
        check("date from actualizado", dated("actualizado: 2026-09-01", "conocimiento/a.md") == "2026-09-01")
        check("date quoted", dated("fecha: \"2026-09-02\"", "conocimiento/a.md") == "2026-09-02")
        check("date with hour", dated("fecha: 2026-09-03T10:00:00Z", "conocimiento/a.md") == "2026-09-03")
        check("date from the file name", dated("tipo: x", "informes/x/2026-08-01-algo.md") == "2026-08-01")
        check("date from the folder name", dated("tipo: x", "informes/x/2026-08-02-algo/informe.md") == "2026-08-02")
        check("fecha wins over the name", dated("fecha: 2026-07-01", "informes/x/2026-08-01-algo.md") == "2026-07-01")
        check("impossible date ignored", dated("fecha: 2026-13-01", "conocimiento/a.md") == "")
        check("no date", dated("tipo: x", "conocimiento/a.md") == "")
        check("no frontmatter: indexed", doc("conocimiento/sin-frontmatter.md")?.titulo == "sin-frontmatter")
        check("no frontmatter: summary from text", doc("conocimiento/sin-frontmatter.md")?.resumen == ["Línea suelta sobre tarifas.", "Otra línea."])
        check("summary: the section", doc(inventory)?.resumen == ["Inventario de 14 servidores.", "Dos sin parches.", "Nadie fuera de la VPN."])
        check("summary: first three lines", doc(audit)?.resumen.count == 3 && doc(audit)?.resumen.last == "Sin hallazgos críticos.")
        check("summary skips heading, table and code", JarvisVault.summary(body: "# T\n| a |\n```\ncode\n```\nTexto.\n") == ["Texto."])
        check("summary: long line cut", JarvisVault.summary(body: String(repeating: "a", count: 999)).first?.count == JarvisVault.summaryLineMax + 1)
        check("summary: empty section uses the text", JarvisVault.summary(body: "## Resumen\n\n## Otro\nTexto.\n") == ["Texto."])
        check("CRLF frontmatter", JarvisVault.parse(path: "conocimiento/a.md", data: Data("---\r\nempresa: x1\r\n---\r\n# T\r\n".utf8), modified: 0).empresa == "x1")
        check("departamento from the folder", JarvisVault.parse(path: "informes/radar/a.md", data: Data("x".utf8), modified: 0).departamento == "radar")
        check("empresa spellings are one", JarvisVault.key("space-technology") == JarvisVault.key("spacetechnology"))

        // MARK: what is indexed
        let all = Set(docs.map(\.path))
        check("only the .md of the two folders", all.allSatisfy { $0.hasSuffix(".md") && ($0.hasPrefix("informes/") || $0.hasPrefix("conocimiento/")) }, "\(all)")
        check("hidden files and folders never", !all.contains { $0.contains("borrador") || $0.contains("oculta") })
        check("aprobaciones never", !all.contains { $0.contains("aprobaciones") })
        check("clientes never", !all.contains { $0.contains("clientes") })
        check("the rest of the vault never", !all.contains { $0.contains("fuera") })

        let linked = tmp.appendingPathComponent("linked")
        let linkedVault = makeVault(linked)
        try! fm.createSymbolicLink(at: linkedVault.appendingPathComponent("informes/atajo"), withDestinationURL: linkedVault.appendingPathComponent("aprobaciones"))
        try! fm.createSymbolicLink(at: linkedVault.appendingPathComponent("informes/copia.md"), withDestinationURL: linkedVault.appendingPathComponent("aprobaciones/APROBADO-x.md"))
        let linkedDocs = JarvisVault.scan(vault: linkedVault, previous: .init()).docs
        check("a link to aprobaciones isn't followed", linkedDocs.count == docs.count && !linkedDocs.contains { $0.path.contains("atajo") || $0.path.contains("copia") })
        let rootLink = tmp.appendingPathComponent("rootlink")
        let rootVault = rootLink.appendingPathComponent("vault")
        try! fm.createDirectory(at: rootVault, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(at: rootVault.appendingPathComponent("informes"), withDestinationURL: vault.appendingPathComponent("aprobaciones"))
        check("informes as a link isn't walked", JarvisVault.scan(vault: rootVault, previous: .init()).docs.isEmpty)

        // MARK: index on disk, refreshed when files change
        let live = tmp.appendingPathComponent("live")
        let liveVault = makeVault(live)
        let indexFile = tmp.appendingPathComponent("support/Jarvis/vault-index.json")
        let store = JarvisVaultStore(file: indexFile)
        let before = tree(liveVault)
        let liveBrands = await store.brands(vault: liveVault) ?? []
        check("store: brands", liveBrands.contains { $0.name == "HispanoHost" })
        var found = await store.search(question, brand: nil, brands: liveBrands, vault: liveVault)
        check("store: finds", !found.isEmpty)
        check("the vault is left as it was", tree(liveVault) == before)
        check("the index is outside it", fm.fileExists(atPath: indexFile.path))
        let mode = (try? fm.attributesOfItem(atPath: indexFile.path)[.posixPermissions] as? Int) ?? 0
        check("index mode 600", mode == 0o600, "\(String(mode, radix: 8))")
        let saved = String(decoding: (try? Data(contentsOf: indexFile)) ?? Data(), as: UTF8.self)
        check("index holds nothing of aprobaciones", !saved.contains("secreta") && !saved.contains("APROBADO"))

        write(liveVault, "informes/radar/2026-11-01-nueva-auditoria.md", "---\nfecha: 2026-11-01\n---\n# Auditoría zanahoria\n")
        found = await store.search("auditoría zanahoria", brand: nil, brands: liveBrands, vault: liveVault)
        check("a new report counts at once", found.first?.doc.titulo == "Auditoría zanahoria")
        write(liveVault, "informes/radar/2026-11-01-nueva-auditoria.md", "---\nfecha: 2026-11-01\n---\n# Auditoría pepino largo\n")
        found = await store.search("auditoría pepino", brand: nil, brands: liveBrands, vault: liveVault)
        check("a changed report is read again", found.first?.doc.titulo == "Auditoría pepino largo")
        try! fm.removeItem(at: liveVault.appendingPathComponent("informes/radar/2026-11-01-nueva-auditoria.md"))
        found = await store.search("auditoría pepino", brand: nil, brands: liveBrands, vault: liveVault)
        check("a deleted report goes", found.isEmpty)

        let unchanged = JarvisVault.scan(vault: liveVault, previous: JarvisVault.scan(vault: liveVault, previous: .init()))
        var marked = JarvisVault.scan(vault: liveVault, previous: .init())
        let first = marked.docs.removeFirst()
        let fake = JarvisVault.Doc(path: first.path, modified: first.modified, size: first.size, empresa: "", departamento: "",
                                   fecha: "", titulo: "guardado", resumen: [], words: [])
        marked.docs.insert(fake, at: 0)
        check("an unchanged file isn't read again", JarvisVault.scan(vault: liveVault, previous: marked).docs.first?.titulo == "guardado")
        check("same files, same index", unchanged == JarvisVault.scan(vault: liveVault, previous: .init()))
        marked.vault = "/otro"
        check("another vault's index isn't reused", JarvisVault.scan(vault: liveVault, previous: marked).docs.first?.titulo != "guardado")

        let reborn = JarvisVaultStore(file: indexFile)
        let again = await reborn.search(question, brand: nil, brands: liveBrands, vault: liveVault)
        check("index read back after a restart", !again.isEmpty)
        try! Data("{roto".utf8).write(to: indexFile)
        let broken = await JarvisVaultStore(file: indexFile).search(question, brand: nil, brands: liveBrands, vault: liveVault)
        check("a broken index is rebuilt", !broken.isEmpty && (try? JSONDecoder().decode(JarvisVault.Index.self, from: Data(contentsOf: indexFile))) != nil)
        let inside = liveVault.appendingPathComponent("informes/.index/vault-index.json")
        _ = await JarvisVaultStore(file: inside).search(question, brand: nil, brands: liveBrands, vault: liveVault)
        check("the index is never saved in the vault", !fm.fileExists(atPath: inside.deletingLastPathComponent().path))
        let viaLink = tmp.appendingPathComponent("vault-link")
        try! fm.createSymbolicLink(at: viaLink, withDestinationURL: liveVault)
        _ = await JarvisVaultStore(file: viaLink.appendingPathComponent("conocimiento/.idx/i.json")).search(question, brand: nil, brands: liveBrands, vault: liveVault)
        check("nor through a link to it", !fm.fileExists(atPath: liveVault.appendingPathComponent("conocimiento/.idx").path))
        let noVault = await JarvisVaultStore(file: indexFile).brands(vault: tmp.appendingPathComponent("nada"))
        check("no vault: no brands", noVault == nil)

        // MARK: search
        let answer = paths(question)
        check("Abraham's question: the audit", answer.contains(audit), "\(answer)")
        check("Abraham's question: the inventory, filed under another empresa", answer.contains(inventory), "\(answer)")
        check("at most three", answer.count == 3, "\(answer)")
        let noBrandCover = paths("auditoría de seguridad")
        check("without the brand too", noBrandCover.contains(audit) && noBrandCover.contains(inventory), "\(noBrandCover)")
        let recent = paths("¿Cómo va HispanoHost?")
        check("brand alone: its reports, newest first", recent.first == audit && recent.count == 3, "\(recent)")
        check("a sister brand's report isn't HispanoHost's", !paths("ventas de HispanoHost").contains("informes/cobranza-ventas/2026-10-20-social.md"))
        check("its own brand finds it", paths("ventas de Social Space").first == "informes/cobranza-ventas/2026-10-20-social.md", "\(paths("ventas de Social Space"))")
        check("a word in the body counts", paths("informe de seguridad sobre puertos").first == inventory, "\(paths("informe de seguridad sobre puertos"))")
        check("unknown word: nothing", paths("la auditoría de Acme").isEmpty, "\(paths("la auditoría de Acme"))")
        check("nothing about shoes", paths("ventas de zapatos en Panamá").isEmpty)
        check("the weather isn't a report's estado", paths("¿cuál es el estado del tiempo?").isEmpty)
        check("reports in general", paths("¿qué informes hay?").count == 3)
        check("two-word brand isn't looked for as words", !paths("cómo va Social Space").isEmpty)

        // MARK: answer
        check("short date", JarvisVault.shortDate("2026-10-25") == "25-oct")
        check("short date, first of the month", JarvisVault.shortDate("2026-01-05") == "5-ene")
        check("long date", JarvisVault.longDate("2026-09-02") == "2 de septiembre")
        check("no date said", JarvisVault.shortDate("") == "sin fecha")
        let hits = JarvisVault.search(question, brand: brands.first, brands: brands, docs: docs)
        let shown = JarvisVault.shown(hits: hits, estado: "Va bien.", today: Date(timeIntervalSince1970: 1_793_900_000), vaultName: "vault", markdown: true)
        check("source in the answer", shown.contains("Según `vault/\(audit)`, 25-oct: **Auditoría de hispanohost.net**"), shown)
        check("each report with its source", shown.contains("Según `vault/\(inventory)`, 25-oct:"), shown)
        check("three summary lines", shown.contains("Tres cabeceras faltan en el sitio.\nEl certificado vence en enero.\nSin hallazgos críticos."))
        check("estado cited too", shown.contains("Según `pnpm estado`, ") && shown.hasSuffix("Va bien."), shown)
        let plain = JarvisVault.shown(hits: hits, estado: nil, today: Date(), vaultName: "vault", markdown: false)
        check("no markup for the caption", !plain.contains("`") && !plain.contains("**") && plain.contains("vault/\(audit)"))
        let said = JarvisVault.spoken(hits: hits, estado: nil)
        check("no file read aloud", !said.contains(".md"), said)
        check("title and date read aloud", said.contains("Según Auditoría de hispanohost.net, 25 de octubre: Tres cabeceras"), said)
        check("no heading: the department", said.contains("Según el informe de seguridad, 25 de octubre"), said)
        check("web said", JarvisVault.missNotice(usedWeb: true).contains("web") && JarvisVault.missNotice(usedWeb: true).contains("vault"))
        check("no web, not claimed", !JarvisVault.missNotice(usedWeb: false).contains("web"))
        check("web result seen", JarvisVault.usedWeb([["type": "server_tool_use"], ["type": "web_search_tool_result"]]))
        check("no web result", !JarvisVault.usedWeb([["type": "text", "text": "web"]]))

        // MARK: the four cases of the request, end to end
        var calls = Calls()
        var turn = await JarvisVault.turn(question, awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls, estado: "Alcance 10 %."))
        if case .answered(let text, _, let fromVault) = turn {
            check("Abraham's question: both reports with source", text.contains("`vault/\(audit)`") && text.contains("`vault/\(inventory)`"), text)
            check("Abraham's question: from the vault", fromVault)
            check("Abraham's question: estado asked for the brand", calls.count("estado HispanoHost") == 1 && text.contains("Alcance 10 %."))
        } else { check("Abraham's question answered", false, "\(turn)") }
        check("Abraham's question: no order sent", calls.count("send") == 0)

        calls = Calls()
        let inbox = tmp.appendingPathComponent("inbox")
        try! fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let order = "Pídele a Michael una auditoría de HispanoHost"
        turn = await JarvisVault.turn(order, awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls) { text in
            let id = JarvisLink.messageId(now: Date())
            try? JarvisLink.deliver(JarvisLink.buildMessage(text: text, now: Date(), id: id, typed: true), inbox: inbox)
            return ("Se lo pasé.", "Se lo pasé.")
        })
        check("order with brand: answered by the send", turn == .answered(shown: "Se lo pasé.", spoken: "Se lo pasé.", fromVault: false), "\(turn)")
        check("order with brand: vault and estado untouched", calls.count("search") == 0 && calls.count("estado") == 0)
        let delivered = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        let body = delivered.first.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(JarvisLink.HQMessage.self, from: $0) }
        check("order with brand: in Michael's inbox", delivered.count == 1 && body?.to == "god")
        check("order: his words, marked as typed", body?.body == "\(JarvisLink.typedHeader)\n\(order)" && body?.subject.hasPrefix("CHAT: ") == true, "\(String(describing: body))")
        check("typed text fits HQ with its header", JarvisLink.typedTextMax + JarvisLink.typedHeader.utf16.count + 1 == JarvisLink.messageMax)
        let voiced = JarvisLink.buildMessage(text: "x", now: Date(), id: "i")
        check("the voice's message stays as it was", voiced.subject == "VOZ: x" && voiced.body == "\(JarvisLink.voiceHeader)\nx" && voiced.from == JarvisLink.voiceFrom)

        calls = Calls()
        turn = await JarvisVault.turn("¿Cómo van las ventas de zapatos en Panamá?", awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls))
        check("nothing in the vault: on to the web", turn == .pass(miss: true), "\(turn)")
        check("nothing in the vault: it looked", calls.count("search") == 1)

        calls = Calls()
        turn = await JarvisVault.turn("¿Qué tiempo hace mañana?", awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls))
        check("any message: the usual turn, no notice", turn == .pass(miss: false), "\(turn)")
        check("any message: never through the vault", calls.all.isEmpty, "\(calls.all)")

        calls = Calls()
        turn = await JarvisVault.turn("informe de ventas", awaitingAnswer: true, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls))
        check("an answer to a question: the usual turn", turn == .pass(miss: false) && calls.all.isEmpty)

        calls = Calls()
        turn = await JarvisVault.turn("¿Cómo van las ventas?", awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls, estado: "x"))
        check("no brand: no estado", calls.count("estado") == 0)

        calls = Calls()
        turn = await JarvisVault.turn("¿Cómo va demo cafe?", awaitingAnswer: false, markdown: true, deps: deps(brands: brands, docs: docs, calls: calls, estado: "Sin ventas."))
        if case .answered(let text, _, let fromVault) = turn {
            check("only estado answers: cited, not from the vault", text.contains("Según `pnpm estado`") && !fromVault, text)
        } else { check("only estado answers", false, "\(turn)") }

        let goneCalls = Calls()
        let gone = JarvisVault.Deps(vaultName: "vault", brands: { nil }, search: { _, _, _ in goneCalls.add("search"); return [] },
                                    estado: { _, _ in nil }, send: { ($0, $0) })
        turn = await JarvisVault.turn(question, awaitingAnswer: false, markdown: true, deps: gone)
        check("no vault folder: the usual turn, nothing claimed", turn == .pass(miss: false) && goneCalls.all.isEmpty)

        print("\n\(total - failures)/\(total) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
