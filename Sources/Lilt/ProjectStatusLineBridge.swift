import Foundation
import LiltCore

/// The status line bridge of one project. A project's sessions read the `settings.json` in the project's own Claude
/// configuration, never `~/.claude/settings.json`, so each project gets its own script, spool, previous status line,
/// backup and label in its state directory. Only that configuration is edited; the repository's `.claude` settings,
/// managed policy and ORCA's files are left alone.
enum ProjectStatusLineBridge {
    private static func state(_ project: ProjectBinding) -> URL {
        Disk.root.appendingPathComponent("projects/\(project.id.uuidString)/state", isDirectory: true)
    }
    private static func script(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("statusline.sh") }
    private static func chain(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("statusline-chain.sh") }
    private static func previous(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("statusline-previous.json") }
    private static func backup(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("claude-settings-before-lilt.json") }
    private static func label(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("statusline-label.txt") }
    static func spool(_ project: ProjectBinding) -> URL { state(project).appendingPathComponent("live-usage-spool", isDirectory: true) }
    private static func configuration(_ project: ProjectBinding) -> URL { RuntimeScope(project: project).directory }
    private static func settings(_ project: ProjectBinding) -> URL { configuration(project).appendingPathComponent("settings.json") }
    private static func command(_ project: ProjectBinding) -> String { "/bin/sh " + shellQuote(script(project).path) }

    private static func readSettings(_ project: ProjectBinding) throws -> [String: Any] {
        let file = settings(project)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("项目 Claude 配置是符号链接，未修改。") }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw AppFailure("项目 Claude 配置不是有效 JSON，未修改。")
        }
        return object
    }

    private static func writeSettings(_ project: ProjectBinding, _ object: [String: Any]) throws {
        let file = settings(project)
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        try Disk.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]), to: file)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }

    static func isInstalled(_ project: ProjectBinding) -> Bool {
        ((try? readSettings(project))?["statusLine"] as? [String: Any])?["command"] as? String == command(project)
    }

    /// Puts the project's script in front of whatever status line its configuration had. Changes nothing when it
    /// already is there, apart from the label.
    static func install(_ project: ProjectBinding, accountLabel: String) throws {
        try Disk.directory(state(project))
        try Disk.directory(configuration(project))
        try writeScript(project)
        setLabel(project, text: accountLabel)
        var object = try readSettings(project)
        let current = object["statusLine"] as? [String: Any]
        guard current?["command"] as? String != command(project) else { return }
        let file = settings(project)
        let existed = FileManager.default.fileExists(atPath: file.path)
        if existed, !FileManager.default.fileExists(atPath: backup(project).path) {
            try Disk.write(Data(contentsOf: file), to: backup(project))
        }
        try Disk.write(JSONSerialization.data(withJSONObject: ["statusLine": current.map { $0 as Any } ?? NSNull(), "fileExisted": existed]), to: previous(project))
        if current?["type"] as? String == "command", let before = current?["command"] as? String, !before.isEmpty {
            try Disk.write(Data((before + "\n").utf8), to: chain(project))
        } else {
            try? FileManager.default.removeItem(at: chain(project))
        }
        var next = current ?? [:]
        next["type"] = "command"; next["command"] = command(project)
        object["statusLine"] = next
        try writeSettings(project, object)
    }

    /// Puts the project's previous status line back, if Lilt's is still the one there, and removes Lilt's files for it.
    static func uninstall(_ project: ProjectBinding) throws {
        var object = try readSettings(project)
        if (object["statusLine"] as? [String: Any])?["command"] as? String == command(project) {
            let kept = (try? Data(contentsOf: previous(project))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let before = kept?["statusLine"] as? [String: Any] { object["statusLine"] = before } else { object.removeValue(forKey: "statusLine") }
            if object.isEmpty, kept?["fileExisted"] as? Bool == false { try? FileManager.default.removeItem(at: settings(project)) }
            else { try writeSettings(project, object) }
        }
        for file in [chain(project), previous(project), label(project), script(project)] { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: spool(project))
    }

    static func setLabel(_ project: ProjectBinding, text: String?) {
        if let text { try? Disk.write(Data("Lilt · \(text)".utf8), to: label(project)) }
        else { try? FileManager.default.removeItem(at: label(project)) }
    }

    /// Records only for sessions started on this project's configuration directory.
    private static func writeScript(_ project: ProjectBinding) throws {
        let directory = configuration(project).path
        let condition = #"[ "${CLAUDE_CONFIG_DIR%/}" = "# + shellQuote(directory) + " ]"
        try Disk.write(Data(StatusLineBridge.script(root: state(project).path, spool: spool(project).path, scope: project.eventScope,
                                                    condition: condition, chain: chain(project).path, label: label(project).path).utf8),
                       to: script(project))
    }
}
