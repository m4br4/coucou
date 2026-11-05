#if !APPSTORE
import Foundation

// MARK: - JarvisApprovalSocket
//
// aprobar.sock: how HQ asks for a card (JV-13). Not nb.sock, the hooks' channel: this one takes
// a line and closes, and it never takes over a socket that someone is still answering on.
// Nothing here authenticates the caller beyond its user: see JarvisRequest. No AppKit: compiled
// into tests/JarvisApprovalsTests.swift, on temporary paths only.
final class JarvisApprovalSocket: @unchecked Sendable {
    static let maxConnections = 4
    static let readTimeout: TimeInterval = 2

    static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true).appendingPathComponent("aprobar.sock").path
    }

    enum Refusal: Error, Equatable {
        case pathTooLong
        case unsafeFolder     // not a real folder of ours, mode 700
        case unsafeSocket     // something else lives at the path
        case inUse            // another Jarvis.app or Coucou.app answers there
        case system(Int32)
    }

    private let path: String
    /// A line, without its \n → the answer; nil closes without a word. Runs on the connection's thread.
    private let answer: @Sendable (Data) -> String?
    private let lock = NSLock()
    private var connections = 0
    private var listener: Int32 = -1

    init(path: String = JarvisApprovalSocket.defaultPath, answer: @escaping @Sendable (Data) -> String?) {
        self.path = path
        self.answer = answer
    }

    func start() throws {
        // A client that left must not kill the app when it gets its answer. AppDelegate does the
        // same for the hooks: this file doesn't count on it.
        signal(SIGPIPE, SIG_IGN)
        let fd = try Self.listen(at: path)
        lock.withLock { listener = fd }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    // MARK: Creating it

    private static func listen(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Refusal.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, c) in bytes.enumerated() { raw[i] = UInt8(bitPattern: c) }
        }

        try prepareFolder((path as NSString).deletingLastPathComponent)
        try clearOld(path, address: address)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Refusal.system(errno) }
        // Born with mode 600: chmod after bind would leave a moment with the default mode. The
        // mask is the process's, so it is only changed for this one call.
        let mask = umask(0o177)
        let bound = bind(fd, address)
        let bindError = errno
        umask(mask)
        guard bound == 0 else { close(fd); throw Refusal.system(bindError) }

        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_mode & 0o777 == 0o600,
              Darwin.listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            throw Refusal.unsafeSocket
        }
        return fd
    }

    private static func bind(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Someone of the same user may have made the folder or put a symlink there first.
    private static func prepareFolder(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT, mkdir(dir, 0o700) == 0, lstat(dir, &st) == 0 else { throw Refusal.unsafeFolder }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else {
            throw Refusal.unsafeFolder
        }
    }

    /// Only an old socket of ours that nobody answers on is removed.
    private static func clearOld(_ path: String, address: sockaddr_un) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw Refusal.system(errno)
        }
        guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else { throw Refusal.unsafeSocket }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Refusal.system(errno) }
        defer { close(probe) }
        var address = address
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { throw Refusal.inUse }
        guard errno == ECONNREFUSED, unlink(path) == 0 else { throw Refusal.system(errno) }
    }

    // MARK: Serving it

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(client, &euid, &egid) == 0, euid == getuid(), takeConnection() else {
                close(client)
                continue
            }
            Thread.detachNewThread { [self] in
                serve(client)
                close(client)
                lock.withLock { connections -= 1 }
            }
        }
    }

    private func takeConnection() -> Bool {
        lock.withLock {
            guard connections < Self.maxConnections else { return false }
            connections += 1
            return true
        }
    }

    private func serve(_ fd: Int32) {
        guard let line = Self.readLine(fd), let reply = answer(line) else { return }
        let bytes = Array(reply.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            sent += n
        }
    }

    /// The line without its \n; nil if it is too long or doesn't arrive whole in time.
    private static func readLine(_ fd: Int32) -> Data? {
        let deadline = Date().addingTimeInterval(readTimeout)
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        while line.count < JarvisRequest.maxLine {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32((left * 1000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let wanted = min(chunk.count, JarvisRequest.maxLine - line.count)
            let n = read(fd, &chunk, wanted)
            guard n > 0 else { return nil }
            if let end = chunk[..<n].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<end])
                return line
            }
            line.append(contentsOf: chunk[..<n])
        }
        return nil
    }
}
#endif
