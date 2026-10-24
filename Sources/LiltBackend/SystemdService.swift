import Foundation
import LiltCore

public enum SystemdService {
    private static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static var executable: String {
        let argument = ProcessInfo.processInfo.arguments.first ?? "lilt"
        return argument.hasPrefix("/") ? argument : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument).standardized.path
    }
    @discardableResult
    private static func systemctl(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/systemctl")
        process.arguments = ["--user"] + arguments; process.standardOutput = output; process.standardError = output
        do { try process.run() } catch { throw BackendFailure("无法运行 systemctl；也可以直接运行 `lilt daemon`。") }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else { throw BackendFailure(text.isEmpty ? "systemd 用户服务操作失败。" : text) }
        return text
    }
    public static func install(paths: BackendPaths) throws {
        try SecureFiles.directory(paths.unit.deletingLastPathComponent())
        var environment = ""
        for key in ["XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "CLAUDE_CONFIG_DIR"] {
            if let value = paths.environment[key] { environment += "Environment=\(quote(key + "=" + value))\n" }
        }
        let unit = """
        [Unit]
        Description=Lilt Claude account relay
        After=network-online.target

        [Service]
        Type=simple
        ExecStart=\(quote(executable)) daemon
        Restart=on-failure
        RestartSec=2
        NoNewPrivileges=true
        \(environment)
        [Install]
        WantedBy=default.target
        """
        try SecureFiles.write(Data(unit.utf8), to: paths.unit)
        _ = try systemctl(["daemon-reload"])
        _ = try systemctl(["enable", "--now", "liltd.service"])
    }
    public static func uninstall(paths: BackendPaths) throws {
        _ = try? systemctl(["disable", "--now", "liltd.service"])
        if FileManager.default.fileExists(atPath: paths.unit.path) { try FileManager.default.removeItem(at: paths.unit) }
        _ = try systemctl(["daemon-reload"])
    }
    public static func status() throws -> String { try systemctl(["status", "--no-pager", "liltd.service"]) }
}
