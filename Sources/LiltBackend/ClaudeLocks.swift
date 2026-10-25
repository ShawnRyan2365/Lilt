import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func modificationDate(_ info: stat) -> Date {
    #if canImport(Darwin)
    let stamp = info.st_mtimespec
    #else
    let stamp = info.st_mtim
    #endif
    return Date(timeIntervalSince1970: TimeInterval(stamp.tv_sec) + TimeInterval(stamp.tv_nsec) / 1_000_000_000)
}

private final class DirectoryLock: @unchecked Sendable {
    let path: URL
    let stale: TimeInterval
    private var timer: DispatchSourceTimer?
    init(path: URL, stale: TimeInterval) { self.path = path; self.stale = stale }

    func acquire(timeout: TimeInterval = 9) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let start = DispatchTime.now()
        while true {
            if mkdir(path.path, 0o700) == 0 {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + 3, repeating: 3)
                timer.setEventHandler { [path] in try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: path.path) }
                timer.resume(); self.timer = timer
                return
            }
            guard errno == EEXIST else { throw BackendFailure("无法创建 Claude Code 锁。") }
            if DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds > UInt64(timeout * 1_000_000_000) {
                throw BackendFailure("Claude Code 正在续期或写入配置，请稍后重试。")
            }
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw BackendFailure("Claude Code 锁路径不是目录，已拒绝修改。") }
                let modified = modificationDate(info)
                if Date.now.timeIntervalSince(modified) > stale { tryRemoveStale() }
            }
            Thread.sleep(forTimeInterval: 0.25 + Double.random(in: 0..<0.25))
        }
    }
    private func tryRemoveStale() {
        let takeover = path.appendingPathExtension("takeover")
        guard mkdir(takeover.path, 0o700) == 0 else { return }
        defer { _ = rmdir(takeover.path) }
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let modified = modificationDate(info)
        if Date.now.timeIntervalSince(modified) > stale { _ = rmdir(path.path) }
    }
    func release() {
        timer?.cancel(); timer = nil
        _ = rmdir(path.path)
    }
    deinit { if timer != nil { release() } }
}

private func withDirectoryLock<T>(_ path: URL, stale: TimeInterval, _ work: () throws -> T) throws -> T {
    let lock = DirectoryLock(path: path, stale: stale)
    try lock.acquire(); defer { lock.release() }
    return try work()
}

public enum ClaudeLocks {
    public static func withCredentials<T>(_ paths: BackendPaths, _ work: () throws -> T) throws -> T {
        try withCredentials(paths.runtimeScope, work)
    }
    public static func withCredentials<T>(_ paths: RuntimeScopePaths, _ work: () throws -> T) throws -> T {
        let primary = paths.claudeDirectory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
        let legacy = paths.claudeDirectory.deletingLastPathComponent().appendingPathComponent(paths.claudeDirectory.lastPathComponent + ".lock", isDirectory: true)
        return try withDirectoryLock(primary, stale: 60) {
            try withDirectoryLock(legacy, stale: 60) {
                try withOwnLock(paths, work)
            }
        }
    }
    public static func withConfig<T>(_ paths: BackendPaths, _ work: () throws -> T) throws -> T {
        try withConfig(paths.runtimeScope, work)
    }
    public static func withConfig<T>(_ paths: RuntimeScopePaths, _ work: () throws -> T) throws -> T {
        try withDirectoryLock(paths.globalClaudeConfig.appendingPathExtension("lock"), stale: 10, work)
    }
    public static func withAll<T>(_ paths: BackendPaths, _ work: () throws -> T) throws -> T {
        try withAll(paths.runtimeScope, work)
    }
    public static func withAll<T>(_ paths: RuntimeScopePaths, _ work: () throws -> T) throws -> T {
        try withCredentials(paths) { try withConfig(paths, work) }
    }
    private static func withOwnLock<T>(_ paths: RuntimeScopePaths, _ work: () throws -> T) throws -> T {
        let file = paths.stateRoot.appendingPathComponent("runtime.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BackendFailure("无法锁定 Lilt 运行时。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw BackendFailure("另一个 Lilt 操作正在切换。") }
        defer { _ = flock(fd, LOCK_UN) }
        return try work()
    }
}
