import Foundation
import LiltCore

/// Live quota from Claude Code's own status line, the way ORCA gets it. After every response Claude Code hands its
/// status line command a JSON description of the session, including `rate_limits`. Lilt puts a small script in front
/// of whatever status line was configured: the script keeps only the rate limits, then runs the previous command with
/// the same input, so the terminal shows what it showed before. Nothing else from the session is stored.
enum StatusLineBridge {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var script: URL { Disk.root.appendingPathComponent("statusline.sh") }
    private static var chain: URL { Disk.root.appendingPathComponent("statusline-chain.sh") }
    private static var previous: URL { Disk.root.appendingPathComponent("statusline-previous.json") }
    private static var record: URL { Disk.root.appendingPathComponent("live-usage.json") }
    private static var label: URL { Disk.root.appendingPathComponent("statusline-label.txt") }
    /// A copy of the settings file as it was before Lilt first touched it, kept for good.
    static var backup: URL { Disk.root.appendingPathComponent("claude-settings-before-lilt.json") }
    static var command: String { "/bin/sh " + shellQuote(script.path) }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any] else {
            throw AppFailure("~/.claude/settings.json 不是 Lilt 能读懂的 JSON，没有改动它。")
        }
        return object
    }
    private static func writeSettings(_ object: [String: Any]) throws {
        let mode = (try? FileManager.default.attributesOfItem(atPath: settingsFile.path))?[.posixPermissions] as? NSNumber
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        do { try Disk.write(data, to: settingsFile) } catch { throw AppFailure("无法写入 ~/.claude/settings.json（它可能是符号链接），状态栏没有接上。") }
        // Written atomically with owner-only access; keep whatever access the user had given the file.
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settingsFile.path) }
    }

    /// Lilt's script is the status line Claude Code runs.
    static var isInstalled: Bool { ((try? readSettings())?["statusLine"] as? [String: Any])?["command"] as? String == command }

    /// Put Lilt's script in front of the configured status line. Does nothing to the settings when it already is there.
    static func install() throws {
        try Disk.directory(Disk.root)
        try writeScript()
        var settings = try readSettings()
        let current = settings["statusLine"] as? [String: Any]
        guard current?["command"] as? String != command else { return }
        guard FileManager.default.fileExists(atPath: settingsFile.deletingLastPathComponent().path) else {
            throw AppFailure("找不到 ~/.claude，先运行一次 Claude Code。")
        }
        let existed = FileManager.default.fileExists(atPath: settingsFile.path)
        if existed, !FileManager.default.fileExists(atPath: backup.path) { try Disk.write(Data(contentsOf: settingsFile), to: backup) }
        // Keep what was there, so it still runs and can be put back exactly as it was.
        try Disk.write(JSONSerialization.data(withJSONObject: ["statusLine": current.map { $0 as Any } ?? NSNull(), "fileExisted": existed]), to: previous)
        if current?["type"] as? String == "command", let before = current?["command"] as? String, !before.isEmpty {
            try Disk.write(Data((before + "\n").utf8), to: chain)
        } else {
            try? FileManager.default.removeItem(at: chain)
        }
        var next = current ?? [:]
        next["type"] = "command"; next["command"] = command
        settings["statusLine"] = next
        try writeSettings(settings)
    }

    /// Put the previous status line back, if Lilt's is still the one configured, and remove Lilt's files.
    static func uninstall() throws {
        var settings = try readSettings()
        if (settings["statusLine"] as? [String: Any])?["command"] as? String == command {
            let kept = (try? Data(contentsOf: previous)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let before = kept?["statusLine"] as? [String: Any] { settings["statusLine"] = before } else { settings.removeValue(forKey: "statusLine") }
            // A file Lilt created only for its status line goes again with it.
            if settings.isEmpty, kept?["fileExisted"] as? Bool == false { try? FileManager.default.removeItem(at: settingsFile) }
            else { try writeSettings(settings) }
        }
        for file in [chain, previous, record, label, script] { try? FileManager.default.removeItem(at: file) }
    }

    /// The latest reading a session reported, or nil.
    static func latest() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: record) else { return nil }
        return UsageParser.parseStatusLine(data)
    }

    /// What the status line shows when there was none before Lilt's: the account in use.
    static func setLabel(_ text: String?) {
        if let text { try? Disk.write(Data("Lilt · \(text)".utf8), to: label) } else { try? FileManager.default.removeItem(at: label) }
    }

    private static func writeScript() throws {
        let text = #"""
        #!/bin/sh
        # Installed by Lilt. After every response Claude Code gives its status line the session's rate limits; this keeps
        # only those for Lilt, then runs the status line that was set up before Lilt with the same input, so the terminal
        # shows what it showed before. Turning off live quota in Lilt puts the previous status line back.
        dir="$HOME/Library/Application Support/Lilt"
        input=$(cat)
        if [ -z "${CLAUDE_CONFIG_DIR-}" ] && [ -d "$dir" ]; then
          limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
          if [ -n "$limits" ]; then
            tmp="$dir/.live-usage.$$"
            (umask 077; printf '{"at":%s,"rate_limits":%s}\n' "$(date +%s)" "$limits" > "$tmp") && mv -f "$tmp" "$dir/live-usage.json"
          fi
        fi
        if [ -f "$dir/statusline-chain.sh" ]; then
          printf '%s' "$input" | /bin/sh "$dir/statusline-chain.sh"
        elif [ -f "$dir/statusline-label.txt" ]; then
          cat "$dir/statusline-label.txt"
        fi
        """#
        try Disk.write(Data((text + "\n").utf8), to: script)
    }
}
