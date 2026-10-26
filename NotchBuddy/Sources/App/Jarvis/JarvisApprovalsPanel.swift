#if !APPSTORE
import CoreServices
import LocalAuthentication
import SwiftUI

// MARK: - JarvisApprovalStore
//
// Watches the vault (FSEvents, nothing runs between changes) and keeps the reports
// waiting for approval. A new one opens the "Aprobaciones de Jarvis" card in the notch
// when nothing else waits there. Approving asks for Touch ID (or the Mac's password)
// first, then writes vault/aprobaciones/APROBADO-<id>.md; rejecting writes
// RECHAZADO-<id>.md with the reason. Nothing is written without a click.
@MainActor
final class JarvisApprovalStore: ObservableObject {
    static let shared = JarvisApprovalStore()

    @Published private(set) var pending: [JarvisApprovals.Report] = []
    @Published var index = 0
    @Published private(set) var status: String?
    @Published private(set) var busy = false

    private var stream: FSEventStreamRef?
    private var watched: String?
    private var seen: Set<String> = []
    private var rescanTask: Task<Void, Never>?

    var vault: URL { JarvisLink.expand(JarvisSettings.vaultPath) }
    var current: JarvisApprovals.Report? { pending.indices.contains(index) ? pending[index] : pending.first }

    func start() {
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
        pending = []
    }

    func rescan() {
        rescanTask?.cancel()
        let vault = vault
        rescanTask = Task { [weak self] in
            let list = await Task.detached { JarvisApprovals.listPending(vault: vault).filter { $0.decision == .pendiente } }.value
            guard !Task.isCancelled, let self else { return }
            let shownId = self.current?.id
            self.pending = list
            self.index = list.firstIndex { $0.id == shownId } ?? 0
            // A new report opens the card once; while the notch is busy it waits for the next look.
            let fresh = list.filter { !self.seen.contains($0.id) }
            if let first = fresh.first, self.islandFree {
                self.seen.formUnion(list.map(\.id))
                self.index = list.firstIndex(of: first) ?? 0
                self.status = nil
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.jarvisApprovals)
            }
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

    func next() {
        guard !pending.isEmpty else { return }
        index = (index + 1) % pending.count
        status = nil
    }

    func later() {
        status = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: Decisions

    func approve(_ report: JarvisApprovals.Report) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard await Self.ownerConfirms(reason: "aprobar \(report.id) de Jarvis") else {
            status = "Sin Touch ID o contraseña no se aprueba nada."
            return
        }
        let vault = vault
        do {
            let name = try await Task.detached { try JarvisApprovals.approve(report, vault: vault) }.value
            log("approved \(report.id)")
            status = "Aprobado: \(name)."
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
    // Whether every permite pattern was on screen (JarvisApprovals.canApprove).
    @State private var permiteFits = false
    @State private var permiteSeenToEnd = false
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
        .onChange(of: store.current?.id) { _, _ in
            rejecting = false; motivo = ""
            permiteFits = false; permiteSeenToEnd = false
        }
    }

    @ViewBuilder private var content: some View {
        if let report = store.current {
            title(store.pending.count > 1 ? "Aprobación de Jarvis · \(store.index + 1) de \(store.pending.count)"
                                           : "Aprobación de Jarvis")
            field("Tarea", report.id)
            field("Acción", report.titulo)
            permite(report)
            if let status = store.status { line(status) }
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
                    let enabled = report.permiteIsValid && !store.busy
                        && JarvisApprovals.canApprove(contentFits: permiteFits, reachedEnd: permiteSeenToEnd)
                    PrimaryButton(verbatim: "Aprobar") { if enabled { Task { await store.approve(report) } } }
                        .disabled(!enabled)
                        .opacity(enabled ? 1 : 0.4)
                    SecondaryButton(verbatim: "Rechazar") { rejecting = true }
                    if store.pending.count > 1 { SecondaryButton(verbatim: "Siguiente") { store.next() } }
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
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { permiteFits = proxy.size.height <= Self.permiteBoxHeight + 0.5 }
                            .onChange(of: proxy.size.height) { _, h in permiteFits = h <= Self.permiteBoxHeight + 0.5 }
                    })
                }
                .frame(maxHeight: Self.permiteBoxHeight)
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 1
                } action: { _, atEnd in
                    if atEnd { permiteSeenToEnd = true }   // once seen, stays seen
                }
                if let problem = JarvisApprovals.permiteProblem(report.permite) {
                    line(problem)
                } else if !JarvisApprovals.canApprove(contentFits: permiteFits, reachedEnd: permiteSeenToEnd) {
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
