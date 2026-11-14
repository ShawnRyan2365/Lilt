import Foundation
import Darwin
import LiltCore

/// `lilt` in a terminal, run by the script `CommandLineInstall` puts on the PATH. It is this app's own binary started
/// with `flag`: it never opens a window. `lilt 001` asks the running Lilt for a terminal session on that account
/// (`AppModel.startSession`), then replaces itself with Claude Code on the session's own login, in this terminal, the
/// way `ccl` starts a provider. The default login is not touched. Lilt is opened in the background first when it is
/// not running. Accounts are found like `ccl` finds a provider: a number from `lilt ls`, or a name matched exactly,
/// by prefix, inside, or by its letters in order.
enum LiltCommand {
    static let flag = "--lilt-cli"

    static let usage = """
    用法：
      lilt                 列出账号，输入编号或名字，在这个终端打开独立会话
      lilt 001             用 001 在这个终端打开独立的 Claude Code 会话，不动本机默认登录
      lilt 3 -c            按编号选（lilt ls 里的顺序）；从第一个 - 开头的参数起原样交给 claude
      lilt ent             按名字选（不分大小写；完全相同 > 编号 > 开头 > 包含 > 缩写）
      lilt 001 002 003     独立会话在这几个账号之间自动接力，先用写在前面的
      lilt 001 -- 提示词    -- 后面的全部交给 claude
      lilt ls              列出账号、额度和正在运行的独立会话
      lilt bypass on|off   开/关自动跳过权限确认（--dangerously-skip-permissions），默认开
      lilt 001 --permission-mode default   只这一次不跳过权限确认
      lilt -n 001          只打印将要执行的命令，不启动
    独立会话共用 ~/.claude 的设置、MCP 和历史，只有登录是它自己的；同一个账号同时只给一个会话用。
    """

    static func run(_ arguments: [String]) -> Int32 {
        var arguments = arguments
        var dry = false
        switch arguments.first {
        case "-h", "--help", "help": print(usage); return 0
        case "_names": printNames(); return 0
        case "ls", "list":
            guard arguments.count == 1 else { return fail("ls 后面不带参数。") }
            guard let reply = exchange(ControlRequest(action: "list")) else { return 1 }
            guard reply.ok else { printOutcome(reply); return 1 }
            printBypass(reply.bypass ?? true); printList(reply); return 0
        case "bypass":
            let value: Bool?
            switch arguments.count > 1 ? arguments[1] : nil {
            case "on": value = true
            case "off": value = false
            case nil: value = nil
            default: return fail("用法：lilt bypass on|off")
            }
            guard arguments.count <= 2 else { return fail("用法：lilt bypass on|off") }
            guard let reply = exchange(ControlRequest(action: "bypass", bypass: value)) else { return 1 }
            guard reply.ok else { printOutcome(reply); return 1 }
            printBypass(reply.bypass ?? true); return 0
        case "-n", "--dry-run": dry = true; arguments.removeFirst()
        default: break
        }
        let (selectors, passthrough) = SessionRules.split(arguments)
        guard let claude = claudeExecutable() else { return fail("找不到 claude；先安装 Claude Code。") }
        guard let list = exchange(ControlRequest(action: "list")) else { return 1 }
        guard list.ok else { printOutcome(list); return 1 }
        let accounts = list.accounts ?? []
        guard !accounts.isEmpty else { return fail("Lilt 里还没有账号；先在 Lilt 里添加。") }
        var words = selectors
        if words.isEmpty {
            guard isatty(STDIN_FILENO) == 1 else { return fail("要指定账号，比如 lilt 001；或者在终端里直接运行 lilt 选择。") }
            printBypass(list.bypass ?? true); printList(list)
            print("选择编号或名字（多个用空格隔开，在它们之间接力；回车取消）: ", terminator: "")
            fflush(stdout)
            words = (readLine() ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return 0 }
        }
        var ids: [UUID] = []
        for word in words {
            guard let index = resolve(word, among: accounts, typed: !selectors.isEmpty) else { return 1 }
            if !ids.contains(accounts[index].id) { ids.append(accounts[index].id) }
        }
        if dry {
            let directory = RuntimeScope(session: SessionRules.scopeID(pool: ids)).directory.path
            let (arguments, _) = SessionRules.claudeArguments(passthrough, bypass: list.bypass ?? true)
            let names = ids.compactMap { id in accounts.first { $0.id == id }?.label }.joined(separator: "、")
            print("账号：\(names)")
            print((["env"] + ProjectRules.clearedEnvironment.map { "-u \($0)" } + ["CLAUDE_SECURESTORAGE_CONFIG_DIR=" + shellQuote(directory), shellQuote(claude)]
                   + arguments.map(shellQuote)).joined(separator: " "))
            return 0
        }
        guard let reply = exchange(ControlRequest(action: "session", ids: ids)) else { return 1 }
        guard reply.ok, let launch = reply.launch else { printOutcome(reply); return 1 }
        return start(claude, launch, passthrough: passthrough)
    }

    /// Replaces this process with Claude Code on the session's login. Only on failure does it return.
    private static func start(_ claude: String, _ launch: ControlLaunch, passthrough: [String]) -> Int32 {
        var environment = ProcessInfo.processInfo.environment
        // A token, provider or configuration directory in the shell would win over the session's login.
        for key in ProjectRules.clearedEnvironment { environment.removeValue(forKey: key) }
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = launch.secureDirectory
        let (arguments, bypassed) = SessionRules.claudeArguments(passthrough, bypass: launch.bypass)
        var detail = "独立会话"
        if launch.pool.count > 1 { detail += " · 在 \(launch.pool.joined(separator: "、")) 间接力" }
        if launch.joined { detail += " · 和已开的终端共用" }
        var line = paint("▶", "36", stderr: true) + " " + launch.account + "  " + paint(detail, "2", stderr: true)
        if bypassed { line += "  " + paint("⚡ 跳过权限确认", "31", stderr: true) }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let argv = ([claude] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(claude, argv, envp)
        let code = errno
        return fail("没能启动 claude（\(String(cString: strerror(code)))）。")
    }

    /// `claude` as this shell finds it, the way `ccl` runs it; the usual install places when the PATH has none.
    private static func claudeExecutable() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = String(directory) + "/claude"
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 { return candidate }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first { access($0, X_OK) == 0 }
    }

    private static func resolve(_ word: String, among accounts: [ControlAccount], typed: Bool) -> Int? {
        switch AccountQuery.match(word, labels: accounts.map(\.label)) {
        case .one(let index): return index
        case .none:
            let hint = typed ? "要把它交给 claude，写在 -- 后面：lilt <账号> -- \(word)" : "运行 lilt ls 查看。"
            _ = fail("没有匹配「\(word)」的账号；\(hint)"); return nil
        case .several(let hits):
            guard isatty(STDIN_FILENO) == 1 else {
                _ = fail("「\(word)」匹配到多个账号：\(hits.map { accounts[$0].label }.joined(separator: "、"))；写完整一些。"); return nil
            }
            print("「\(word)」匹配到多个：")
            let width = hits.map { displayWidth(accounts[$0].label) }.max() ?? 0
            for index in hits { print(row(accounts[index], number: index + 1, width: width)) }
            print("选择编号: ", terminator: ""); fflush(stdout)
            guard let answer = readLine().flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), hits.contains(answer - 1) else {
                _ = fail("无效编号。"); return nil
            }
            return answer - 1
        }
    }

    // MARK: Talking to the app

    /// One request and its reply, opening Lilt first if it is not running. Nil after printing why it failed.
    private static func exchange(_ request: ControlRequest) -> ControlReply? {
        var connection = ControlSocket.connect(ControlSocket.path)
        if case .failure(let error) = connection, error.code == ENOENT || error.code == ECONNREFUSED {
            guard launchApp() else { _ = fail("Lilt 没在运行；先打开 Lilt。"); return nil }
            let deadline = Date.now.addingTimeInterval(20)
            repeat {
                usleep(250_000)
                connection = ControlSocket.connect(ControlSocket.path)
                if case .success = connection { break }
            } while Date.now < deadline
        }
        guard case .success(let fd) = connection else { _ = fail("连不上 Lilt；确认 Lilt 已打开并且版本支持 lilt 命令。"); return nil }
        defer { close(fd) }
        // A session may wait for a token renewal or a slow keychain; two minutes is past anything Lilt would wait.
        ControlSocket.timeout(fd, seconds: 120)
        guard let data = try? JSONEncoder().encode(request), ControlSocket.writeAll(fd, data) else { _ = fail("发送失败。"); return nil }
        shutdown(fd, SHUT_WR)
        guard let line = ControlSocket.readLine(fd), let reply = try? JSONDecoder().decode(ControlReply.self, from: line) else {
            _ = fail("Lilt 没有回应；稍后用 lilt ls 查看。"); return nil
        }
        return reply
    }

    /// Opens this copy of Lilt in the background. Only a packaged app can do so; `swift run` has no bundle to open.
    private static func launchApp() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        // `open` does not pass this process's environment on: under a fake home the copy it opened would run against
        // the real one, beside the Lilt already managing it.
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil else { return false }
        FileHandle.standardError.write(Data("lilt: Lilt 没在运行，正在打开…\n".utf8))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", bundle.path]
        do { try open.run(); open.waitUntilExit() } catch { return false }
        return open.terminationStatus == 0
    }

    /// For shell completion: the names alone, from the account file, without starting Lilt.
    private static func printNames() {
        guard let data = try? Data(contentsOf: Disk.file("accounts.json")),
              let library = try? JSONDecoder().decode(Library.self, from: data) else { return }
        for account in library.accounts { print(account.label) }
    }

    // MARK: Output

    private static let colour = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    private static let colourErrors = isatty(STDERR_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    private static func paint(_ text: String, _ code: String, stderr: Bool = false) -> String {
        (stderr ? colourErrors : colour) ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data("lilt: \(text)\n".utf8)); return 1
    }

    private static func printOutcome(_ reply: ControlReply) {
        guard reply.ok else { for line in reply.lines { _ = fail(line) }; return }
        for line in reply.lines { print(line) }
    }

    private static func printBypass(_ on: Bool) {
        print(on ? paint("⚡ 跳过权限确认：开", "31") + paint("（lilt bypass off 关闭）", "2") : paint("跳过权限确认：关（lilt bypass on 打开）", "2"))
    }

    private static func printList(_ reply: ControlReply) {
        let accounts = reply.accounts ?? []
        guard !accounts.isEmpty else { print("Lilt 里还没有账号；在 Lilt 里添加。"); return }
        let width = accounts.map { displayWidth($0.label) }.max() ?? 0
        for (index, account) in accounts.enumerated() { print(row(account, number: index + 1, width: width)) }
        for session in reply.sessions ?? [] {
            var line = "独立会话：" + (session.holding ?? "准备中")
            if session.pool.count > 1 { line += " · 在 \(session.pool.joined(separator: "、")) 间接力" }
            line += session.terminals > 0 ? " · \(session.terminals) 个终端" : " · 已结束，正在收尾"
            print(paint(line, "36"))
            if let note = session.note { print("  " + paint(note, "2")) }
        }
    }

    private static func row(_ account: ControlAccount, number: Int, width: Int) -> String {
        let name = account.label + String(repeating: " ", count: max(0, width - displayWidth(account.label)))
        let five = "5小时 " + leftPad(percent(account.fiveHour), 4)
        let week = "7天 " + leftPad(account.noWeeklyLimit ? "不限" : percent(account.sevenDay), 4)
        var notes: [String] = []
        if !account.enabled { notes.append("已停用") }
        if account.project { notes.append("项目专用") }
        if account.sessionSpare { notes.append("会话备用") }
        if let sampled = account.sampledAt, Date.now.timeIntervalSince(sampled) > 1800 { notes.append(Wording.age(sampled, now: .now)) }
        var line = String(format: "%2d", number) + "  " + name + "  " + paint(five + "  " + week, "2")
        if !notes.isEmpty { line += "  " + paint(notes.joined(separator: " · "), "2") }
        if account.sessionHeld { line += "  " + paint("← 独立会话", "36") }
        if account.active { line += "  " + paint("← 默认登录", "33") }
        return account.enabled || account.sessionHeld ? line : paint(line, "2")
    }

    private static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private static func leftPad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - displayWidth(text))) + text
    }
    /// Terminal columns: Chinese, Japanese, Korean and full-width characters take two.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return total + (wide ? 2 : 1)
        }
    }
}

/// Puts `lilt` on the PATH: a small script at `~/.local/bin/lilt` that runs this app's binary as the command. It is
/// written only where nothing else is, or over a script of Lilt's own, and follows the app when it moves.
enum CommandLineInstall {
    static var target: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/lilt", directoryHint: .notDirectory) }
    static let marker = "# Written by Lilt.app (设置 → 命令行). Lilt rewrites it when the app moves."
    enum State: Equatable { case unavailable, absent, installed, moved, foreign }

    /// Only a packaged app has a stable binary for the script to run.
    static var executable: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.executablePath
    }
    static func script(for executable: String) -> String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/sh\n\(marker)\nexec \(quoted) \(LiltCommand.flag) \"$@\"\n"
    }
    static func state() -> State {
        guard let executable else { return .unavailable }
        let path = target.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return .absent }
        guard info.st_mode & S_IFMT == S_IFREG, let text = try? String(contentsOf: target, encoding: .utf8), text.contains(marker) else { return .foreign }
        return text == script(for: executable) ? .installed : .moved
    }
    static func install() throws {
        guard let executable else { throw AppFailure("只有打包好的 Lilt.app 才能安装 lilt 命令。") }
        let current = state()
        guard current != .foreign else { throw AppFailure("~/.local/bin/lilt 已经是别的程序，没有覆盖。") }
        guard current != .installed else { return }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".lilt.\(UUID().uuidString)", directoryHint: .notDirectory)
        try Data(script(for: executable).utf8).write(to: temporary)
        guard chmod(temporary.path, 0o755) == 0, rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw AppFailure("没能写入 ~/.local/bin/lilt。")
        }
    }
    static func uninstall() throws {
        guard [.installed, .moved].contains(state()) else { return }
        try FileManager.default.removeItem(at: target)
    }
    /// A script of Lilt's own that still points at where the app used to be is pointed here.
    static func followMove() { if state() == .moved { try? install() } }
}
