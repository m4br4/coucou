import Combine
import Foundation
import SwiftUI

// MARK: - JarvisApprovalStore tests
// The real store, FSEvents and socket. Fakes: AppState and what the card view draws with, and
// Touch ID, which only counts. Everything lives in a temporary HOME: no real vault, no real app.

enum IslandMode { case compact, expanded }
enum IslandView { case home, jarvisApprovals, claudeAlert }

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var mode = IslandMode.compact
    @Published var view = IslandView.home
    var pendingApproval: Int?
    var pendingQuestion: Int?
    var voiceMailDraft: Int?
    var voiceActive = false
}

extension Notification.Name {
    static let hookExpand = Notification.Name("test.hookExpand")
    static let jarvisCardSilently = Notification.Name("test.jarvisCardSilently")
    static let islandCollapse = Notification.Name("test.islandCollapse")
}

enum JarvisSettings { static var vaultPath: String { Store.vault.path } }
enum JarvisLink { static func expand(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) } }
func appendAppLog(_ file: String, _ message: String) {}

enum Wash { case amber }
struct CardBackground: View {
    let wash: Wash
    var body: some View { EmptyView() }
}
struct PrimaryButton: View {
    init(verbatim: String, action: @escaping () -> Void) {}
    var body: some View { EmptyView() }
}
struct SecondaryButton: View {
    init(verbatim: String, action: @escaping () -> Void) {}
    init(_ title: String, action: @escaping () -> Void) {}
    var body: some View { EmptyView() }
}
extension Color { init(hex: String) { self = .clear } }

enum Store {
    static var vault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("vault") }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    func add(_ reason: String) { lock.withLock { reasons.append(reason) } }
    var count: Int { lock.withLock { reasons.count } }
    var last: String? { lock.withLock { reasons.last } }
}

@main
enum JarvisStoreTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var total = 0

    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✓  \(label)") } else { print("✗  \(label) \(detail())"); failures += 1 }
    }

    /// Lets FSEvents, tasks and the card's observers run.
    static func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func report(_ tarea: String, body: String = "texto") -> String {
        "---\ntarea: \(tarea)\nestado: esperando-aprobacion\nfecha: 2026-11-05\npermite: [\"^a$\"]\n---\n# Título\n\(body)\n"
    }

    static func put(_ text: String, _ name: String) {
        let url = JarvisApprovals.informesDir(Store.vault).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: false, encoding: .utf8)
    }

    static func remove(_ name: String) {
        try! FileManager.default.removeItem(at: JarvisApprovals.informesDir(Store.vault).appendingPathComponent(name))
    }

    static var written: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: JarvisApprovals.aprobacionesDir(Store.vault).path)) ?? []
    }

    static func huella(_ id: String) -> String { JarvisApprovals.listPending(vault: Store.vault).first { $0.id == id }!.huella }

    /// What Abraham's click does, once the card has been on screen long enough.
    @MainActor static func clickApprove(_ report: JarvisApprovals.Report) {
        Task { await JarvisApprovalStore.shared.approve(report) }
        pump(0.3)
    }

    /// The real socket, from another thread: the main thread has to stay free for the store.
    static func ask(_ line: String, whileRunning body: () -> Void = { pump(0.5) }) -> String? {
        let answer = Answer()
        Thread.detachNewThread { answer.set(send(line)) }
        body()
        while !answer.ready { pump(0.05) }
        return answer.value
    }

    final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var text: String?
        func set(_ value: String?) { lock.withLock { text = value; done = true } }
        var ready: Bool { lock.withLock { done } }
        var value: String? { lock.withLock { text } }
    }

    static func send(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, c) in Array(JarvisApprovalSocket.defaultPath.utf8CString).enumerated() { raw[i] = UInt8(bitPattern: c) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? String(decoding: buffer[..<n], as: UTF8.self) : nil
    }

    static func request(_ id: String, _ huella: String) -> String {
        "{\"v\":1,\"op\":\"solicitar\",\"id\":\"\(id)\",\"huella\":\"\(huella)\"}\n"
    }

    @MainActor static func closeCard() {
        AppState.shared.mode = .compact
        AppState.shared.view = .home
        pump(0.2)
    }

    @MainActor static func run() {
        typealias R = JarvisRequest
        let store = JarvisApprovalStore.shared
        let state = AppState.shared
        let calls = Calls()
        store.confirmOwner = { calls.add($0); return true }
        // What IslandWindowController does with these.
        let open: (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                state.view = .jarvisApprovals
                state.mode = .expanded
                store.rearm()
            }
        }
        var opened = 0
        let center = NotificationCenter.default
        let tokens = [Notification.Name.hookExpand, .jarvisCardSilently].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                opened += 1
                open(note)
            }
        }
        defer { tokens.forEach(center.removeObserver) }

        put(report("A"), "a.md")
        put(report("E"), "e.md")
        store.start()
        pump(1.5)
        closeCard()
        check("the socket answers", send("{\"v\":1,\"op\":\"estado\"}\n") == R.stateReply(watching: true))

        // MARK: the report on the card is deleted
        opened = 0
        check("a request opens the card", ask(request("E", huella("E"))) == R.opened)
        check("on the report asked for", store.current?.id == "E")
        check("no Touch ID for a request", calls.count == 0)
        let shownE = store.current!
        remove("e.md")
        pump(2.5)
        check("deleted: the card doesn't move", store.current?.id == "E", store.current?.id ?? "nil")
        check("it says so", store.warning == "Ese informe ya no está.", store.warning ?? "nil")
        check("it stays held", store.isHoldingCard)
        check("Siguiente is there", store.canAdvance)
        clickApprove(shownE)
        check("Approve does nothing: no Touch ID", calls.count == 0, "\(calls.count)")
        check("and no file", written.isEmpty, "\(written)")
        put(report("N"), "n.md")
        pump(2.5)
        check("a new report doesn't move it either", store.current?.id == "E", store.current?.id ?? "nil")
        store.next()
        check("Siguiente moves on", store.current?.id != "E" && store.current != nil)
        check("and the warning goes", store.warning == nil, store.warning ?? "nil")
        store.later()
        closeCard()
        remove("n.md")
        pump(1.5)

        // MARK: the report on the card changes
        put(report("D"), "d.md")
        pump(1.5)
        closeCard()
        let asked = huella("D")
        pump(31)
        closeCard()   // the vault may have opened its own card meanwhile
        check("a request for D opens the card", ask(request("D", asked)) == R.opened)
        check("on D", store.current?.huella == asked)
        put(report("D", body: "otro cuerpo, mismo título y permite"), "d.md")
        pump(2.5)
        let changed = store.current
        check("the card shows the change", changed?.id == "D" && changed?.huella != asked, changed?.huella ?? "nil")
        check("title and patterns are the same", changed?.titulo == "Título" && changed?.permite == ["^a$"])
        check("it says to ask again", store.warning == "El informe cambió: pídelo otra vez desde HQ.", store.warning ?? "nil")
        pump(1.6)
        clickApprove(changed!)
        check("Approve does nothing: no Touch ID", calls.count == 0, "\(calls.count)")
        check("0 files written", written.isEmpty, "\(written)")
        store.later()
        closeCard()

        // MARK: control: with the same huella it does approve
        let now = huella("D")
        pump(31)
        closeCard()   // the vault may have opened its own card meanwhile
        check("a request for what is there now", ask(request("D", now)) == R.opened)
        clickApprove(store.current!)
        check("not within the 1.5 s", calls.count == 0, "\(calls.count)")
        pump(1.6)
        clickApprove(store.current!)
        check("Touch ID once, naming the code", calls.count == 1 && calls.last?.contains(JarvisApprovals.shortCode(now)) == true, calls.last ?? "nil")
        check("the APROBADO is written", written == ["APROBADO-D.md"], "\(written)")
        pump(1.5)
        check("decided: no warning about it", store.warning == nil, store.warning ?? "nil")
        check("and it is held no more", !store.isHoldingCard)
        store.later()
        closeCard()

        // MARK: a request given up on
        put(report("F"), "f.md")
        pump(1.5)
        closeCard()
        let f = huella("F")
        pump(31)
        closeCard()   // the vault may have opened its own card meanwhile
        opened = 0
        let t0 = Date()
        let late = ask(request("F", f)) { Thread.sleep(forTimeInterval: 2.5) }   // the main thread hangs
        check("the socket closes in time", late == nil && Date().timeIntervalSince(t0) < 3, late ?? "nil")
        pump(0.5)
        check("the card doesn't open late", opened == 0 && state.mode == .compact, "\(opened)")
        check("nothing held", !store.isHoldingCard)
        check("and it spent nothing: asking again works", ask(request("F", f)) == R.opened)

        // MARK: espera only if Abraham closed it
        state.view = .claudeAlert                     // a Claude notice takes the notch
        pump(0.3)
        check("another view lets the card go", !store.isHoldingCard)
        closeCard()
        check("no espera for that", ask(request("F", f)) == R.reply(.limite))
        pump(31)
        closeCard()   // the vault may have opened its own card meanwhile
        check("the request goes through", ask(request("F", f)) == R.opened)
        store.later()
        closeCard()
        check("Luego: espera", ask(request("F", f)) == R.reply(.espera))
        put(report("G"), "g.md")
        pump(1.5)
        closeCard()
        let g = huella("G")
        pump(31)
        closeCard()   // the vault may have opened its own card meanwhile
        check("a request for G", ask(request("G", g)) == R.opened)
        store.requestedCardClosed()                   // collapse(allowPendingApproval: true)
        closeCard()
        check("explicit collapse: espera", ask(request("G", g)) == R.reply(.espera))

        check("still no more files", written == ["APROBADO-D.md"], "\(written)")
        check("still one Touch ID", calls.count == 1, "\(calls.count)")
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        try? FileManager.default.createDirectory(at: Store.vault, withIntermediateDirectories: true)
        MainActor.assumeIsolated { run() }
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
