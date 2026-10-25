import Foundation
import LiltCore

/// Live quota from Claude Code's own status line, the way ORCA gets it. After every response Claude Code hands its
/// status line command a JSON description of the session, including `rate_limits`. Lilt puts a small script in front
/// of whatever status line was configured: the script keeps only the rate limits, then runs the previous command with
/// the same input, so the terminal shows what it showed before. Nothing else from the session is stored.
enum StatusLineBridge {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var settingsFile: URL { home.appending(path: ".claude/settings.json", directoryHint: .notDirectory) }
    private static var script: URL { Disk.file("statusline.sh") }
    private static var chain: URL { Disk.file("statusline-chain.sh") }
    private static var previous: URL { Disk.file("statusline-previous.json") }
    private static var legacyRecord: URL { Disk.file("live-usage.json") }
    static var spoolDirectory: URL { Disk.file("live-usage-spool") }
    private static var label: URL { Disk.file("statusline-label.txt") }
    /// A copy of the settings file as it was before Lilt first touched it, kept for good.
    static var backup: URL { Disk.file("claude-settings-before-lilt.json") }
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
        for file in [chain, previous, legacyRecord, label, script] { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: spoolDirectory)
    }

    /// Every event the default login's sessions reported since the last call (see `LiveUsageSpool`).
    static func drain() -> LiveUsageBatch {
        LiveUsageSpool.drain(spoolDirectory, scope: LiveUsageEvent.defaultScope)
    }

    /// What the status line shows when there was none before Lilt's: the account in use.
    static func setLabel(_ text: String?) {
        if let text { try? Disk.write(Data("Lilt · \(text)".utf8), to: label) } else { try? FileManager.default.removeItem(at: label) }
    }

    private static func writeScript() throws {
        let condition = #"[ -z "${CLAUDE_CONFIG_DIR-}" ] || [ "${CLAUDE_CONFIG_DIR%/}" = "$HOME/.claude" ]"#
        try Disk.write(Data(script(root: Disk.root.path, spool: spoolDirectory.path, scope: LiveUsageEvent.defaultScope,
                                   condition: condition, chain: chain.path, label: label.path).utf8), to: script)
    }

    /// The status line script for one scope. It keeps only `rate_limits`, writes each report as a file of its own
    /// (a hidden temporary file renamed into place, so concurrent sessions never overwrite one another), drops the
    /// oldest beyond `LiveUsageSpool.maximumEvents` and marks that as a gap, then hands the unchanged input to the
    /// status line that was there before. `condition` limits recording to sessions on this scope's configuration.
    static func script(root: String, spool: String, scope: String, condition: String, chain: String, label: String) -> String {
        let limit = LiveUsageSpool.maximumEvents
        return #"""
        #!/bin/sh
        # Installed by Lilt. Keeps the quota windows of each report and nothing else of the session.
        spool=\#(shellQuote(spool))
        input=$(cat)
        if { \#(condition); } && [ -d \#(shellQuote(root)) ]; then
          limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
          if [ -n "$limits" ]; then
            (umask 077; mkdir -p "$spool")
            id=$(/usr/bin/uuidgen)
            now=$(/bin/date +%s)
            tmp="$spool/.$id.tmp"
            if (umask 077; printf '{"id":"%s","scope":"%s","at":%s,"rate_limits":%s}\n' "$id" \#(shellQuote(scope)) "$now" "$limits" > "$tmp") && /bin/mv -f "$tmp" "$spool/$now-$$-$id.json"; then
              count=$(/bin/ls -1 "$spool" | /usr/bin/grep -c '\.json$')
              if [ "$count" -gt \#(limit) ] && /bin/mkdir "$spool/.lock" 2>/dev/null; then
                /bin/ls -1 "$spool" | /usr/bin/grep '\.json$' | /usr/bin/sort | /usr/bin/head -n "$((count - \#(limit)))" | while IFS= read -r old; do /bin/rm -f "$spool/$old"; done
                : > "$spool/.gap"
                /bin/rmdir "$spool/.lock"
              fi
            else
              /bin/rm -f "$tmp"; : > "$spool/.gap" 2>/dev/null
            fi
          fi
        fi
        if [ -f \#(shellQuote(chain)) ]; then
          printf '%s' "$input" | /bin/sh \#(shellQuote(chain))
        elif [ -f \#(shellQuote(label)) ]; then
          /bin/cat \#(shellQuote(label))
        fi
        """# + "\n"
    }
}
