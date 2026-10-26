#if !APPSTORE
import Foundation

// MARK: - JarvisLink
//
// "Jarvis, …" (this fork): Coucou as the voice of Jarvis, Abraham's agent team, on this
// Mac only. Pure Foundation, no AppKit: compiled into the app and into
// tests/JarvisLinkTests.swift.
//
// - A status question runs `pnpm estado <brand> "<question>" --voz` in Jarvis/fabrica
//   (read-only); its ≤6 plain lines are read aloud as they are.
// - Anything else becomes one message for Michael (god) in the hive, in the exact format
//   HQ writes (Jarvis/hq/src/lib/server/chat.ts); his reply in hive/agents/god/hq-replies/
//   is read aloud if it comes within a minute.
// The question and the answers are never logged.
enum JarvisLink {
    static let defaultFabricaPath = "~/Code/personal/Jarvis/fabrica"
    static let defaultHivePath    = "~/Code/personal/harness-home/hive"
    static let messageMax  = 4000      // HQ's CHAT_MAX
    static let questionMax = 500
    static let replyMax    = 20_000    // HQ's REPLY_MAX
    static let spokenLineMax = 6

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: Status (pnpm estado --voz)

    enum EstadoOutcome: Equatable {
        case answer(String)       // the lines to read, already joined
        case unknownBrand         // exit 2: the brand is in no ficha
        case timedOut
        case failed(Int32)        // any other exit status
        case notRunnable          // pnpm missing or couldn't start
    }

    /// A brand as said ("HispanoHost", "social space"): letters, digits, spaces, . _ -,
    /// never a leading dash (it would read as an option).
    static func cleanBrand(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60, !t.hasPrefix("-"),
              t.range(of: #"^[\p{L}\p{N} ._-]+$"#, options: .regularExpression) != nil else { return nil }
        return t
    }

    /// The question on one line, without control characters or leading dashes.
    static func cleanQuestion(_ raw: String) -> String? {
        var t = (normalizeText(raw) ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        while t.hasPrefix("-") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= questionMax else { return nil }
        return t
    }

    static func estadoArguments(brand: String, question: String) -> [String] {
        ["-s", "estado", brand, question, "--voz"]
    }

    /// At most 6 non-empty lines, each ending with punctuation, so they are read as
    /// sentences once joined on one line.
    static func spokenLines(_ output: String) -> String {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(spokenLineMax)
            .map { line in
                guard let last = line.last, !".!?…:;".contains(last) else { return line }
                return line + "."
            }
            .joined(separator: " ")
    }

    /// Where pnpm usually lives; the app doesn't get the shell's PATH.
    static func pnpmExecutable(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        let fm = FileManager.default
        var candidates = [
            "\(home)/Library/pnpm/pnpm",
            "\(home)/.local/share/pnpm/pnpm",
            "/opt/homebrew/bin/pnpm",
            "/usr/local/bin/pnpm",
            "\(home)/.volta/bin/pnpm",
            "\(home)/.npm-global/bin/pnpm",
        ]
        // mise and nvm: one bin folder per Node version, newest first.
        for root in ["\(home)/.local/share/mise/installs/node", "\(home)/.nvm/versions/node"] {
            if let versions = try? fm.contentsOfDirectory(atPath: root) {
                let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                candidates += sorted.map { "\(root)/\($0)/bin/pnpm" }
            }
        }
        candidates.append("\(home)/.local/share/mise/shims/pnpm")
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs `executable arguments` in `directory`, gives up after `timeout`. Only stdout is
    /// kept; stderr (paths, stack traces) is dropped.
    static func runEstado(executable: String, arguments: [String], directory: URL,
                          timeout: TimeInterval) async -> EstadoOutcome {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin",
                           "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            env["NO_COLOR"] = "1"
            process.environment = env
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .notRunnable }

            // Terminating closes stdout, which ends the read below.
            let timer = TimeoutFlag()
            let work = DispatchWorkItem {
                if process.isRunning { timer.fire(); process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            work.cancel()

            if timer.fired { return .timedOut }
            switch process.terminationStatus {
            case 0:
                let text = spokenLines(String(decoding: data, as: UTF8.self))
                return text.isEmpty ? .failed(0) : .answer(text)
            case 2:  return .unknownBrand
            default: return .failed(process.terminationStatus)
            }
        }.value
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func fire() { lock.withLock { value = true } }
        var fired: Bool { lock.withLock { value } }
    }

    // MARK: Message for Michael (HQ format)

    struct HQMessage: Codable, Equatable {
        let id: String
        let conversation: String
        let in_reply_to: String?
        let from: String
        let to: String
        let act: String
        let subject: String
        let body: String
        let hops: Int
        let requires_reply: Bool
        let needs_human: Bool
        let created_at: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(in_reply_to, forKey: .in_reply_to)   // null, as HQ writes it
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(act, forKey: .act)
            try c.encode(subject, forKey: .subject)
            try c.encode(body, forKey: .body)
            try c.encode(hops, forKey: .hops)
            try c.encode(requires_reply, forKey: .requires_reply)
            try c.encode(needs_human, forKey: .needs_human)
            try c.encode(created_at, forKey: .created_at)
        }
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Same as HQ: 2026-10-26T04-15-50-843Z-hq-1a2b3c.
    static func messageId(now: Date, rand: String = randomHex(bytes: 3)) -> String {
        isoString(now).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-") + "-hq-\(rand)"
    }

    static let replyIdPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-hq-[0-9a-f]{6}$"#

    /// HQ's normalizeText: NFC, \n line ends, no control characters (but \n and \t), trimmed.
    /// nil when empty or longer than HQ accepts.
    static func normalizeText(_ raw: String) -> String? {
        let unified = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let kept = unified.unicodeScalars.filter { s in
            let v = s.value
            if v == 0x0A || v == 0x09 { return true }
            return !(v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029)
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= messageMax else { return nil }
        return text
    }

    static func buildMessage(text: String, now: Date, id: String) -> HQMessage {
        let oneLine = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return HQMessage(id: id, conversation: "hq-chat", in_reply_to: nil, from: "hq", to: "god",
                         act: "request", subject: "HQ: \(oneLine.prefix(60))", body: text, hops: 0,
                         requires_reply: true, needs_human: false, created_at: isoString(now))
    }

    static func encoded(_ msg: HQMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(msg) + Data("\n".utf8)
    }

    enum DeliveryError: Error { case noInbox, write(Int32), exists }

    /// Like HQ's deliverToGod: a dot temp file without .json in the same folder (nobody reads
    /// it half-written) → fsync → link to the final name (fails if it exists: never
    /// overwrites) → unlink the temp. Mode 600. Never creates folders in the hive.
    static func deliver(_ msg: HQMessage, inbox: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir), isDir.boolValue else {
            throw DeliveryError.noInbox
        }
        let data = try encoded(msg)
        let tmp = inbox.appendingPathComponent(".hq-tmp-\(randomHex(bytes: 6))").path
        let final = inbox.appendingPathComponent("\(msg.id).json").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DeliveryError.write(errno) }
        defer { unlink(tmp) }
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
        guard ok else { throw DeliveryError.write(failure) }
        chmod(tmp, 0o600)
        guard link(tmp, final) == 0 else {
            throw errno == EEXIST ? DeliveryError.exists : DeliveryError.write(errno)
        }
    }

    // MARK: Michael's reply

    /// HQ's readReply: id by pattern, no symlink, a regular file inside the folder, size
    /// capped. The "# Re: …" heading Michael puts first is dropped. nil when missing or empty.
    static func readReply(id: String, in dir: URL) -> String? {
        guard id.range(of: replyIdPattern, options: .regularExpression) != nil else { return nil }
        let root = dir.resolvingSymlinksInPath()
        let path = root.appendingPathComponent("\(id).md").path
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= replyMax,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"^# Re:.*\n+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Waits for the reply, polling once a second. A reply is taken once its size stopped
    /// changing between two looks, so a file still being written is not read half-way.
    static func waitForReply(id: String, in dir: URL, timeout: TimeInterval,
                             poll: TimeInterval = 1) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize: off_t = -1
        while Date() < deadline, !Task.isCancelled {
            var st = stat()
            let path = dir.resolvingSymlinksInPath().appendingPathComponent("\(id).md").path
            if lstat(path, &st) == 0 {
                if st.st_size == lastSize, let reply = readReply(id: id, in: dir) { return reply }
                lastSize = st.st_size
            }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return nil
    }

    /// A reply cut for the voice: the first sentences up to about `limit` characters.
    static func spokenReply(_ text: String, limit: Int = 600) -> (text: String, cut: Bool) {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return (flat, false) }
        let head = String(flat.prefix(limit))
        if let end = head.lastIndex(where: { ".!?…".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 3 {
            return (String(head[...end]), true)
        }
        return (head + "…", true)
    }
}
#endif
