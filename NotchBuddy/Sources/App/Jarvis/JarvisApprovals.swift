#if !APPSTORE
import Foundation

// MARK: - JarvisApprovals
//
// "Aprobaciones de Jarvis" (this fork): the reports Jarvis's agents leave in
// vault/informes/ with `estado: esperando-aprobacion`, approved or rejected from the
// notch. Coucou is Abraham's own process, not an agent session: it may write in
// vault/aprobaciones/, the agents may not. Pure Foundation, no AppKit: compiled into the
// app and into tests/JarvisApprovalsTests.swift.
//
// Same rules as HQ (Jarvis/hq/src/lib/server/approvals.ts): the APROBADO carries the
// frontmatter of vault/aprobaciones/README.md (tarea, accion, fecha, autorizado_por:
// Abraham, permite) with `permite:` copied from the report as is, never widened; files
// are written once (temp → fsync → link, mode 600) and never overwritten; each decision
// is logged in vault/informes/jarvis/aprobaciones-YYYY-MM-DD.md.
enum JarvisApprovals {
    static let defaultVaultPath = "~/Code/personal/Jarvis/vault"
    static let pendingState = "esperando-aprobacion"
    static let idPattern = #"^[A-Za-z0-9._-]{1,64}$"#
    static let maxPatterns = 20
    static let maxPatternLength = 300
    static let motivoMax = 2000

    struct Report: Equatable, Identifiable, Sendable {
        let id: String
        let titulo: String      // the report's "# " heading: the APROBADO's accion
        let informe: String     // path relative to the vault's parent (as HQ shows it)
        let permite: [String]   // the report's frontmatter, as is
        let decision: Decision

        /// Approvable as is: one to 20 patterns, none empty, too long or multi-line.
        var permiteIsValid: Bool { JarvisApprovals.permiteProblem(permite) == nil }
    }

    enum Decision: String, Sendable { case pendiente, aprobado, rechazado }

    enum Failure: Error, Equatable {
        case notPending          // gone, or already decided
        case changed             // the report changed since it was shown
        case invalidPermite(String)
        case exists(String)
        case write(Int32)
        case motivo
    }

    static func informesDir(_ vault: URL) -> URL { vault.appendingPathComponent("informes", isDirectory: true) }
    static func aprobacionesDir(_ vault: URL) -> URL { vault.appendingPathComponent("aprobaciones", isDirectory: true) }

    // MARK: Reading the reports

    /// HQ's parseFrontmatter: `key: value` lines between the first two `---`, trailing
    /// `# comments` dropped (after a list, only after its closing bracket).
    static func parseFrontmatter(_ md: String) -> (data: [String: String], body: String) {
        let text = md.replacingOccurrences(of: "\r\n", with: "\n")
        guard let block = text.range(of: #"^---\n([\s\S]*?)\n---\n?"#, options: .regularExpression) else {
            return ([:], text)
        }
        let inner = text[block].dropFirst(4).replacingOccurrences(of: #"\n---\n?$"#, with: "", options: .regularExpression)
        var data: [String: String] = [:]
        for line in inner.components(separatedBy: "\n") {
            guard let kv = line.range(of: #"^[A-Za-z_][\w-]*:"#, options: .regularExpression) else { continue }
            let key = String(line[kv].dropLast())
            var value = String(line[kv.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                value = value.replacingOccurrences(of: #"\]\s+#[^\]]*$"#, with: "]", options: .regularExpression)
            } else if !value.hasPrefix("\"") && !value.hasPrefix("'") {
                value = value.replacingOccurrences(of: #"\s+#.*$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            data[key] = value
        }
        return (data, String(text[block.upperBound...]))
    }

    /// `permite:` as a JSON list of strings; anything else is no list at all.
    static func parsePermite(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
    }

    /// Why this `permite:` can't be approved, or nil. The patterns themselves are checked by
    /// the hook (fullmatch, the empty string, the blacklist): an APROBADO it refuses opens nothing.
    static func permiteProblem(_ permite: [String]) -> String? {
        if permite.isEmpty { return "El informe no propone ningún permite." }
        if permite.count > maxPatterns { return "Más de \(maxPatterns) patrones." }
        for p in permite {
            if p.trimmingCharacters(in: .whitespaces).isEmpty { return "Hay un patrón vacío." }
            if p.count > maxPatternLength || hasControl(p) { return "Hay un patrón demasiado largo o con saltos de línea." }
            if hasInvisibleFormat(p) { return "Hay un patrón con caracteres invisibles." }
        }
        return nil
    }

    /// Invisible format characters (Unicode category Cf: zero-width spaces and joiners,
    /// bidi marks, embeddings and isolates, BOM…): a pattern that reads one way on screen
    /// and matches another.
    static func hasInvisibleFormat(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .format }
    }

    /// Approve stays off until every pattern was on screen: the list fits in its box, or it
    /// was scrolled to the end.
    static func canApprove(contentFits: Bool, reachedEnd: Bool) -> Bool {
        contentFits || reachedEnd
    }

    /// Every .md under informes/, skipping names starting with "." or "_" (templates, used
    /// files), names with control characters, and symlinks.
    static func reportFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [URL] = []
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasPrefix("_") && !hasControl(name) {
            let url = dir.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true { out += reportFiles(in: url) }
            else if values.isRegularFile == true, name.hasSuffix(".md") { out.append(url) }
        }
        return out
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func decision(for id: String, vault: URL) -> Decision {
        let dir = aprobacionesDir(vault)
        if exists(dir.appendingPathComponent("APROBADO-\(id).md"))
            || exists(dir.appendingPathComponent("_usado-APROBADO-\(id).md.txt")) { return .aprobado }
        if exists(dir.appendingPathComponent("RECHAZADO-\(id).md")) { return .rechazado }
        return .pendiente
    }

    /// The reports waiting for approval, newest first (HQ's listPending).
    static func listPending(vault: URL) -> [Report] {
        let base = vault.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        var out: [(Report, String)] = []
        for file in reportFiles(in: informesDir(vault)) {
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            let (fm, body) = parseFrontmatter(String(decoding: data, as: UTF8.self))
            guard fm["estado"] == pendingState else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let tarea = fm["tarea"] ?? ""
            let id = isValidId(tarea) ? tarea : name
            guard isValidId(id) else { continue }
            let heading = body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let path = file.resolvingSymlinksInPath().path
            let report = Report(id: id, titulo: heading.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                                informe: path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path,
                                permite: parsePermite(fm["permite"]), decision: decision(for: id, vault: vault))
            out.append((report, fm["fecha"] ?? ""))
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func isValidId(_ id: String) -> Bool { id.range(of: idPattern, options: .regularExpression) != nil }

    // MARK: Writing the decision

    /// HQ's yamlStr: no control characters, between JSON quotes (never opens another line).
    static func yamlString(_ s: String) -> String {
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            hasControl(String(scalar)) ? " " : scalar
        }))
        return jsonString(clean)
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// `permite:` the way HQ writes it (JSON.stringify): ["a","b"].
    static func permiteLine(_ permite: [String]) -> String {
        "[" + permite.map(jsonString).joined(separator: ",") + "]"
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")   // HQ: toISOString().slice(0, 10)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// The APROBADO, with exactly the README's frontmatter. Refused if `permite:` would show
    /// up on more than one line.
    static func approvalContent(_ report: Report, now: Date) throws -> String {
        if let problem = permiteProblem(report.permite) { throw Failure.invalidPermite(problem) }
        let content = "---\ntarea: \(yamlString(report.id))\naccion: \(yamlString(report.titulo))\nfecha: \(day(now))\n"
            + "autorizado_por: Abraham\npermite: \(permiteLine(report.permite))\n---\n"
            + "Aprobado desde Coucou con Touch ID o la contraseña del Mac el \(iso(now)). Informe: \(report.informe.replacingOccurrences(of: "\n", with: " "))\n"
        guard content.components(separatedBy: "\n").filter({ $0.hasPrefix("permite:") }).count == 1 else {
            throw Failure.invalidPermite("El APROBADO generado no es válido.")
        }
        return content
    }

    /// The RECHAZADO, as HQ writes it, with the reason as the body.
    static func rejectionContent(_ report: Report, motivo: String, now: Date) -> String {
        "---\ntarea: \(yamlString(report.id))\naccion: \(yamlString(report.titulo))\nfecha: \(day(now))\n"
            + "rechazado_por: Abraham (desde Coucou)\ninforme: \(yamlString(report.informe))\n---\n\(motivo)\n"
    }

    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Temp file that doesn't look like APROBADO-*.md → fsync → link to the final name (fails
    /// if it exists: never overwrites) → unlink. Mode 600.
    static func writeOnce(_ content: String, named name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".hq-tmp-\(randomHex(bytes: 6))").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.write(errno) }
        defer { unlink(tmp) }
        let data = Data(content.utf8)
        var ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        let failure = errno
        close(fd)
        guard ok else { throw Failure.write(failure) }
        chmod(tmp, 0o600)
        guard link(tmp, dir.appendingPathComponent(name).path) == 0 else {
            throw errno == EEXIST ? Failure.exists(name) : Failure.write(errno)
        }
    }

    /// One line per decision in vault/informes/jarvis/aprobaciones-YYYY-MM-DD.md (HQ's log).
    static func logDecision(_ what: String, report: Report, detail: String, vault: URL, now: Date) {
        let dir = informesDir(vault).appendingPathComponent("jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("aprobaciones-\(day(now)).md")
        let header = exists(file) ? "" : "# Aprobaciones desde HQ — \(day(now))\n\n"
        let line = "\(header)- \(iso(now)) · \(what) (desde Coucou) · \(report.informe) · \(detail)\n"
        // Appended in one write (O_APPEND), like HQ's appendFile; best effort.
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Data(line.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    /// The report as it is now, if it is still the one that was shown and still pending.
    static func current(_ shown: Report, vault: URL) throws -> Report {
        guard let now = listPending(vault: vault).first(where: { $0.id == shown.id && $0.informe == shown.informe }),
              now.decision == .pendiente else { throw Failure.notPending }
        guard now.titulo == shown.titulo, now.permite == shown.permite else { throw Failure.changed }
        return now
    }

    /// Writes APROBADO-<id>.md. The caller has already checked the owner (LAContext).
    @discardableResult
    static func approve(_ shown: Report, vault: URL, now: Date = Date()) throws -> String {
        let report = try current(shown, vault: vault)
        let name = "APROBADO-\(report.id).md"
        try writeOnce(try approvalContent(report, now: now), named: name, in: aprobacionesDir(vault))
        logDecision("APROBADO \(report.id)", report: report, detail: "permite: \(permiteLine(report.permite))", vault: vault, now: now)
        return name
    }

    /// Writes RECHAZADO-<id>.md with the reason (at least 3 characters, like HQ).
    @discardableResult
    static func reject(_ shown: Report, motivo raw: String, vault: URL, now: Date = Date()) throws -> String {
        let motivo = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(motivoMax))
        guard motivo.count >= 3 else { throw Failure.motivo }
        let report = try current(shown, vault: vault)
        let name = "RECHAZADO-\(report.id).md"
        try writeOnce(rejectionContent(report, motivo: motivo, now: now), named: name, in: aprobacionesDir(vault))
        let flat = motivo.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        logDecision("RECHAZADO \(report.id)", report: report, detail: "motivo: \(flat)", vault: vault, now: now)
        return name
    }
}
#endif
