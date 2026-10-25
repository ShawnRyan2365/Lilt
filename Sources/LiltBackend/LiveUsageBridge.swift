import Foundation
import LiltCore

public enum LiveUsageBridge {
    private static func file(_ store: BackendStore, _ scope: RuntimeScopePaths?, _ name: String) -> URL {
        (scope?.stateRoot ?? store.paths.stateRoot).appendingPathComponent(name)
    }
    private static func paths(_ store: BackendStore, _ scope: RuntimeScopePaths?) -> RuntimeScopePaths {
        scope ?? store.paths.runtimeScope
    }
    private static var executable: String {
        let argument = ProcessInfo.processInfo.arguments.first ?? "lilt"
        return argument.hasPrefix("/") ? argument : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument).standardized.path
    }
    private static func command(_ store: BackendStore, _ scope: RuntimeScopePaths?) -> String {
        var command = shellQuote(executable) + " statusline-hook"
        if let id = scope?.projectID { command += " --project \(id.uuidString)" }
        return command
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func settings(_ store: BackendStore, _ scope: RuntimeScopePaths?) throws -> [String: Any] {
        guard let data = try read(paths(store, scope).settings) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendFailure("Claude settings.json 不是有效 JSON，没有改动它。") }
        return object
    }
    private static func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackendFailure("Claude 配置是符号链接，未修改。") }
        return try Data(contentsOf: file)
    }
    private static func writeSettings(_ store: BackendStore, _ scope: RuntimeScopePaths?, _ object: [String: Any]) throws {
        let settings = paths(store, scope).settings
        let mode = (try? FileManager.default.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? NSNumber
        try SecureFiles.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: settings)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path) }
    }
    public static func isInstalled(store: BackendStore, scope: RuntimeScopePaths? = nil) -> Bool {
        (((try? settings(store, scope))?["statusLine"] as? [String: Any])?["command"] as? String) == command(store, scope)
    }
    public static func install(store: BackendStore, scope: RuntimeScopePaths? = nil) throws {
        try store.prepare()
        let runtime = paths(store, scope)
        guard FileManager.default.fileExists(atPath: runtime.claudeDirectory.path) else { throw BackendFailure("找不到 Claude 配置目录，先运行一次 Claude Code。") }
        var object = try settings(store, scope)
        let current = object["statusLine"] as? [String: Any]
        if current?["command"] as? String == command(store, scope) { return }
        let existed = FileManager.default.fileExists(atPath: runtime.settings.path)
        let backup = file(store, scope, "claude-settings-before-lilt.json")
        if existed, !FileManager.default.fileExists(atPath: backup.path), let data = try read(runtime.settings) { try SecureFiles.write(data, to: backup) }
        let previous = ["statusLine": current.map { $0 as Any } ?? NSNull(), "fileExisted": existed] as [String: Any]
        try SecureFiles.write(try JSONSerialization.data(withJSONObject: previous), to: file(store, scope, "statusline-previous.json"))
        if current?["type"] as? String == "command", let before = current?["command"] as? String, !before.isEmpty {
            try SecureFiles.write(Data((before + "\n").utf8), to: file(store, scope, "statusline-chain.sh"))
        } else { try? FileManager.default.removeItem(atPath: file(store, scope, "statusline-chain.sh").path) }
        var next = current ?? [:]; next["type"] = "command"; next["command"] = command(store, scope)
        object["statusLine"] = next; try writeSettings(store, scope, object)
    }
    public static func uninstall(store: BackendStore, scope: RuntimeScopePaths? = nil) throws {
        let runtime = paths(store, scope)
        var object = try settings(store, scope)
        if (object["statusLine"] as? [String: Any])?["command"] as? String == command(store, scope) {
            let kept = try read(file(store, scope, "statusline-previous.json")).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let before = kept?["statusLine"] as? [String: Any] { object["statusLine"] = before } else { object.removeValue(forKey: "statusLine") }
            if object.isEmpty, kept?["fileExisted"] as? Bool == false { try? FileManager.default.removeItem(atPath: runtime.settings.path) }
            else { try writeSettings(store, scope, object) }
        }
        for name in ["statusline-chain.sh", "statusline-previous.json", "live-usage.json", "live-usage-events.json", "statusline-label.txt"] {
            try? FileManager.default.removeItem(atPath: file(store, scope, name).path)
        }
        try? FileManager.default.removeItem(at: runtime.spool)
    }
    /// Every event this scope's sessions reported since the last call (see `LiveUsageSpool`).
    public static func drain(store: BackendStore, scope: RuntimeScopePaths? = nil) -> LiveUsageBatch {
        let runtime = paths(store, scope)
        return LiveUsageSpool.drain(runtime.spool, scope: runtime.eventScope)
    }
    public static func setLabel(_ store: BackendStore, _ label: String?, scope: RuntimeScopePaths? = nil) throws {
        if let label { try SecureFiles.write(Data("Lilt · \(label)".utf8), to: file(store, scope, "statusline-label.txt")) }
        else { try? FileManager.default.removeItem(atPath: file(store, scope, "statusline-label.txt").path) }
    }
    /// Keeps the session's `rate_limits` and nothing else, as one event file of its own.
    public static func ingest(store: BackendStore, scope: RuntimeScopePaths? = nil, input: Data, at now: Date = .now) throws {
        let runtime = paths(store, scope)
        guard let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let limits = root["rate_limits"], JSONSerialization.isValidJSONObject(limits) else { return }
        let id = UUID().uuidString
        let record = try LiveUsageSpool.record(id: id, scope: runtime.eventScope, at: now, limits: limits)
        guard UsageParser.parseStatusLineEvent(record) != nil else { return }
        try runtime.prepare()
        try LiveUsageSpool.write(record, id: id, at: now, to: runtime.spool)
    }
    public static func handle(store: BackendStore, input: Data, projectID: UUID? = nil) throws -> Data {
        let scope = projectID.map { store.paths.projectRuntime($0) }
        let runtime = paths(store, scope)
        // Only a session on this very scope reports for it. A hook copied into another configuration, or a session
        // started with another CLAUDE_CONFIG_DIR, would otherwise put a different login's quota on this account.
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : ProjectBinding.normalizedRoot($0) }
        let own = ProjectBinding.normalizedRoot(runtime.claudeDirectory.path)
        let matches = projectID == nil ? (configured == nil || configured == own) : configured == own
        // The user's own status line runs whatever happens here. An event that could not be kept is a gap, which
        // makes the daemon ask the endpoint instead.
        if matches {
            do { try ingest(store: store, scope: scope, input: input) }
            catch { try? SecureFiles.write(Data(), to: runtime.spool.appendingPathComponent(LiveUsageSpool.gapName)) }
        }
        let chain = file(store, scope, "statusline-chain.sh")
        if FileManager.default.fileExists(atPath: chain.path) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [chain.path]
            let stdin = Pipe(), stdout = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.standardError
            try process.run()
            stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return output
        }
        return (try? Data(contentsOf: file(store, scope, "statusline-label.txt"))) ?? Data()
    }
}
