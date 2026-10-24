import Foundation
import LiltCore

public enum LiveUsageBridge {
    private static func file(_ store: BackendStore, _ name: String) -> URL { store.paths.stateRoot.appendingPathComponent(name) }
    private static var executable: String {
        let argument = ProcessInfo.processInfo.arguments.first ?? "lilt"
        return argument.hasPrefix("/") ? argument : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument).standardized.path
    }
    private static func command(_ store: BackendStore) -> String { shellQuote(executable) + " statusline-hook" }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func settings(_ store: BackendStore) throws -> [String: Any] {
        guard let data = try read(store.paths.settings) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendFailure("~/.claude/settings.json 不是有效 JSON，没有改动它。") }
        return object
    }
    private static func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackendFailure("Claude 配置是符号链接，未修改。") }
        return try Data(contentsOf: file)
    }
    private static func writeSettings(_ store: BackendStore, _ object: [String: Any]) throws {
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.paths.settings.path))?[.posixPermissions] as? NSNumber
        try SecureFiles.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: store.paths.settings)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: store.paths.settings.path) }
    }
    public static func isInstalled(store: BackendStore) -> Bool {
        (((try? settings(store))?["statusLine"] as? [String: Any])?["command"] as? String) == command(store)
    }
    public static func install(store: BackendStore) throws {
        try store.prepare()
        guard FileManager.default.fileExists(atPath: store.paths.claudeDirectory.path) else { throw BackendFailure("找不到 Claude 配置目录，先运行一次 Claude Code。") }
        var object = try settings(store)
        let current = object["statusLine"] as? [String: Any]
        if current?["command"] as? String == command(store) { return }
        let existed = FileManager.default.fileExists(atPath: store.paths.settings.path)
        let backup = file(store, "claude-settings-before-lilt.json")
        if existed, !FileManager.default.fileExists(atPath: backup.path), let data = try read(store.paths.settings) { try SecureFiles.write(data, to: backup) }
        let previous = ["statusLine": current.map { $0 as Any } ?? NSNull(), "fileExisted": existed] as [String: Any]
        try SecureFiles.write(try JSONSerialization.data(withJSONObject: previous), to: file(store, "statusline-previous.json"))
        if current?["type"] as? String == "command", let before = current?["command"] as? String, !before.isEmpty {
            try SecureFiles.write(Data((before + "\n").utf8), to: file(store, "statusline-chain.sh"))
        } else { try? FileManager.default.removeItem(atPath: file(store, "statusline-chain.sh").path) }
        var next = current ?? [:]; next["type"] = "command"; next["command"] = command(store)
        object["statusLine"] = next; try writeSettings(store, object)
    }
    public static func uninstall(store: BackendStore) throws {
        var object = try settings(store)
        if (object["statusLine"] as? [String: Any])?["command"] as? String == command(store) {
            let kept = try read(file(store, "statusline-previous.json")).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let before = kept?["statusLine"] as? [String: Any] { object["statusLine"] = before } else { object.removeValue(forKey: "statusLine") }
            if object.isEmpty, kept?["fileExisted"] as? Bool == false { try? FileManager.default.removeItem(atPath: store.paths.settings.path) }
            else { try writeSettings(store, object) }
        }
        for name in ["statusline-chain.sh", "statusline-previous.json", "live-usage.json", "statusline-label.txt"] {
            try? FileManager.default.removeItem(atPath: file(store, name).path)
        }
    }
    public static func latest(store: BackendStore) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: file(store, "live-usage.json")) else { return nil }
        return UsageParser.parseStatusLine(data)
    }
    public static func setLabel(_ store: BackendStore, _ label: String?) throws {
        if let label { try SecureFiles.write(Data("Lilt · \(label)".utf8), to: file(store, "statusline-label.txt")) }
        else { try? FileManager.default.removeItem(atPath: file(store, "statusline-label.txt").path) }
    }
    public static func handle(store: BackendStore, input: Data) throws -> Data {
        if let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any], let limits = root["rate_limits"],
           JSONSerialization.isValidJSONObject(limits) {
            let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            if configured?.isEmpty != false || configured == store.paths.claudeDirectory.path {
                let record: [String: Any] = ["at": Date.now.timeIntervalSince1970, "rate_limits": limits]
                try? SecureFiles.write(try JSONSerialization.data(withJSONObject: record), to: file(store, "live-usage.json"))
            }
        }
        let chain = file(store, "statusline-chain.sh")
        if FileManager.default.fileExists(atPath: chain.path) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [chain.path]
            let stdin = Pipe(), stdout = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.standardError
            try process.run()
            stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return output
        }
        return (try? Data(contentsOf: file(store, "statusline-label.txt"))) ?? Data()
    }
}
