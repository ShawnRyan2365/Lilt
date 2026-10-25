import Foundation
import LiltCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct DaemonRequest: Codable, Sendable {
    public var action: String
    public var id: UUID?
    public var label: String?
    public var credential: Data?
    public var identity: Data?
    public var enabled: Bool?
    public var amount: Double?
    public var rootPath: String?
    public var allowShared: Bool?
    /// Only for export and import. The socket is the user's own (0600 in a 0700 directory), like a setup-token sent
    /// with `add`; neither is ever logged or kept.
    public var passphrase: String?
    public var archive: Data?

    public init(
        action: String,
        id: UUID? = nil,
        label: String? = nil,
        credential: Data? = nil,
        identity: Data? = nil,
        enabled: Bool? = nil,
        amount: Double? = nil,
        rootPath: String? = nil,
        allowShared: Bool? = nil,
        passphrase: String? = nil,
        archive: Data? = nil
    ) {
        self.action = action
        self.id = id
        self.label = label
        self.credential = credential
        self.identity = identity
        self.enabled = enabled
        self.amount = amount
        self.rootPath = rootPath
        self.allowShared = allowShared
        self.passphrase = passphrase
        self.archive = archive
    }
}

public struct DaemonStatus: Codable, Sendable {
    public var running: Bool
    public var message: String?
    public var relayPause: String?
    public var relayRetryAt: Date?
    public var scopeIssue: String?
    public var scopeUnreadable: String?
    public var statusLineIssue: String?
    public var lastEvent: String?
    public var appliedPending: Bool
    public var apiModeDetected: Bool
    /// At least one session on the default login reported the account switched to. Not every session.
    public var sessionConfirmed: Bool

    public init(
        running: Bool = true,
        message: String? = nil,
        relayPause: String? = nil,
        relayRetryAt: Date? = nil,
        scopeIssue: String? = nil,
        scopeUnreadable: String? = nil,
        statusLineIssue: String? = nil,
        lastEvent: String? = nil,
        appliedPending: Bool = false,
        apiModeDetected: Bool = false,
        sessionConfirmed: Bool = false
    ) {
        self.running = running
        self.message = message
        self.relayPause = relayPause
        self.relayRetryAt = relayRetryAt
        self.scopeIssue = scopeIssue
        self.scopeUnreadable = scopeUnreadable
        self.statusLineIssue = statusLineIssue
        self.lastEvent = lastEvent
        self.appliedPending = appliedPending
        self.apiModeDetected = apiModeDetected
        self.sessionConfirmed = sessionConfirmed
    }
}

public struct DaemonResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var library: Library?
    public var status: DaemonStatus?
    public var projects: [ProjectBinding]?
    public var project: ProjectBinding?
    public var launchPlan: ProjectLaunchPlan?
    public var archive: Data?
    public var transfer: TransferSummary?

    public init(ok: Bool, error: String? = nil, library: Library? = nil, status: DaemonStatus? = nil,
                projects: [ProjectBinding]? = nil, project: ProjectBinding? = nil, launchPlan: ProjectLaunchPlan? = nil,
                archive: Data? = nil, transfer: TransferSummary? = nil) {
        self.ok = ok
        self.error = error
        self.library = library
        self.status = status
        self.projects = projects
        self.project = project
        self.launchPlan = launchPlan
        self.archive = archive
        self.transfer = transfer
    }
}

private enum LocalSocketTransport {
    static let maximumMessageSize = 1_048_576

    static func failure(_ message: String) -> BackendFailure {
        BackendFailure(message)
    }

    static func makeAddress(for url: URL) throws -> (sockaddr_un, socklen_t) {
        let bytes = Array(url.path.utf8)
        guard !bytes.contains(0) else { throw failure("本地 socket 路径无效。") }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw failure("本地 socket 路径过长。") }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        let length = pathOffset + bytes.count + 1
        #if canImport(Darwin)
        address.sun_len = UInt8(length)
        #endif
        return (address, socklen_t(length))
    }

    static func closeDescriptor(_ fd: Int32) {
        _ = close(fd)
    }

    static func setNoSIGPIPE(_ fd: Int32) throws {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw failure("无法配置本地 socket。")
        }
        #endif
    }

    static func connect(_ fd: Int32, address: sockaddr_un, length: socklen_t) -> Int32 {
        withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.connect(fd, $0, length)
            }
        }
    }

    static func readMessage(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress, bytes.count, 0)
            }
            if count > 0 {
                guard data.count + count <= maximumMessageSize else {
                    throw failure("本地 socket 消息超过 1 MiB 限制。")
                }
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw failure("读取本地 socket 失败。")
        }
    }

    static func writeMessage(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumMessageSize else {
            throw failure("本地 socket 消息超过 1 MiB 限制。")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = send(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset,
                    noSIGPIPEFlag
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw failure("写入本地 socket 失败。")
                }
            }
        }
    }

    static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #elseif canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static var noSIGPIPEFlag: Int32 {
        #if canImport(Darwin)
        return 0
        #else
        return Int32(MSG_NOSIGNAL)
        #endif
    }

    static func shutdownWrite(_ fd: Int32) throws {
        while true {
            if shutdown(fd, Int32(SHUT_WR)) == 0 { return }
            if errno == EINTR { continue }
            throw failure("无法结束本地 socket 写入。")
        }
    }

    static func makeConnectedSocket(at url: URL) throws -> Int32 {
        let (address, length) = try makeAddress(for: url)
        let fd = socket(AF_UNIX, LocalSocketTransport.streamSocketType, 0)
        guard fd >= 0 else { throw failure("无法创建本地 socket。") }
        do {
            try setNoSIGPIPE(fd)
            while true {
                if connect(fd, address: address, length: length) == 0 { break }
                if errno == EINTR { continue }
                throw failure("无法连接本地 daemon。")
            }
            return fd
        } catch {
            closeDescriptor(fd)
            throw error
        }
    }
}

#if canImport(Darwin)
private enum DarwinOrGlibc {
    static let connect = Darwin.connect
}
#elseif canImport(Glibc)
private enum DarwinOrGlibc {
    static let connect = Glibc.connect
}
#elseif canImport(Musl)
private enum DarwinOrGlibc {
    static let connect = Musl.connect
}
#endif

public final class LocalSocketClient: Sendable {
    private let paths: BackendPaths

    public init(paths: BackendPaths) {
        self.paths = paths
    }

    public func send(_ request: DaemonRequest) async throws -> DaemonResponse {
        let socketURL = paths.socket
        return try await Task.detached {
            let fd = try LocalSocketTransport.makeConnectedSocket(at: socketURL)
            defer { LocalSocketTransport.closeDescriptor(fd) }
            let encoded = try JSONEncoder().encode(request)
            try LocalSocketTransport.writeMessage(encoded, to: fd)
            try LocalSocketTransport.shutdownWrite(fd)
            let data = try LocalSocketTransport.readMessage(from: fd)
            return try JSONDecoder().decode(DaemonResponse.self, from: data)
        }.value
    }
}

private final class LocalSocketListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    func install(_ fd: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor == nil else { throw BackendFailure("本地 daemon 已在运行。") }
        descriptor = fd
    }

    func take(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor == fd else { return false }
        descriptor = nil
        return true
    }

    func stop() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        let fd = descriptor
        descriptor = nil
        return fd
    }
}

public final class LocalSocketServer: @unchecked Sendable {
    private let paths: BackendPaths
    private let handler: @Sendable (DaemonRequest) async -> DaemonResponse
    private let state = LocalSocketListenerState()

    public init(
        paths: BackendPaths,
        handler: @escaping @Sendable (DaemonRequest) async -> DaemonResponse
    ) {
        self.paths = paths
        self.handler = handler
    }

    public func run() async throws {
        let fd = try makeListener()
        do {
            while true {
                let connection = try await Task.detached {
                    try Self.acceptConnection(on: fd)
                }.value
                Task {
                    await handle(connection)
                }
            }
        } catch {
            if state.take(fd) {
                LocalSocketTransport.closeDescriptor(fd)
                _ = unlink(paths.socket.path)
                throw error
            }
            return
        }
    }

    public func stop() {
        guard let fd = state.stop() else { return }
        _ = shutdown(fd, Int32(SHUT_RDWR))
        LocalSocketTransport.closeDescriptor(fd)
        _ = unlink(paths.socket.path)
    }

    private func makeListener() throws -> Int32 {
        try BackendStore(paths: paths).prepare()
        let (address, length) = try LocalSocketTransport.makeAddress(for: paths.socket)
        var info = stat()
        if lstat(paths.socket.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else {
                throw BackendFailure("本地 socket 路径已被其他文件占用。")
            }
            let existing = socket(AF_UNIX, LocalSocketTransport.streamSocketType, 0)
            guard existing >= 0 else { throw BackendFailure("无法检查现有本地 socket。") }
            defer { LocalSocketTransport.closeDescriptor(existing) }
            var connectResult: Int32
            while true {
                connectResult = LocalSocketTransport.connect(existing, address: address, length: length)
                if connectResult == 0 || errno != EINTR { break }
            }
            if connectResult == 0 {
                throw BackendFailure("本地 daemon 已在运行。")
            }
            guard errno == ECONNREFUSED else {
                throw BackendFailure("现有本地 socket 状态未知，已拒绝覆盖。")
            }
            var current = stat()
            guard lstat(paths.socket.path, &current) == 0,
                  current.st_mode & S_IFMT == S_IFSOCK,
                  current.st_dev == info.st_dev,
                  current.st_ino == info.st_ino else {
                throw BackendFailure("现有本地 socket 已变化，已拒绝覆盖。")
            }
            guard unlink(paths.socket.path) == 0 else {
                throw BackendFailure("无法清理陈旧的本地 socket。")
            }
        } else if errno != ENOENT {
            throw BackendFailure("无法检查现有本地 socket。")
        }

        let fd = socket(AF_UNIX, LocalSocketTransport.streamSocketType, 0)
        guard fd >= 0 else { throw BackendFailure("无法创建本地 socket。") }
        var bound = false
        do {
            try LocalSocketTransport.setNoSIGPIPE(fd)
            let bindResult = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length)
                }
            }
            guard bindResult == 0 else { throw BackendFailure("无法绑定本地 socket。") }
            bound = true
            guard chmod(paths.socket.path, 0o600) == 0 else { throw BackendFailure("无法设置本地 socket 权限。") }
            guard listen(fd, 128) == 0 else { throw BackendFailure("无法监听本地 socket。") }
            try state.install(fd)
            return fd
        } catch {
            LocalSocketTransport.closeDescriptor(fd)
            if bound { _ = unlink(paths.socket.path) }
            throw error
        }
    }

    private static func acceptConnection(on fd: Int32) throws -> Int32 {
        while true {
            let connection = accept(fd, nil, nil)
            if connection >= 0 { return connection }
            if errno == EINTR { continue }
            throw BackendFailure("接受本地 socket 连接失败。")
        }
    }

    private func handle(_ fd: Int32) async {
        defer { LocalSocketTransport.closeDescriptor(fd) }
        let request: DaemonRequest
        do {
            request = try await Task.detached {
                let data = try LocalSocketTransport.readMessage(from: fd)
                return try JSONDecoder().decode(DaemonRequest.self, from: data)
            }.value
        } catch {
            return
        }
        let response = await handler(request)
        do {
            try await Task.detached {
                let data = try JSONEncoder().encode(response)
                try LocalSocketTransport.writeMessage(data, to: fd)
            }.value
        } catch {
            return
        }
    }
}
