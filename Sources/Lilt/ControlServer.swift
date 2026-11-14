import Foundation
import Darwin
import LiltCore

/// The socket the `lilt` command talks to: `control.sock` in Lilt's own directory. Only this user's processes reach it:
/// the directory is 0700, the socket 0600, and every connection's peer is checked with `getpeereid`. One JSON request
/// line in, one reply line out, and neither carries a credential. A session asked for here is prepared by `AppModel`,
/// for the process on the other end of the connection, which the kernel names (`LOCAL_PEERPID`).
enum ControlSocket {
    static var path: String { Disk.file("control.sock").path }
    static let maximumMessage = 256 * 1024

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A connected socket, or the `errno` of the failure.
    static func connect(_ path: String) -> Result<Int32, Errno> {
        guard var address = address(path) else { return .failure(Errno(ENAMETOOLONG)) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(Errno(errno)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { let code = errno; close(fd); return .failure(Errno(code)) }
        noSignalOnBrokenPipe(fd)
        return .success(fd)
    }

    static func noSignalOnBrokenPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    static func timeout(_ fd: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }
    /// Reads up to the first newline, or the end, within `maximumMessage` bytes.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumMessage {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline]); return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty || data.count > maximumMessage ? nil : data
    }
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var payload = [UInt8](data); payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let written = payload[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

struct Errno: Error { let code: Int32; init(_ code: Int32) { self.code = code } }

@MainActor
final class ControlServer {
    static let shared = ControlServer()
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private weak var model: AppModel?

    /// Starts answering `lilt`, unless another copy of Lilt already does (a debug build beside the installed one).
    func start(model: AppModel) {
        guard listener < 0 else { return }
        self.model = model
        let path = ControlSocket.path
        guard (try? Disk.directory(Disk.root)) != nil else { return }
        if case .success(let probe) = ControlSocket.connect(path) { close(probe); return }
        // Left behind by a copy that crashed. Anything there that is not a socket is not Lilt's to remove.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { return }
            unlink(path)
        }
        guard var address = ControlSocket.address(path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "app.lilt.control"))
        source.setEventHandler(handler: Self.acceptHandler(fd))
        source.resume()
        self.source = source
    }

    func stop() {
        guard listener >= 0 else { return }
        source?.cancel(); source = nil
        close(listener); listener = -1
        unlink(ControlSocket.path)
    }

    /// Made outside the main actor: a closure written inside `start` would be isolated to it, and running it on the
    /// socket's queue stops the app on Swift 6's isolation check.
    nonisolated private static func acceptHandler(_ listener: Int32) -> @Sendable () -> Void { { acceptPending(listener) } }

    nonisolated private static func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async { serve(client) }
        }
    }

    nonisolated private static func serve(_ client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        ControlSocket.noSignalOnBrokenPipe(client)
        ControlSocket.timeout(client, seconds: 5)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), let line = ControlSocket.readLine(client) else { close(client); return }
        // Taken now, while the terminal's process is certainly the one connected.
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let lease = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? ProcessLease.lease(pid: pid) : nil
        Task { @MainActor in
            let reply = await handle(line, lease: lease)
            let data = (try? JSONEncoder().encode(reply)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                ControlSocket.writeAll(client, data)
                close(client)
            }
        }
    }

    private static func handle(_ line: Data, lease: SessionLease?) async -> ControlReply {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else { return .failure("请求无法识别。") }
        guard let model = shared.model else { return .failure("Lilt 还没准备好，稍后再试。") }
        if model.demo { return .failure("Lilt 正在演示模式；先在 Lilt 里退出演示。") }
        switch request.action {
        case "list": return model.commandLineList()
        case "session": return await model.startSession(request.ids ?? [], lease: lease)
        case "bypass":
            if let on = request.bypass { model.setSessionBypass(on) }
            return ControlReply(ok: true, bypass: model.sessionBypass)
        default: return .failure("正在运行的 Lilt 不认识“\(request.action)”；重新打开 Lilt 后再试。")
        }
    }
}
