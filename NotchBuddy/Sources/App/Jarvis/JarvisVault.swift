#if !APPSTORE
import Foundation

// MARK: - JarvisVault
//
// The chat and the voice look in Jarvis's vault first: a message naming a brand, a client
// or a word like «auditoría» is answered from vault/informes/** and vault/conocimiento/**
// (plus `pnpm estado`), citing file and date. The code decides, not the model, so the
// answer can't go to the web by choice. Orders still go to Michael.
//
// Read-only on the vault: the index lives in Application Support, and nothing but the
// `.md` files of those two folders is indexed (never vault/aprobaciones/). Reports are
// written by agents and may quote web pages: what they say approves nothing and sends
// nothing. No AppKit: compiled into the app and into tests/JarvisVaultTests.swift.
enum JarvisVault {
    static let roots = ["informes", "conocimiento"]
    static let maxFileSize = 2_000_000
    static let maxDocs = 5000
    static let maxDepth = 8
    static let maxWords = 1500
    static let summaryLines = 3
    static let summaryLineMax = 240
    static let resultLimit = 3

    // MARK: Words

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es")).lowercased()
    }

    static func tokens(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// One form for singular and plural, on both sides of a comparison.
    static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// `space-technology` and `spacetechnology`, `Hispano Host` and `hispanohost`: the same.
    static func key(_ text: String) -> String { tokens(text).joined() }

    /// The words that send a message to the vault. Stems.
    static let keywords: Set<String> = ["auditoria", "seguridad", "rede", "informe", "reporte", "estado", "venta"]
    /// Too common to tell one report from another.
    static let genericWords: Set<String> = ["informe", "reporte", "estado"]
    /// Coucou reads these itself (service_info): «ventas de Stripe» is not a vault question.
    static let services: Set<String> = ["stripe", "github", "vercel", "resend", "n8n", "notion", "cal", "spotify", "claude", "codex"]
    /// A mail is drafted on the card, whoever it names.
    static let mailWords: Set<String> = ["correo", "email", "mail", "gmail"]
    static let fillers: Set<String> = ["jarvis", "oye", "hey", "ok", "okay", "hola", "porfa", "por", "favor"]

    static let orderVerbs: Set<String> = [
        "haz", "hazme", "hazle", "hagan", "pide", "pidele", "pideles", "pidan", "programa", "programame", "programen",
        "agenda", "agendame", "encarga", "encargale", "prepara", "preparame", "genera", "generame", "crea", "creame",
        "redacta", "publica", "lanza", "dile", "diles", "avisa", "avisale",
    ]
    static let orderInfinitives: Set<String> = [
        "hacer", "hacerme", "pedir", "pedirle", "pedirles", "programar", "agendar", "encargar", "encargarle", "preparar",
        "generar", "crear", "redactar", "publicar", "lanzar", "decirle", "avisar", "avisarle",
    ]
    static let stopWords: Set<String> = [
        "de", "del", "la", "el", "los", "las", "lo", "le", "les", "un", "una", "unos", "unas", "uno", "y", "e", "o", "u",
        "a", "al", "en", "con", "sin", "por", "para", "que", "como", "cual", "cuales", "cuando", "donde", "quien", "sobre",
        "se", "su", "sus", "mi", "mis", "me", "te", "tu", "es", "son", "era", "fue", "ha", "han", "hay", "esta", "este", "esto",
        "estan", "eso", "esa", "ese", "ya", "si", "no", "tiene", "tienen", "tengo", "tenemos", "dime", "dame", "muestrame",
        "ensename", "pasame", "busca", "buscame", "mira", "revisa", "ver", "leeme", "quiero", "saber", "sabes", "va", "van",
        "dice", "dicen", "decir", "relacionado", "relacionada", "relacionados", "relacionadas", "nuevo", "nueva", "nuevos",
        "nuevas", "ultimo", "ultima", "ultimos", "ultimas", "reciente", "recientes", "algo", "todo", "toda", "todos", "todas",
        "mas", "muy", "tal", "entonces", "pues", "hoy", "ayer", "jarvis", "oye", "hola", "porfa", "favor", "the", "what",
        "how", "of", "is", "and",
    ]

    // MARK: Brands and clients

    struct Brand: Equatable, Sendable {
        let name: String        // as `pnpm estado` and the user know it
        let keys: Set<String>
        var isMarca = true      // from informe-diario.json: a sister brand excludes its reports
    }

    /// The brands of informe-diario.json, the folders of vault/clientes (never `_plantilla`)
    /// and each `empresa` the reports name. `jarvis` is the wake word, not a brand.
    static func brands(vault: URL, docs: [Doc]) -> [Brand] {
        var list: [Brand] = []
        let daily = vault.appendingPathComponent("conocimiento/informe-diario.json")
        if let file = JarvisApprovals.readRegular(daily),
           let json = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any],
           let marcas = json["marcas"] as? [[String: Any]] {
            for marca in marcas {
                let slug = marca["slug"] as? String ?? ""
                let nombre = marca["nombre"] as? String ?? ""
                let dominio = marca["dominio"] as? String ?? ""
                let label = dominio.split(separator: ".").first.map(String.init) ?? ""
                let keys = Set([slug, nombre, label].map(key).filter { $0.count >= 3 })
                guard !keys.isEmpty else { continue }
                list.append(Brand(name: nombre.isEmpty ? slug : nombre, keys: keys))
            }
        }
        var known = Set(list.flatMap(\.keys))
        let clientes = vault.appendingPathComponent("clientes")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: clientes.path)) ?? []).sorted()
        where !name.hasPrefix("_") && !name.hasPrefix(".") {
            var st = stat()
            let k = key(name)
            guard lstat(clientes.appendingPathComponent(name).path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  k.count >= 3, known.insert(k).inserted else { continue }
            list.append(Brand(name: name, keys: [k], isMarca: false))
        }
        for doc in docs {
            let k = key(doc.empresa)
            guard k.count >= 3, k != "jarvis", known.insert(k).inserted else { continue }
            list.append(Brand(name: doc.empresa, keys: [k], isMarca: false))
        }
        return list
    }

    /// The brand the message names, by whole words: "Hispano Host" and "hispanohost.net" count,
    /// "parte" doesn't name a brand called "arte". The longest match wins.
    static func mentioned(in text: String, brands: [Brand]) -> Brand? {
        let words = tokens(text)
        for size in stride(from: 4, through: 1, by: -1) where words.count >= size {
            for start in 0...(words.count - size) {
                let joined = words[start..<(start + size)].joined()
                if let brand = brands.first(where: { $0.keys.contains(joined) }) { return brand }
            }
        }
        return nil
    }

    // MARK: Routing

    enum Route: Equatable {
        case normal             // not for the vault: the usual chat or voice turn
        case vault(Brand?)
        case order              // for Michael's inbox
    }

    /// An order starts with its verb: «Programa un post…», «Oye, pídele a…», «¿Puedes
    /// pedirle…?», «¿Me puedes hacer…?», «Quiero que…». «¿Qué programa usa…?» is a question.
    static func isOrder(_ text: String) -> Bool {
        var words = tokens(text)[...]
        while let first = words.first, fillers.contains(first) { words = words.dropFirst() }
        if words.first == "me", ["puedes", "podrias"].contains(words.dropFirst().first ?? "") { words = words.dropFirst() }
        guard let first = words.first else { return false }
        let second = words.dropFirst().first
        if ["puedes", "podrias", "pueden", "podrian"].contains(first) {
            let next = second == "me" || second == "le" ? words.dropFirst(2).first : second
            return next.map(orderInfinitives.contains) ?? false
        }
        if ["quiero", "necesito"].contains(first) { return second == "que" }
        return orderVerbs.contains(first) && !text.contains("?")
    }

    /// `awaitingAnswer`: the assistant just asked something (a mail's subject, say) and this
    /// is the answer, whatever words it uses.
    static func route(_ text: String, brands: [Brand], awaitingAnswer: Bool = false) -> Route {
        guard !awaitingAnswer else { return .normal }
        let words = tokens(text)
        guard mailWords.isDisjoint(with: words) else { return .normal }
        let brand = mentioned(in: text, brands: brands)
        let keyword = !keywords.isDisjoint(with: words.map(stem))
        if isOrder(text) { return brand != nil || keyword || words.contains("michael") ? .order : .normal }
        if let brand { return .vault(brand) }
        guard keyword, services.isDisjoint(with: words) else { return .normal }
        return .vault(nil)
    }

    /// True when the last thing said in `messages` is a question.
    static func asksBack(_ messages: [[String: Any]]) -> Bool {
        guard let last = messages.last, last["role"] as? String == "assistant" else { return false }
        let text: String?
        if let blocks = last["content"] as? [[String: Any]] {
            text = blocks.last { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = last["content"] as? String
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ?? false
    }

    // MARK: Index

    struct Doc: Codable, Equatable, Sendable {
        let path: String            // relative to the vault: informes/radar/…/informe.md
        let modified: Double
        let size: Int
        let empresa: String
        let departamento: String
        let fecha: String           // yyyy-MM-dd, or empty
        let titulo: String
        let resumen: [String]
        let words: [String]         // stems of the whole report

        var fileStem: String {
            ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    struct Index: Codable, Equatable, Sendable {
        static let currentVersion = 1
        var version = Index.currentVersion
        var vault = ""
        var docs: [Doc] = []
    }

    private static func unquoted(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespaces))
    }

    private static func isoDay(_ text: String) -> String? {
        guard let range = text.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        let day = String(text[range])
        return monthIndex(day) == nil ? nil : day
    }

    private static func monthIndex(_ day: String) -> Int? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return month - 1
    }

    /// The first heading of the body, or the file's name: the vault has no title key.
    static func title(body: String, fileStem: String) -> String {
        for line in body.components(separatedBy: "\n") where line.hasPrefix("# ") {
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return fileStem
    }

    private static func cleaned(_ line: String) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^([-*+>]|\d+\.)\s+"#, with: "", options: .regularExpression)
        return text.count > summaryLineMax ? String(text.prefix(summaryLineMax)) + "…" : text
    }

    /// The `## Resumen…` section when there is one; if not, the first lines of plain text.
    static func summary(body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        func isHeading(_ line: String) -> Bool { line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil }
        func usable(_ part: ArraySlice<String>) -> [String] {
            var fenced = false
            var kept: [String] = []
            for line in part {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("```") { fenced.toggle(); continue }
                if fenced || t.isEmpty || isHeading(t) || t.hasPrefix("|") || t.hasPrefix("---") { continue }
                let text = cleaned(t)
                if !text.isEmpty { kept.append(text) }
                if kept.count == summaryLines { break }
            }
            return kept
        }
        if let start = lines.firstIndex(where: { isHeading($0) && fold($0).contains("resumen") }) {
            let rest = lines[(start + 1)...]
            let end = rest.firstIndex(where: isHeading) ?? rest.endIndex
            let section = usable(rest[..<end])
            if !section.isEmpty { return section }
        }
        return usable(lines[...])
    }

    static func parse(path: String, data: Data, modified: Double) -> Doc {
        let (front, body) = JarvisApprovals.parseFrontmatter(String(decoding: data, as: UTF8.self))
        let parts = path.components(separatedBy: "/")
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var fecha = ""
        for candidate in [front["fecha"], front["medido"], front["actualizado"]] {
            if let day = isoDay(unquoted(candidate)) { fecha = day; break }
        }
        if fecha.isEmpty { fecha = parts.reversed().lazy.compactMap(isoDay).first ?? "" }
        var departamento = unquoted(front["departamento"])
        if departamento.isEmpty, parts.count >= 3, parts[0] == "informes" { departamento = parts[1] }
        let stems = Set(tokens(body + " " + unquoted(front["tipo"]) + " " + unquoted(front["tema"])).map(stem))
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Doc(path: path, modified: modified, size: data.count, empresa: unquoted(front["empresa"]),
                   departamento: departamento, fecha: fecha, titulo: title(body: body, fileStem: fileName),
                   resumen: summary(body: body), words: Array(stems.sorted().prefix(maxWords)))
    }

    /// Walks the two folders without following links. Files whose date and size didn't change
    /// are kept from `previous`, unread.
    static func scan(vault: URL, previous: Index) -> Index {
        let known = previous.vault == vault.path ? Dictionary(previous.docs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        var docs: [Doc] = []

        func walk(_ dir: URL, _ relative: String, _ depth: Int) {
            guard depth <= maxDepth, docs.count < maxDocs else { return }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            where !name.hasPrefix(".") && docs.count < maxDocs {
                let url = dir.appendingPathComponent(name)
                let path = "\(relative)/\(name)"
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    walk(url, path, depth + 1)
                case S_IFREG where name.lowercased().hasSuffix(".md") && st.st_size <= maxFileSize:
                    let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                    if let doc = known[path], doc.modified == modified, doc.size == Int(st.st_size) {
                        docs.append(doc)
                    } else if let file = JarvisApprovals.readRegular(url), file.data.count <= maxFileSize {
                        docs.append(parse(path: path, data: file.data, modified: modified))
                    }
                default:
                    continue
                }
            }
        }

        for root in roots {
            let url = vault.appendingPathComponent(root, isDirectory: true)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            walk(url, root, 0)
        }
        return Index(vault: vault.path, docs: docs)
    }

    // MARK: Search

    struct Hit: Equatable, Sendable {
        let doc: Doc
        let score: Int
    }

    /// The `limit` reports that best answer `question`. A named brand brings its reports, but
    /// never only them: the security inventory is filed under `space-technology`, so the words
    /// count on their own and each pick prefers a word nothing picked yet covers. Without a
    /// brand, a word the vault doesn't know («la auditoría de Acme») means it isn't there.
    static func search(_ question: String, brand: Brand?, brands: [Brand], docs: [Doc], limit: Int = resultLimit) -> [Hit] {
        let brandWords = Set(brand?.keys ?? [])
        var terms = Set(tokens(question).map(stem)).filter { $0.count >= 3 && !stopWords.contains($0) && !brandWords.contains($0) }
        if let brand {
            // "Hispano Host" said in two words: neither is a term to look for.
            let words = tokens(question)
            for size in 2...4 where words.count >= size {
                for start in 0...(words.count - size) where brand.keys.contains(words[start..<(start + size)].joined()) {
                    terms.subtract(words[start..<(start + size)].map(stem))
                }
            }
        }
        let specific = terms.subtracting(keywords)
        let sisters = brand == nil ? [] : Set(brands.filter { $0.isMarca && $0 != brand }.flatMap(\.keys))

        struct Candidate { let hit: Hit; let strong: Set<String> }
        var pool: [Candidate] = []
        for doc in docs {
            let empresa = key(doc.empresa)
            let isBrandDoc = brand.map { b in
                b.keys.contains(empresa) || !b.keys.isDisjoint(with: tokens(doc.titulo + " " + doc.path))
            } ?? false
            if !isBrandDoc, sisters.contains(empresa) { continue }

            let inDepartment = Set(tokens(doc.departamento).map(stem))
            let inTitle = Set(tokens(doc.titulo).map(stem))
            let inPath = Set(tokens(doc.path).map(stem))
            let inBody = Set(doc.words)
            let covered = terms.filter { inDepartment.contains($0) || inTitle.contains($0) || inPath.contains($0) || inBody.contains($0) }
            let telling = covered.subtracting(genericWords)
            if brand == nil {
                guard !covered.isEmpty else { continue }
                if !specific.isEmpty, specific.isDisjoint(with: covered) { continue }
            } else if !isBrandDoc, telling.isEmpty {
                continue
            }
            var score = isBrandDoc ? 3 : 0
            var strong = Set<String>()
            for term in covered {
                if genericWords.contains(term) { score += 1; continue }
                if inDepartment.contains(term) { score += 6; strong.insert(term) }
                if inTitle.contains(term) { score += 5; strong.insert(term) }
                if inPath.contains(term) { score += 3; strong.insert(term) }
                if inBody.contains(term) { score += 1 }
            }
            pool.append(Candidate(hit: Hit(doc: doc, score: score), strong: strong))
        }
        pool.sort {
            ($0.hit.score, $0.hit.doc.fecha, $1.hit.doc.path) > ($1.hit.score, $1.hit.doc.fecha, $0.hit.doc.path)
        }

        var picked: [Hit] = []
        var uncovered = terms.subtracting(genericWords)
        while picked.count < limit, !pool.isEmpty {
            let next = pool.firstIndex { !$0.strong.isDisjoint(with: uncovered) } ?? 0
            let candidate = pool.remove(at: next)
            picked.append(candidate.hit)
            uncovered.subtract(candidate.strong)
        }
        return picked
    }

    // MARK: Answer

    private static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                                 "septiembre", "octubre", "noviembre", "diciembre"]

    /// 2026-10-25 → 25-oct.
    static func shortDate(_ day: String) -> String {
        guard let month = monthIndex(day), let number = Int(day.split(separator: "-")[2]) else { return "sin fecha" }
        return "\(number)-\(months[month].prefix(3))"
    }

    /// 2026-10-25 → 25 de octubre.
    static func longDate(_ day: String) -> String {
        guard let month = monthIndex(day), let number = Int(day.split(separator: "-")[2]) else { return "sin fecha" }
        return "\(number) de \(months[month])"
    }

    static func isoDay(of date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// What the screen shows: each report with its file and date, then `pnpm estado`.
    static func shown(hits: [Hit], estado: String?, today: Date, vaultName: String, markdown: Bool) -> String {
        func code(_ text: String) -> String { markdown ? "`\(text)`" : text }
        var parts = hits.map { hit -> String in
            let doc = hit.doc
            let title = markdown ? "**\(doc.titulo)**" : doc.titulo
            let head = "Según \(code("\(vaultName)/\(doc.path)")), \(shortDate(doc.fecha)): \(title)"
            return ([head] + doc.resumen).joined(separator: "\n")
        }
        if let estado { parts.append("Según \(code("pnpm estado")), \(shortDate(isoDay(of: today))): \(estado)") }
        return parts.joined(separator: "\n\n")
    }

    /// What is read aloud: a file path isn't, its title and date are.
    static func spoken(hits: [Hit], estado: String?) -> String {
        var parts = hits.map { hit -> String in
            let doc = hit.doc
            let named = doc.titulo == doc.fileStem && !doc.departamento.isEmpty ? "el informe de \(doc.departamento)" : doc.titulo
            let line = doc.resumen.first.map { ": \($0)" } ?? ""
            let text = "Según \(named), \(longDate(doc.fecha))\(line)"
            return text.hasSuffix(".") ? text : text + "."
        }
        if let estado { parts.append("Estado: \(estado)") }
        return parts.joined(separator: " ")
    }

    /// Said before an answer that didn't come from the vault.
    static func missNotice(usedWeb: Bool) -> String {
        usedWeb ? "No hay nada de esto en el vault; lo busqué en la web." : "No hay nada de esto en el vault."
    }

    static let webHint = " The vault has nothing on this question: use web_search for it."

    static func usedWeb(_ content: [[String: Any]]) -> Bool {
        content.contains { $0["type"] as? String == "web_search_tool_result" }
    }

    // MARK: Turn

    enum Turn: Equatable {
        case pass(miss: Bool)       // the usual turn; `miss`: the vault was asked and has nothing
        case answered(shown: String, spoken: String, fromVault: Bool)
    }

    struct Deps: Sendable {
        var vaultName: String
        var brands: @Sendable () async -> [Brand]?      // nil: no vault here
        var search: @Sendable (String, Brand?, [Brand]) async -> [Hit]
        var estado: @Sendable (String, String) async -> String?
        var send: @Sendable (String) async -> (shown: String, spoken: String)
    }

    /// One message, from either side. Nothing here reaches a model: the words of an order go
    /// to Michael as they were said or typed.
    static func turn(_ text: String, awaitingAnswer: Bool, markdown: Bool, today: Date = Date(), deps: Deps) async -> Turn {
        guard let brands = await deps.brands() else { return .pass(miss: false) }
        switch route(text, brands: brands, awaitingAnswer: awaitingAnswer) {
        case .normal:
            return .pass(miss: false)
        case .order:
            let (shown, spoken) = await deps.send(text)
            return .answered(shown: shown, spoken: spoken, fromVault: false)
        case .vault(let brand):
            async let status: String? = brand == nil ? nil : deps.estado(brand!.name, text)
            let hits = await deps.search(text, brand, brands)
            let estado = await status
            guard !hits.isEmpty || estado != nil else { return .pass(miss: true) }
            return .answered(shown: shown(hits: hits, estado: estado, today: today, vaultName: deps.vaultName, markdown: markdown),
                             spoken: spoken(hits: hits, estado: estado), fromVault: !hits.isEmpty)
        }
    }
}

// MARK: - JarvisVaultStore

/// The index, in memory and on disk, off the main thread. Refreshed on each search: a walk of
/// file dates, reading only what changed, so a new report counts at once and nothing runs
/// while nobody asks (no watcher, 0 % CPU when the island is hidden).
actor JarvisVaultStore {
    static let shared = JarvisVaultStore(file: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchBuddy/Jarvis/vault-index.json"))

    private let file: URL
    private var index: JarvisVault.Index?

    init(file: URL) { self.file = file }

    private func loaded() -> JarvisVault.Index {
        if let index { return index }
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(JarvisVault.Index.self, from: data),
              saved.version == JarvisVault.Index.currentVersion else { return JarvisVault.Index() }
        return saved
    }

    private func refreshed(vault: URL) -> JarvisVault.Index {
        let previous = loaded()
        let fresh = JarvisVault.scan(vault: vault, previous: previous)
        index = fresh
        if fresh != previous { save(fresh, vault: vault) }
        return fresh
    }

    /// The real path of what exists of `url`, plus the rest: the folder of a first save
    /// doesn't exist yet, and /tmp must still compare equal to /private/tmp.
    private func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/" {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + rest.reversed()).joined(separator: "/")
            }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return "/" + rest.reversed().joined(separator: "/")
    }

    /// Mode 600, through a temp file. Never inside the vault.
    private func save(_ index: JarvisVault.Index, vault: URL) {
        let folder = file.deletingLastPathComponent()
        guard !(realPath(folder) + "/").hasPrefix(realPath(vault) + "/"),
              (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(index) else { return }
        let tmp = folder.appendingPathComponent(".vault-index-\(UUID().uuidString)").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let written = (try? handle.write(contentsOf: data)) != nil
        if !written || rename(tmp, file.path) != 0 { unlink(tmp) }
    }

    /// nil when the vault isn't there. The index is walked only the first time: a message
    /// that turns out not to be for the vault costs one small file and one folder listing.
    func brands(vault: URL) -> [JarvisVault.Brand]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return JarvisVault.brands(vault: vault, docs: (index ?? refreshed(vault: vault)).docs)
    }

    func search(_ question: String, brand: JarvisVault.Brand?, brands: [JarvisVault.Brand], vault: URL) -> [JarvisVault.Hit] {
        JarvisVault.search(question, brand: brand, brands: brands, docs: refreshed(vault: vault).docs)
    }
}
#endif
