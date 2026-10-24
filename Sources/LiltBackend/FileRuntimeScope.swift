import Foundation
import LiltCore

public final class FileRuntimeScope: @unchecked Sendable {
    public let store: BackendStore
    public var paths: BackendPaths { store.paths }
    public init(store: BackendStore) { self.store = store }
    private var journal: URL { paths.stateRoot.appendingPathComponent("transaction-system.json") }
    private struct Stamp: Codable, Equatable { var file: String?; var pending = false }
    private func digest(_ data: Data?) -> String? { data.map(SHA256.hex) }
    private func read(_ file: URL, label: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackendFailure("\(label)是符号链接，已暂停。") }
        do { return try Data(contentsOf: file) } catch { throw ScopeUnreadable(BackendFailure("\(label)暂时读不出来。")) }
    }
    private func state() throws -> Stamp { Stamp(file: digest(try read(paths.credentials, label: "登录文件"))) }
    private func expected() throws -> Stamp? {
        guard let data = try read(journal, label: "事务日志") else { return nil }
        return try JSONDecoder().decode(Stamp.self, from: data)
    }
    private func verify(_ current: Stamp) throws {
        if let expected = try expected() {
            guard !expected.pending, expected == current else { throw BackendFailure("作用域凭据已被外部修改，或上次切换未完成。自动接力已暂停；请检查管理方。") }
        } else if current.file != nil { throw BackendFailure("此作用域已有未确认归属的凭据；Lilt 不会覆盖。") }
    }
    public func check() throws { try store.prepare(); try verify(state()) }
    public func currentCredential() throws -> Credential? {
        guard let data = try read(paths.credentials, label: "登录文件") else { return nil }
        return Credential(data: data)
    }
    public var transactionPending: Bool { ((try? expected()) ?? nil)?.pending == true }
    public func rebaseline() throws {
        try store.prepare()
        try SecureFiles.write(try JSONEncoder().encode(Stamp(file: digest(try read(paths.credentials, label: "登录文件")))), to: journal)
    }
    public func settle(identity: Data?) throws {
        if FileManager.default.fileExists(atPath: paths.globalClaudeConfig.path) { try writeIdentity(identity) }
        try rebaseline()
    }
    public func readIdentity() -> Data? { Self.identity(at: paths.globalClaudeConfig) }
    public static func identity(at config: URL) -> Data? {
        guard (try? config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: config),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }
    public static func identity(in directory: URL) -> Data? { identity(at: directory.appendingPathComponent(".claude.json")) }
    private func identityConfig(_ data: Data, _ identity: Data?) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendFailure("Claude 配置格式无效，未写入账号身份。") }
        if let identity, let account = try JSONSerialization.jsonObject(with: identity) as? [String: Any] { object["oauthAccount"] = account }
        else { object.removeValue(forKey: "oauthAccount") }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
    private func writeIdentity(_ identity: Data?) throws {
        let config = paths.globalClaudeConfig
        guard let old = try read(config, label: "Claude 配置") else { return }
        try SecureFiles.write(try identityConfig(old, identity), to: config)
    }
    public func hasAPIOverride() throws -> Bool {
        guard let data = try read(paths.settings, label: "Claude 用户配置") else { return false }
        do { return try AuthenticationSettings.hasAPIOverride(data) }
        catch { throw BackendFailure("Claude 用户配置格式无效，请修复 settings.json 后再切换。") }
    }
    public func apply(_ credential: Credential, identity: Data?, replacingExternalState: Bool = false) throws {
        try credential.validate(); try store.prepare()
        try ClaudeLocks.withAll(paths) {
            let oldFile = try read(paths.credentials, label: "登录文件")
            let previous = Stamp(file: digest(oldFile))
            if !replacingExternalState { try verify(previous) }
            let oldSettings = try read(paths.settings, label: "Claude 用户配置")
            if !replacingExternalState, try oldSettings.map(AuthenticationSettings.hasAPIOverride) == true {
                throw BackendFailure("检测到 API 模式，自动接力不会覆盖；请手动选择订阅账号。")
            }
            let newSettings = try replacingExternalState ? oldSettings.flatMap(AuthenticationSettings.subscriptionSettings) : nil
            let config = paths.globalClaudeConfig
            let oldConfig = try read(config, label: "Claude 配置")
            let newConfig = try oldConfig.map { try identityConfig($0, identity) }
            var pending = previous; pending.pending = true
            let priorJournal = try read(journal, label: "事务日志")
            try SecureFiles.write(try JSONEncoder().encode(pending), to: journal)
            var wroteFile = false, wroteSettings = false, wroteConfig = false
            do {
                guard try state() == previous,
                      try read(paths.settings, label: "Claude 用户配置") == oldSettings,
                      try read(config, label: "Claude 配置") == oldConfig else { throw BackendFailure("检测到并发登录配置变更，已暂停。") }
                try SecureFiles.write(credential.data, to: paths.credentials); wroteFile = true
                if let newSettings { try SecureFiles.write(newSettings, to: paths.settings); wroteSettings = true }
                if let newConfig { try SecureFiles.write(newConfig, to: config); wroteConfig = true }
                let next = Stamp(file: digest(try read(paths.credentials, label: "登录文件")))
                guard next.file == digest(credential.data),
                      try read(paths.settings, label: "Claude 用户配置") == (newSettings ?? oldSettings),
                      try read(config, label: "Claude 配置") == (newConfig ?? oldConfig) else { throw BackendFailure("登录配置同步不一致，已暂停。") }
                try SecureFiles.write(try JSONEncoder().encode(next), to: journal)
            } catch {
                if wroteConfig, let oldConfig, (try? read(config, label: "Claude 配置")) == newConfig { try? SecureFiles.write(oldConfig, to: config) }
                if wroteSettings, let oldSettings, (try? read(paths.settings, label: "Claude 用户配置")) == newSettings { try? SecureFiles.write(oldSettings, to: paths.settings) }
                if wroteFile, digest(try? read(paths.credentials, label: "登录文件")) == digest(credential.data) {
                    if let oldFile { try? SecureFiles.write(oldFile, to: paths.credentials) }
                    else { try? FileManager.default.removeItem(at: paths.credentials) }
                }
                if (try? state()) == previous,
                   (try? read(paths.settings, label: "Claude 用户配置")) == oldSettings,
                   (try? read(config, label: "Claude 配置")) == oldConfig {
                    if let priorJournal { try? SecureFiles.write(priorJournal, to: journal) }
                    else { try? FileManager.default.removeItem(at: journal) }
                }
                throw error
            }
        }
    }
}
