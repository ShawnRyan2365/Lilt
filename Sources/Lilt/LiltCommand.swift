import Foundation
import Darwin
import LiltCore

/// `lilt` in a terminal, run by the script `CommandLineInstall` puts on the PATH. It is this app's own binary started
/// with `flag`: it never opens a window, it asks the running Lilt over `ControlSocket` and prints the answer, and it
/// opens Lilt in the background first when Lilt is not running. Lookups work like `ccl`: a number from `lilt ls`, or
/// a name matched exactly, by prefix, inside, or by its letters in order.
enum LiltCommand {
    static let flag = "--lilt-cli"

    static let usage = """
    用法：
      lilt                 列出账号，输入编号或名字选择（可以选多个）
      lilt 001             换到 001 并锁定：用完也不换到别的账号
      lilt 3               按编号选（lilt ls 里的顺序，也是接力顺序）
      lilt ent             按名字选（不分大小写；完全相同 > 编号 > 开头 > 包含 > 缩写）
      lilt 001 002 003     只在这几个账号之间自动接力；当前账号不在其中就先换过去
      lilt all             恢复在全部账号之间接力
      lilt ls              列出账号、额度和接力范围
    """

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "-h", "--help", "help": print(usage); return 0
        case "_names": printNames(); return 0
        case "ls", "list":
            guard arguments.count == 1 else { return fail("ls 后面不带参数。") }
            guard let reply = exchange(ControlRequest(action: "list")) else { return 1 }
            printList(reply); return reply.ok ? 0 : 1
        case "all":
            guard arguments.count == 1 else { return fail("all 后面不带参数；要指定账号就直接写 lilt 001 002。") }
            guard let reply = exchange(ControlRequest(action: "all")) else { return 1 }
            printOutcome(reply); return reply.ok ? 0 : 1
        case nil:
            guard let reply = exchange(ControlRequest(action: "list")) else { return 1 }
            printList(reply)
            guard reply.ok else { return 1 }
            guard isatty(STDIN_FILENO) == 1 else { return 0 }
            print("选择编号或名字（多个用空格隔开，回车取消）: ", terminator: "")
            fflush(stdout)
            let words = (readLine() ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return 0 }
            return use(words, among: reply.accounts ?? [])
        default:
            if let option = arguments.first(where: { $0.hasPrefix("-") }) { return fail("不认识的选项 \(option)；lilt -h 查看用法。") }
            guard let reply = exchange(ControlRequest(action: "list")) else { return 1 }
            guard reply.ok else { printOutcome(reply); return 1 }
            return use(arguments, among: reply.accounts ?? [])
        }
    }

    private static func use(_ words: [String], among accounts: [ControlAccount]) -> Int32 {
        guard !accounts.isEmpty else { return fail("Lilt 里还没有账号。") }
        var ids: [UUID] = []
        for word in words {
            guard let index = resolve(word, among: accounts) else { return 1 }
            if !ids.contains(accounts[index].id) { ids.append(accounts[index].id) }
        }
        guard let reply = exchange(ControlRequest(action: "use", ids: ids)) else { return 1 }
        printOutcome(reply)
        return reply.ok ? 0 : 1
    }

    private static func resolve(_ word: String, among accounts: [ControlAccount]) -> Int? {
        switch AccountQuery.match(word, labels: accounts.map(\.label)) {
        case .one(let index): return index
        case .none:
            _ = fail("没有匹配「\(word)」的账号；运行 lilt ls 查看。"); return nil
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
        // A switch may wait for a token renewal or a slow keychain; two minutes is past anything Lilt would wait.
        ControlSocket.timeout(fd, seconds: 120)
        guard let data = try? JSONEncoder().encode(request), ControlSocket.writeAll(fd, data) else { _ = fail("发送失败。"); return nil }
        shutdown(fd, SHUT_WR)
        guard let line = ControlSocket.readLine(fd), let reply = try? JSONDecoder().decode(ControlReply.self, from: line) else {
            _ = fail("Lilt 没有回应；切换可能仍在进行，稍后用 lilt ls 查看。"); return nil
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
    private static func paint(_ text: String, _ code: String) -> String { colour ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }

    private static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data("lilt: \(text)\n".utf8)); return 1
    }

    private static func printOutcome(_ reply: ControlReply) {
        guard reply.ok else { for line in reply.lines { _ = fail(line) }; return }
        for (index, line) in reply.lines.enumerated() {
            print(index == 0 ? paint("▶", "36") + " " + line : "  " + paint(line, "2"))
        }
    }

    private static func printList(_ reply: ControlReply) {
        guard reply.ok else { printOutcome(reply); return }
        let accounts = reply.accounts ?? []
        guard !accounts.isEmpty else { print("Lilt 里还没有账号；在 Lilt 里添加。"); return }
        var header = "自动接力：" + (reply.autoRelay == true ? "开" : "关")
        if let pool = reply.pool {
            let names = accounts.filter { pool.contains($0.id) }.map(\.label)
            header += names.count == 1 ? " · 已锁定 \(names[0])（lilt all 恢复全部）" : " · 只在 \(names.joined(separator: "、")) 之间接力（lilt all 恢复全部）"
        }
        print(header)
        if let note = reply.relayNote, !note.isEmpty { print(paint(note, "2")) }
        let width = accounts.map { displayWidth($0.label) }.max() ?? 0
        for (index, account) in accounts.enumerated() { print(row(account, number: index + 1, width: width)) }
    }

    private static func row(_ account: ControlAccount, number: Int, width: Int) -> String {
        let name = account.label + String(repeating: " ", count: max(0, width - displayWidth(account.label)))
        let five = "5小时 " + leftPad(percent(account.fiveHour), 4)
        let week = "7天 " + leftPad(account.noWeeklyLimit ? "不限" : percent(account.sevenDay), 4)
        var notes: [String] = []
        if !account.enabled { notes.append("已停用") }
        if account.project { notes.append("项目专用") }
        if account.enabled && !account.project && !account.inPool { notes.append("不接力") }
        if let sampled = account.sampledAt, Date.now.timeIntervalSince(sampled) > 1800 { notes.append(Wording.age(sampled, now: .now)) }
        var line = String(format: "%2d", number) + "  " + name + "  " + paint(five + "  " + week, "2")
        if !notes.isEmpty { line += "  " + paint(notes.joined(separator: " · "), "2") }
        if account.active { line += "  " + paint("← 使用中", "33") }
        return account.enabled ? line : paint(line, "2")
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
