import Foundation
import LiltCore

public struct BackendFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct ScopeUnreadable: Error, Sendable {
    public let message: String
    public init(_ error: Error) { message = (error as? BackendFailure)?.message ?? "读取失败，稍后重试。" }
}

public struct Credential: Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
    public var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    public var oauth: [String: Any] { object["claudeAiOauth"] as? [String: Any] ?? [:] }
    public var token: String? { oauth["accessToken"] as? String }
    public var expiresAt: Date? { (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
    public var refreshable: Bool { !((oauth["refreshToken"] as? String) ?? "").isEmpty }
    public var accessExpired: Bool { expires(within: 0) }
    public func expires(within seconds: TimeInterval) -> Bool { expiresAt.map { $0 <= Date.now.addingTimeInterval(seconds) } ?? false }
    public func validate() throws {
        guard let token, !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw BackendFailure("凭据格式无效，请重新授权或替换 Token。") }
        if accessExpired, !refreshable { throw BackendFailure("凭据已过期，请重新授权。") }
    }
    public static func manual(_ token: String) throws -> Credential {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("sk-ant-oat"), token.count > 24, !token.contains(where: { $0.isWhitespace }) else {
            throw BackendFailure("请输入 Claude setup-token 生成的 OAuth Token；不接受 API Key。")
        }
        return Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token, "scopes": ["user:inference"]]]))
    }
}

/// The backend's name for the shared digest; journals and tests keep calling it this.
public enum SHA256 {
    public static func hex(_ data: Data) -> String { SHA256Digest.hex(data) }
}

public struct BackendPaths: Sendable {
    public let home: URL
    public let dataRoot: URL
    public let stateRoot: URL
    public let configRoot: URL
    public let runtimeDirectory: URL
    public let socket: URL
    public let claudeDirectory: URL
    public let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let resolvedHome = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        func xdg(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
            return resolvedHome.appendingPathComponent(fallback, isDirectory: true)
        }
        let resolvedData = xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("lilt", isDirectory: true)
        let resolvedState = xdg("XDG_STATE_HOME", ".local/state").appendingPathComponent("lilt", isDirectory: true)
        let resolvedRuntime = environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("lilt", isDirectory: true) : nil }
            ?? resolvedState.appendingPathComponent("run", isDirectory: true)
        home = resolvedHome
        dataRoot = resolvedData
        stateRoot = resolvedState
        configRoot = xdg("XDG_CONFIG_HOME", ".config").appendingPathComponent("lilt", isDirectory: true)
        runtimeDirectory = resolvedRuntime
        socket = resolvedRuntime.appendingPathComponent("lilt.sock")
        claudeDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolvedHome.appendingPathComponent(".claude", isDirectory: true)
    }
    public var globalClaudeConfig: URL {
        let environment = self.environment["CLAUDE_CONFIG_DIR"]
        let base = environment.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home
        let modern = base.appendingPathComponent(".claude.json")
        let legacy = claudeDirectory.appendingPathComponent(".config.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: legacy.path),
           (attributes[.type] as? FileAttributeType) == .typeRegular {
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 || (!FileManager.default.fileExists(atPath: modern.path) && FileManager.default.isWritableFile(atPath: legacy.path)) { return legacy }
        }
        return modern
    }
    public var credentials: URL { claudeDirectory.appendingPathComponent(".credentials.json") }
    public var settings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var projectsCatalog: URL { dataRoot.appendingPathComponent("projects.json") }
    public var unit: URL { configRoot.deletingLastPathComponent().appendingPathComponent("systemd/user/liltd.service") }
    public func projectDataDirectory(_ id: UUID) -> URL {
        dataRoot.appendingPathComponent("projects/\(id.uuidString)", isDirectory: true)
    }
    public func projectStateDirectory(_ id: UUID) -> URL {
        stateRoot.appendingPathComponent("projects/\(id.uuidString)", isDirectory: true)
    }
    public func projectRuntime(_ id: UUID) -> RuntimeScopePaths {
        RuntimeScopePaths(project: id, paths: self)
    }
    public var runtimeScope: RuntimeScopePaths { RuntimeScopePaths(global: self) }
}

public struct RuntimeScopePaths: Sendable, Equatable {
    public let projectID: UUID?
    public let claudeDirectory: URL
    public let globalClaudeConfig: URL
    public let stateRoot: URL
    public var credentials: URL { claudeDirectory.appendingPathComponent(".credentials.json") }
    public var settings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    /// One file per status line event of this scope (see `LiveUsageSpool`).
    public var spool: URL { stateRoot.appendingPathComponent("live-usage-spool", isDirectory: true) }
    /// The `scope` its events carry.
    public var eventScope: String { projectID.map(LiveUsageEvent.projectScope) ?? LiveUsageEvent.defaultScope }

    public init(global paths: BackendPaths) {
        projectID = nil
        claudeDirectory = paths.claudeDirectory
        globalClaudeConfig = paths.globalClaudeConfig
        stateRoot = paths.stateRoot
    }
    public init(project id: UUID, paths: BackendPaths) {
        projectID = id
        claudeDirectory = paths.projectDataDirectory(id).appendingPathComponent("claude", isDirectory: true)
        globalClaudeConfig = claudeDirectory.appendingPathComponent(".claude.json")
        stateRoot = paths.projectStateDirectory(id)
    }
    public func prepare() throws {
        try SecureFiles.directory(claudeDirectory)
        try SecureFiles.directory(stateRoot)
    }
}

public final class BackendStore: @unchecked Sendable {
    public let paths: BackendPaths
    public init(paths: BackendPaths = BackendPaths()) { self.paths = paths }
    public func prepare() throws {
        for root in [paths.dataRoot, paths.stateRoot, paths.configRoot, paths.runtimeDirectory,
                     paths.dataRoot.appendingPathComponent("secrets", isDirectory: true),
                     paths.dataRoot.appendingPathComponent("projects", isDirectory: true),
                     paths.stateRoot.appendingPathComponent("projects", isDirectory: true)] {
            try SecureFiles.directory(root)
        }
    }
    public func load() throws -> Library {
        try prepare()
        let file = libraryFile
        guard FileManager.default.fileExists(atPath: file.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
    }
    public func save(_ library: Library) throws {
        try prepare()
        try SecureFiles.write(try JSONEncoder().encode(library), to: libraryFile)
    }
    private func secret(_ name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { throw BackendFailure("凭据名称无效。") }
        return paths.dataRoot.appendingPathComponent("secrets", isDirectory: true).appendingPathComponent(name)
    }
    public func readSecret(_ name: String) throws -> Data? {
        let file = try secret(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackendFailure("凭据文件是符号链接，已拒绝读取。") }
        return try Data(contentsOf: file)
    }
    public func writeSecret(_ name: String, data: Data) throws {
        try prepare()
        try SecureFiles.write(data, to: try secret(name))
    }
    public func deleteSecret(_ name: String) throws {
        let file = try secret(name)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func hasSecret(_ name: String) -> Bool { (try? readSecret(name)) != nil }
    public var secretsDirectory: URL { paths.dataRoot.appendingPathComponent("secrets", isDirectory: true) }
    public var libraryFile: URL { paths.dataRoot.appendingPathComponent("accounts.json") }
    public func log(_ kind: String, detail: String? = nil) {
        let line = Date.now.formatted(.iso8601) + " " + kind + (detail.map { " " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "") + "\n"
        let file = paths.stateRoot.appendingPathComponent("switches.log")
        let kept = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").suffix(199).map { $0 + "\n" }.joined()
        try? SecureFiles.write(Data((kept + line).utf8), to: file)
    }
}

public func backendReason(_ error: Error) -> String {
    switch error {
    case let failure as BackendFailure: failure.message
    case let failure as ScopeUnreadable: failure.message
    case let failure as UsageFailure: failure.message
    default: "操作失败，请稍后重试。"
    }
}
