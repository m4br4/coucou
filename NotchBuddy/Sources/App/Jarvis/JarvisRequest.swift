#if !APPSTORE
import Foundation

// MARK: - JarvisRequest
//
// What HQ may ask Jarvis.app over aprobar.sock (JV-13): the line it sends, the answer, and
// when a card may open. A request authorizes nothing: it only asks for a card the app already
// knows how to show, and takes no title and no patterns. Abraham decides on the card. Pure
// Foundation: compiled into tests/JarvisApprovalsTests.swift.
enum JarvisRequest {
    enum Parsed: Equatable {
        case estado
        case solicitar(id: String, huella: String)
        /// Well formed, but the id or the huella is not: the caller gets `formato`.
        case formato
        /// Unknown field or operation, another `v`, not JSON: closed without a word.
        case close
    }

    enum Failure: String, Error {
        case formato
        case noExiste = "no-existe"
        case huella
        case yaDecidido = "ya-decidido"
        case sinPermite = "sin-permite"
        case ocupado
        case espera
        case limite
    }

    static let maxLine = 1024
    private static let huellaPattern = #"^[0-9a-f]{64}\z"#

    /// One line, without its \n.
    static func parse(_ line: Data) -> Parsed {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              isOne(json["v"]), let op = json["op"] as? String else { return .close }
        let fields = Set(json.keys)
        switch op {
        case "estado":
            return fields == ["v", "op"] ? .estado : .close
        case "solicitar":
            guard fields.isSubset(of: ["v", "op", "id", "huella"]) else { return .close }
            guard let id = json["id"] as? String, JarvisApprovals.isValidId(id),
                  let huella = json["huella"] as? String,
                  huella.range(of: huellaPattern, options: .regularExpression) != nil else { return .formato }
            return .solicitar(id: id, huella: huella)
        default:
            return .close
        }
    }

    /// The integer 1: not `true`, not 1.0, which JSONSerialization also reads as numbers.
    private static func isOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(number) && number.intValue == 1
    }

    // MARK: Answers

    static func stateReply(watching: Bool) -> String { "{\"v\":1,\"ok\":\(watching)}\n" }
    static let opened = "{\"v\":1,\"ok\":true,\"estado\":\"en-tarjeta\"}\n"
    static func reply(_ failure: Failure) -> String { "{\"v\":1,\"ok\":false,\"error\":\"\(failure.rawValue)\"}\n" }

    // MARK: Limits (in memory)

    /// How many cards a source may open. The socket and FSEvents have one each, so filling one
    /// doesn't turn off the other; «Ver aprobaciones» has none. An id has its own, lower limit:
    /// asking for the same report over and over doesn't use up the rest.
    struct Limiter {
        static let spacing: TimeInterval = 30
        static let hour: TimeInterval = 3600
        static let perHour = 10
        static let perHourForOneId = 3

        private var opens: [(at: Date, id: String)] = []

        /// When this id may open a card, nil if it may now.
        mutating func wait(for id: String, now: Date) -> Date? {
            opens.removeAll { now.timeIntervalSince($0.at) >= Self.hour }
            var until: Date?
            func later(_ date: Date) { until = max(until ?? date, date) }
            if let last = opens.last, now.timeIntervalSince(last.at) < Self.spacing {
                later(last.at.addingTimeInterval(Self.spacing))
            }
            if opens.count >= Self.perHour { later(opens[opens.count - Self.perHour].at.addingTimeInterval(Self.hour)) }
            let same = opens.filter { $0.id == id }
            if same.count >= Self.perHourForOneId {
                later(same[same.count - Self.perHourForOneId].at.addingTimeInterval(Self.hour))
            }
            return until
        }

        mutating func record(_ id: String, now: Date) { opens.append((now, id)) }
    }

    /// A report Abraham put away with Luego or by closing: not asked again for 10 minutes.
    struct Cooldown {
        static let duration: TimeInterval = 600

        private var until: [String: Date] = [:]

        mutating func add(id: String, huella: String, now: Date) {
            until = until.filter { $0.value > now }
            until["\(id) \(huella)"] = now.addingTimeInterval(Self.duration)
        }

        func isWaiting(id: String, huella: String, now: Date) -> Bool {
            (until["\(id) \(huella)"] ?? .distantPast) > now
        }
    }

    // MARK: Deciding

    /// The report asked for: same id and all 64 characters of the huella. Two files can share an
    /// id; the title and the patterns on the card are this file's. A decided id wins over the
    /// rest, so a report just rejected is `ya-decidido`, not `espera`.
    static func find(_ reports: [JarvisApprovals.Report], id: String, huella: String) -> Result<JarvisApprovals.Report, Failure> {
        let sameId = reports.filter { $0.id == id }
        guard !sameId.isEmpty else { return .failure(.noExiste) }
        guard sameId.allSatisfy({ $0.decision == .pendiente }) else { return .failure(.yaDecidido) }
        guard let report = sameId.first(where: { $0.huella == huella }) else { return .failure(.huella) }
        return report.permiteIsValid ? .success(report) : .failure(.sinPermite)
    }

    /// May this request open a card now? Records nothing.
    static func admit(_ reports: [JarvisApprovals.Report], id: String, huella: String, busy: Bool,
                      cooldown: Cooldown, limiter: inout Limiter, now: Date) -> Result<JarvisApprovals.Report, Failure> {
        let found = find(reports, id: id, huella: huella)
        guard case .success = found else { return found }
        if busy { return .failure(.ocupado) }
        if cooldown.isWaiting(id: id, huella: huella, now: now) { return .failure(.espera) }
        if limiter.wait(for: id, now: now) != nil { return .failure(.limite) }
        return found
    }
}
#endif
