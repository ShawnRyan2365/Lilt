import Foundation
import LiltCore

public enum OfficialLogin {
    public static var executable: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CLAUDE_CLI_PATH"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory).appending("/claude")
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
    public static func version() -> String {
        guard let executable else { return "未安装" }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--version"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run(); process.waitUntilExit()
            let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
            return value.count < 100 ? value : "未知"
        } catch { return "检测失败" }
    }
    public static func login(store: BackendStore) throws -> (credential: Credential, identity: Data?) {
        guard let executable else { throw BackendFailure("未找到官方 Claude Code CLI。") }
        try store.prepare()
        let temporary = store.paths.dataRoot.appendingPathComponent("login-\(UUID().uuidString)", isDirectory: true)
        try SecureFiles.directory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process(); process.executableURL = executable
        process.arguments = ["auth", "login", "--claudeai"]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") { environment.removeValue(forKey: key) }
        environment["CLAUDE_CONFIG_DIR"] = temporary.path
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = temporary.path
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        process.environment = environment; process.currentDirectoryURL = temporary
        process.standardInput = FileHandle.standardInput; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        do { try process.run() } catch { throw BackendFailure("无法启动官方登录命令。") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackendFailure("官方登录未完成；现有账号未修改，临时凭据已清理。") }
        let file = temporary.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file) else { throw BackendFailure("登录完成，但没有读到兼容的文件凭据。") }
        let credential = Credential(data: data); try credential.validate()
        return (credential, FileRuntimeScope.identity(in: temporary))
    }
}
