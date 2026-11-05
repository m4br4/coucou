#if !APPSTORE
import Combine
import CoreServices
import LocalAuthentication
import os
import SwiftUI

// MARK: - JarvisApprovalStore
//
// Watches the vault (FSEvents, nothing runs between changes) and keeps the reports
// waiting for approval. A new one opens the "Aprobaciones de Jarvis" card in the notch
// when nothing else waits there, up to a limit. HQ can ask for the card too (aprobar.sock,
// JV-13). Approving asks for Touch ID (or the Mac's password) first, then writes
// vault/aprobaciones/APROBADO-<id>.md; rejecting writes RECHAZADO-<id>.md with the reason.
// Nothing is written without a click. An open card never moves to another report by itself.
@MainActor
final class JarvisApprovalStore: ObservableObject {
    static let shared = JarvisApprovalStore()

    @Published private(set) var pending: [JarvisApprovals.Report] = []
    @Published var index = 0
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    /// When Approve may take a click again: JarvisApprovals.armDelay after the card last changed.
    @Published private(set) var shownAt = Date.distantPast
    /// The report on the card, once it left the list. The card stays on it, unable to approve,
    /// until Siguiente: nobody chooses what comes up under the pointer by deleting a file.
    @Published private(set) var missing: JarvisApprovals.Report?
    /// The report HQ asked for, while its card is out: it stays open until Abraham closes it.
    @Published private(set) var requested: JarvisApprovals.Report?

    private var stream: FSEventStreamRef?
    private var watched: String?
    private var seen: Set<String> = []
    private var rescanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var server: JarvisApprovalSocket?
    private var observers = Set<AnyCancellable>()

    private var vaultLimiter = JarvisRequest.Limiter()
    private var socketLimiter = JarvisRequest.Limiter()
    private var cooldown = JarvisRequest.Cooldown()
    private var requestedCardAppeared = false
    /// Decided here: its leaving the list is no surprise.
    private var settled: String?

    /// The socket's threads read it without hopping to the main thread.
    nonisolated private static let watching = OSAllocatedUnfairLock(initialState: false)

    var isHoldingCard: Bool { requested != nil }

    #if JARVIS_STORE_TESTS
    /// Stands in for Touch ID in scripts/test-jarvis-store.sh, the only build with this flag:
    /// the app has nothing to replace.
    var confirmOwner: @Sendable (String) async -> Bool = { _ in false }
    #endif

    var vault: URL { JarvisLink.expand(JarvisSettings.vaultPath) }
    var current: JarvisApprovals.Report? { missing ?? (pending.indices.contains(index) ? pending[index] : pending.first) }

    /// Why Approve stays off, whatever was seen.
    var warning: String? {
        if missing != nil { return "Ese informe ya no está." }
        if !JarvisApprovals.requestAllows(requested: requested, current: current) {
            return "El informe cambió: pídelo otra vez desde HQ."
        }
        return nil
    }

    var canAdvance: Bool { missing == nil ? pending.count > 1 : !pending.isEmpty }

    func start() {
        observeCard()
        startSocket()   // without a vault it still answers, with ok:false: HQ says why
        let path = vault.path
        guard watched != path else { return }
        stop()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            log("vault not found, approvals off")
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<JarvisApprovalStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.rescan() }   // the stream runs on the main queue
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        else { log("couldn't watch the vault"); return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        watched = path
        Self.watching.withLock { $0 = true }
        log("watching the vault")
        rescan()
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        watched = nil
        Self.watching.withLock { $0 = false }
        pending = []
    }

    func rescan() {
        rescanTask?.cancel()
        let vault = vault
        rescanTask = Task { [weak self] in
            let list = await Task.detached { JarvisApprovals.listPending(vault: vault).filter { $0.decision == .pendiente } }.value
            guard !Task.isCancelled, let self else { return }
            let shown = self.current
            self.pending = list
            if let position = list.firstIndex(where: { $0.key == shown?.key }) {
                self.index = position
                self.missing = nil
                if list[position].huella != shown?.huella { self.status = "El informe cambió: revísalo otra vez." }
            } else if let shown, self.isCardOpen, shown.key != self.settled {
                self.missing = shown
            } else {
                self.index = 0
                self.missing = nil
                self.settled = nil
            }
            // A new report opens the card once; while the notch is busy it waits for the next look.
            // An open card stays on its report: the new one shows up in the count.
            let fresh = list.filter { !self.seen.contains($0.key) }
            guard let first = fresh.first, !self.isCardOpen, self.islandFree else { return }
            let now = Date()
            if let wait = self.vaultLimiter.wait(for: first.id, now: now) {
                self.rescanAt(wait)
                return
            }
            self.vaultLimiter.record(first.id, now: now)
            self.seen.formUnion(list.map(\.key))
            self.index = list.firstIndex(of: first) ?? 0
            self.status = nil
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.jarvisApprovals)
        }
    }

    /// A report held back by the limit has no event left to bring it back.
    private func rescanAt(_ date: Date) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    /// Opens the card on demand (Settings → Voz → Jarvis).
    func show() {
        status = pending.isEmpty ? "No hay nada esperando aprobación." : nil
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.jarvisApprovals)
    }

    private var islandFree: Bool {
        let s = AppState.shared
        return s.pendingApproval == nil && s.pendingQuestion == nil
            && !(s.mode == .expanded && s.view != .jarvisApprovals)
    }

    private var isCardOpen: Bool {
        AppState.shared.mode == .expanded && AppState.shared.view == .jarvisApprovals
    }

    /// For a request: nothing at all in the notch, this card and a voice turn included.
    private var notchIsEmpty: Bool {
        let s = AppState.shared
        return s.pendingApproval == nil && s.pendingQuestion == nil && s.voiceMailDraft == nil
            && !s.voiceActive && s.mode != .expanded
    }

    // MARK: Requests from HQ (aprobar.sock)

    private func startSocket() {
        guard server == nil else { return }
        let socket = JarvisApprovalSocket(answer: Self.answer)
        do {
            try socket.start()
            server = socket
            log("socket ready")
        } catch {
            log("socket off: \(error)")
        }
    }

    /// On the connection's thread. nil closes without a word: an invalid request shows nothing.
    nonisolated private static func answer(_ line: Data) -> String? {
        switch JarvisRequest.parse(line) {
        case .close:   return nil
        case .formato: return JarvisRequest.reply(.formato)
        case .estado:  return JarvisRequest.stateReply(watching: watching.withLock { $0 })
        case .solicitar(let id, let huella):
            let done = DispatchSemaphore(value: 0)
            let reply = OSAllocatedUnfairLock<String?>(initialState: nil)
            let ticket = JarvisRequest.Ticket()
            Task { @MainActor in
                let text = await JarvisApprovalStore.shared.open(id: id, huella: huella, ticket: ticket)
                reply.withLock { $0 = text }
                done.signal()
            }
            // Within the 2 s HQ waits.
            if done.wait(timeout: .now() + 1.8) != .success {
                if ticket.abandon() { return nil }
                done.wait()
            }
            return reply.withLock { $0 }
        }
    }

    /// Always from disk: `pending` may be a second old. No sound and no notification, and Touch
    /// ID only comes with the click on Approve.
    private func open(id: String, huella: String, ticket: JarvisRequest.Ticket) async -> String? {
        let vault = vault
        let list = await Task.detached { JarvisApprovals.listPending(vault: vault) }.value
        let now = Date()
        switch JarvisRequest.admit(list, id: id, huella: huella, busy: !notchIsEmpty, cooldown: cooldown,
                                   limiter: &socketLimiter, now: now) {
        case .failure(let failure):
            return JarvisRequest.reply(failure)
        case .success(let report):
            guard ticket.take() else { return nil }
            socketLimiter.record(id, now: now)
            pending = list.filter { $0.decision == .pendiente }
            index = pending.firstIndex(of: report) ?? 0
            missing = nil
            seen.insert(report.key)
            status = nil
            requested = report
            requestedCardAppeared = false
            log("card opened for \(report.id) on request")
            NotificationCenter.default.post(name: .jarvisCardSilently, object: nil)
            return JarvisRequest.opened
        }
    }

    /// Abraham put the requested card away: Luego, or an explicit collapse. Only then `espera`:
    /// not for a card that folded by itself, which is why it is held open, nor for one that
    /// another view took over.
    func requestedCardClosed() {
        guard let report = requested else { return }
        cooldown.add(id: report.id, huella: report.huella, now: Date())
        requested = nil
    }

    private func observeCard() {
        guard observers.isEmpty else { return }
        AppState.shared.$mode.combineLatest(AppState.shared.$view)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, view in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if mode == .expanded && view == .jarvisApprovals {
                        if self.requested != nil { self.requestedCardAppeared = true }
                        return
                    }
                    self.missing = nil
                    if self.requestedCardAppeared { self.requested = nil }
                }
            }
            .store(in: &observers)
    }

    /// The card appeared or shows something else: Approve waits again.
    func rearm() { shownAt = Date() }

    func next() {
        guard !pending.isEmpty else { return }
        if missing != nil { missing = nil } else { index = (index + 1) % pending.count }
        status = nil
    }

    func later() {
        status = nil
        requestedCardClosed()
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: Decisions

    /// `seen`: the report whose whole permite list was on screen. Approved only while it is
    /// still the one shown (checked again after Touch ID: a rescan may land during the
    /// prompt); then JarvisApprovals.approve checks it against the file and writes `seen`'s
    /// own permite.
    func approve(_ seen: JarvisApprovals.Report) async {
        guard !busy, warning == nil, JarvisApprovals.isArmed(shownAt: shownAt, now: Date()) else { return }
        guard JarvisApprovals.mayApprove(seen: seen, current: current) else {
            status = "El informe cambió: revisa los patrones otra vez."
            return
        }
        busy = true
        defer { busy = false }
        let report = seen
        let code = JarvisApprovals.shortCode(report.huella)
        let reason = "aprobar \(report.id) de Jarvis, código \(code)"
        #if JARVIS_STORE_TESTS
        let confirmed = await confirmOwner(reason)
        #else
        let confirmed = await Self.ownerConfirms(reason: reason)
        #endif
        guard confirmed else {
            status = "Sin Touch ID o contraseña no se aprueba nada."
            return
        }
        guard warning == nil, JarvisApprovals.mayApprove(seen: report, current: current) else {
            status = "El informe cambió durante Touch ID: revisa los patrones otra vez."
            return
        }
        let vault = vault
        do {
            let name = try await Task.detached { try JarvisApprovals.approve(report, vault: vault) }.value
            log("approved \(report.id)")
            status = "Aprobado: \(name)."
            requested = nil
            settled = report.key
        } catch {
            log("approval of \(report.id) failed")
            status = Self.describe(error)
        }
        rescan()
    }

    func reject(_ report: JarvisApprovals.Report, motivo: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let vault = vault
        do {
            let name = try await Task.detached { try JarvisApprovals.reject(report, motivo: motivo, vault: vault) }.value
            log("rejected \(report.id)")
            status = "Rechazado: \(name)."
            requested = nil
            settled = report.key
            rescan()
            return true
        } catch {
            status = Self.describe(error)
            return false
        }
    }

    /// Touch ID, the Apple Watch or the Mac's password. Never skipped.
    nonisolated static func ownerConfirms(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func describe(_ error: Error) -> String {
        switch error as? JarvisApprovals.Failure {
        case .notPending?:            return "Ese informe ya no espera aprobación."
        case .changed?:               return "El informe cambió desde que lo viste: revísalo otra vez."
        case .invalidPermite(let p)?: return p
        case .exists(let name)?:      return "Ya existe \(name)."
        case .motivo?:                return "Escribe el motivo del rechazo."
        case .write?, nil:            return "No pude escribir en vault/aprobaciones."
        }
    }

    private func log(_ message: String) {
        appendAppLog("nb.log", "[Jarvis] approvals: \(message)")
    }
}

// MARK: - Card in the notch

struct JarvisApprovalsCardView: View {
    @ObservedObject private var store = JarvisApprovalStore.shared
    @State private var rejecting = false
    @State private var motivo = ""
    // The report whose whole permite list was on screen (it fit, or was scrolled to the end).
    // Approve needs it to equal the report shown now (JarvisApprovals.mayApprove).
    @State private var seen: JarvisApprovals.Report?
    /// Off for JarvisApprovals.armDelay after the card appears or changes.
    @State private var armed = false
    @FocusState private var motivoFocused: Bool

    var body: some View {
        ZStack {
            CardBackground(wash: .amber)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.current?.key) { _, _ in rejecting = false; motivo = "" }
        .onChange(of: store.current) { _, _ in store.rearm() }
        .onAppear { store.rearm() }
        .task(id: store.shownAt) {
            armed = false
            try? await Task.sleep(for: .seconds(JarvisApprovals.armDelay))
            if !Task.isCancelled { armed = true }
        }
    }

    @ViewBuilder private var content: some View {
        if let report = store.current {
            title(store.pending.count > 1 && store.missing == nil
                  ? "Aprobación de Jarvis · \(store.index + 1) de \(store.pending.count)" : "Aprobación de Jarvis")
            field("Tarea", report.id)
            field("Acción", report.titulo)
            field("Código", "\(JarvisApprovals.shortCode(report.huella)) · "
                + JarvisApprovals.ageText(since: report.changedAt, now: Date()))
            permite(report)
            if let notice = store.warning ?? store.status { line(notice) }
            if rejecting {
                HStack(spacing: 6) {
                    TextField(text: $motivo) { Text(verbatim: "Motivo del rechazo…") }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .focused($motivoFocused)
                        .onAppear { motivoFocused = true }
                        .onSubmit { confirmReject(report) }
                        .onExitCommand { rejecting = false }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    PrimaryButton(verbatim: "Rechazar") { confirmReject(report) }
                    SecondaryButton(verbatim: "Cancelar") { rejecting = false }
                }
            } else {
                HStack(spacing: 8) {
                    let enabled = armed && store.warning == nil && report.permiteIsValid && !store.busy
                        && JarvisApprovals.mayApprove(seen: seen, current: report)
                    PrimaryButton(verbatim: "Aprobar") {
                        // The report that was seen, never the latest one.
                        if enabled, let seen { Task { await store.approve(seen) } }
                    }
                        .disabled(!enabled)
                        .opacity(enabled ? 1 : 0.4)
                    SecondaryButton(verbatim: "Rechazar") { rejecting = true }
                    if store.canAdvance { SecondaryButton(verbatim: "Siguiente") { store.next() } }
                    SecondaryButton(verbatim: "Luego") { store.later() }
                }
            }
        } else {
            title("Aprobaciones de Jarvis")
            line(store.status ?? "No hay nada esperando aprobación.")
            SecondaryButton("OK") { store.later() }
        }
    }

    private func confirmReject(_ report: JarvisApprovals.Report) {
        Task { if await store.reject(report, motivo: motivo) { rejecting = false; motivo = "" } }
    }

    static let permiteBoxHeight: CGFloat = 54

    private func markSeen(_ report: JarvisApprovals.Report, contentHeight: CGFloat, atEnd: Bool) {
        let fits = contentHeight > 0 && contentHeight <= Self.permiteBoxHeight + 0.5
        if JarvisApprovals.canApprove(contentFits: fits, reachedEnd: atEnd) { seen = report }
    }

    /// The `permite:` patterns exactly as they will be written.
    @ViewBuilder private func permite(_ report: JarvisApprovals.Report) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: report.permite.count == 1 ? "permite: 1 patrón" : "permite: \(report.permite.count) patrones")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color(hex: "#8E939C"))
            if report.permite.isEmpty {
                line(JarvisApprovals.permiteProblem(report.permite) ?? "")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(report.permite.enumerated()), id: \.offset) { _, pattern in
                            Text(verbatim: pattern)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "#F1F2F4"))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The list's own height, measured on appear (always called) and on change.
                    // `report` here is the one these rows show: that is what gets marked seen.
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { markSeen(report, contentHeight: proxy.size.height, atEnd: false) }
                            .onChange(of: proxy.size.height) { _, h in markSeen(report, contentHeight: h, atEnd: false) }
                    })
                }
                .frame(maxHeight: Self.permiteBoxHeight)
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentSize.height > 0
                        && geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 1
                } action: { _, atEnd in
                    markSeen(report, contentHeight: 0, atEnd: atEnd)
                }
                // A new or changed report is a new list: measured and scrolled from the top again.
                .id(report)
                if let problem = JarvisApprovals.permiteProblem(report.permite) {
                    line(problem)
                } else if !JarvisApprovals.mayApprove(seen: seen, current: report) {
                    line("Baja hasta el último patrón para poder aprobar.")
                }
            }
        }
    }

    private func title(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .lineLimit(1)
    }

    private func field(_ label: String, _ value: String) -> some View {
        (Text(verbatim: "\(label): ").foregroundColor(Color(hex: "#8E939C"))
            + Text(verbatim: value).foregroundColor(Color(hex: "#F1F2F4")))
            .font(.system(size: 11.5))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#8E939C"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
