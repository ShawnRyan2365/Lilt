import Foundation
import LiltCore
import LiltTransfer
import LiltBackend
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

let version = "0.3.0"
let paths = BackendPaths()
let client = LocalSocketClient(paths: paths)

func outputJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data([0x0A]))
}
func send(_ action: String, id: UUID? = nil, label: String? = nil, credential: Data? = nil, identity: Data? = nil, enabled: Bool? = nil, amount: Double? = nil, rootPath: String? = nil, allowShared: Bool = false, passphrase: String? = nil, archive: Data? = nil) async throws -> DaemonResponse {
    let request = DaemonRequest(action: action, id: id, label: label, credential: credential, identity: identity, enabled: enabled, amount: amount,
                                rootPath: rootPath, allowShared: allowShared, passphrase: passphrase, archive: archive)
    let response: DaemonResponse
    do { response = try await client.send(request) }
    catch { throw BackendFailure("无法连接 Lilt daemon（先运行 `lilt service install` 或 `lilt daemon`）；没有执行任何操作。") }
    guard response.ok else { throw BackendFailure(response.error ?? "操作失败。") }
    return response
}
func account(_ selector: String) async throws -> UUID {
    let response = try await send("list")
    guard let accounts = response.library?.accounts else { throw BackendFailure("账号库不可用。") }
    if let id = UUID(uuidString: selector), accounts.contains(where: { $0.id == id }) { return id }
    if let number = Int(selector), number > 0, number <= accounts.count { return accounts[number - 1].id }
    if let match = accounts.first(where: { $0.label == selector }) { return match.id }
    throw BackendFailure("找不到账号“\(selector)”；请用 `lilt list` 查看序号或备注。")
}
func remaining(_ window: UsageWindow?) -> String { window?.remaining.map { String(format: "%.1f%%", $0) } ?? "未知" }
func printLibrary(_ library: Library) {
    if library.accounts.isEmpty { print("还没有账号。运行 `lilt login` 添加完整 OAuth 登录。"); return }
    for (index, account) in library.accounts.enumerated() {
        let active = account.id == library.activeID ? "*" : " "
        let disabled = account.enabled ? "" : " [已停用]"
        let issue = account.issue.map { " · \($0)" } ?? ""
        print("\(active) \(index + 1). \(account.label)\(disabled) · 5小时剩 \(remaining(account.usage?.fiveHour)) · 7天剩 \(remaining(account.usage?.sevenDay))\(issue)")
    }
}
func printStatus(_ response: DaemonResponse) {
    if let library = response.library { printLibrary(library) }
    guard let status = response.status else { return }
    if status.appliedPending { print("凭据已应用，等待会话验证：还没有会话报告新账号的额度。") }
    else if status.sessionConfirmed { print("至少一个会话已报告新账号的额度；其他并发会话是否已接续，Lilt 看不到。") }
    for text in [status.message, status.relayPause, status.scopeIssue, status.scopeUnreadable, status.statusLineIssue, status.lastEvent] {
        if let text, !text.isEmpty { print(text) }
    }
}
func projectLine(_ project: ProjectBinding, _ library: Library?) -> String {
    let account = library?.accounts.first { $0.id == project.accountID }
    let phase = switch project.phase { case .ready: "已应用"; case .preparing: "未完成"; case .conflict: "需处理" }
    var parts = ["\(project.name) [\(phase)]", project.rootPath, "→ \(account?.label ?? "账号不可用")"]
    if let usage = account?.usage {
        parts.append("5小时剩 \(remaining(usage.fiveHour)) · 7天剩 \(remaining(usage.sevenDay))")
        if let thresholds = library?.preferences.thresholds, usage.remainsExhausted(threshold: thresholds, at: .now) {
            parts.append("已到阈值：项目固定账号不会自动换号，需要时手动 rebind")
        }
    }
    if project.appliedPending { parts.append("等待会话验证") }
    if let issue = project.issue { parts.append(issue) }
    return parts.joined(separator: " · ")
}
func printProjects(_ response: DaemonResponse) {
    if let project = response.project {
        print(projectLine(project, response.library))
        let sharing = (response.projects ?? []).filter { $0.accountID == project.accountID && $0.id != project.id }.count
        if sharing > 0 { print("这个账号还固定给另外 \(sharing) 个项目：订阅额度共享，各自续期同一登录。") }
    } else if let projects = response.projects {
        if projects.isEmpty { print("还没有项目绑定。用 `lilt project bind <目录> <账号>` 添加。") }
        for project in projects { print(projectLine(project, response.library)) }
    }
    if let message = response.status?.message { print(message) }
}
func flag(_ name: String, in arguments: [String]) -> Bool { arguments.contains(name) }
func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func positional(_ arguments: [String]) -> [String] {
    var result: [String] = [], skip = false
    for argument in arguments {
        if skip { skip = false; continue }
        if ["--label", "--weekly-threshold", "--project"].contains(argument) { skip = true; continue }
        if argument.hasPrefix("-") { continue }
        result.append(argument)
    }
    return result
}

/// Every argument as given; export and import refuse anything they do not know, such as `--password`.
func positionalExact(_ arguments: [String]) -> [String] { arguments }

func handle(_ request: DaemonRequest, engine: HeadlessEngine) async -> DaemonResponse {
    do {
        var bound: ProjectBinding?
        var catalog: [ProjectBinding]?
        var transfer: TransferSummary?
        switch request.action {
        case "list", "status": break
        case "add":
            guard let data = request.credential else { throw BackendFailure("缺少登录凭据。") }
            let credential = Credential(data: data)
            let count = await engine.snapshot().0.accounts.count
            _ = try await engine.add(credential, identity: request.identity, label: request.label ?? "账号 \(count + 1)", kind: credential.refreshable ? .oauth : .setupToken, replacing: request.id)
        case "takeover": _ = try await engine.takeOver(label: request.label)
        case "release": try await engine.release()
        case "apply":
            guard let id = request.id else { throw BackendFailure("缺少账号。") }
            _ = try await engine.apply(id)
        case "remove":
            guard let id = request.id else { throw BackendFailure("缺少账号。") }
            try await engine.remove(id)
        case "enable", "disable":
            guard let id = request.id else { throw BackendFailure("缺少账号。") }
            try await engine.setEnabled(request.action == "enable", id: id)
        case "rename":
            guard let id = request.id else { throw BackendFailure("缺少账号。") }
            try await engine.rename(request.label ?? "", id: id)
        case "move":
            guard let id = request.id else { throw BackendFailure("缺少账号。") }
            try await engine.move(id, amount: Int(request.amount ?? 0))
        case "refresh":
            if let id = request.id { await engine.refresh(id, manually: true) } else { await engine.refreshAll() }
        case "auto": try await engine.setAuto(request.enabled ?? false)
        case "tick": await engine.tick()
        case "threshold-five": try await engine.setThreshold(request.amount ?? -1, weekly: false)
        case "threshold-week": try await engine.setThreshold(request.amount ?? -1, weekly: true)
        case "auto-sort": try await engine.setStrategy(autoSort: request.enabled, soonerWeekly: nil)
        case "sooner-weekly": try await engine.setStrategy(autoSort: nil, soonerWeekly: request.enabled)
        case "statusline": try await engine.installStatusLine(request.enabled ?? false)
        case "adopt": try await engine.adoptScope()
        case "reclaim": try await engine.reclaimScope()
        case "keep-api": try await engine.keepAPI()
        case "project-list": catalog = try await engine.projectCatalog().projects
        case "project-status":
            guard let root = request.rootPath else { throw BackendFailure("缺少项目目录。") }
            bound = try await engine.projectStatus(rootPath: root)
        case "project-bind", "project-rebind":
            guard let root = request.rootPath, let id = request.id else { throw BackendFailure("缺少项目目录或账号。") }
            if request.action == "project-bind" {
                bound = try await engine.bindProject(rootPath: root, accountID: id, allowShared: request.allowShared == true)
            } else {
                bound = try await engine.rebindProject(rootPath: root, accountID: id, allowShared: request.allowShared == true)
            }
        case "project-unbind":
            guard let root = request.rootPath else { throw BackendFailure("缺少项目目录。") }
            bound = try await engine.unbindProject(rootPath: root)
            catalog = try await engine.projectCatalog().projects
        case "project-launch":
            guard let root = request.rootPath else { throw BackendFailure("缺少项目目录。") }
            let plan = try await engine.projectLaunch(rootPath: root)
            return DaemonResponse(ok: true, launchPlan: plan)
        case "export":
            guard let passphrase = request.passphrase else { throw BackendFailure("缺少口令。") }
            let (archive, summary) = try await engine.exportArchive(passphrase: passphrase)
            return DaemonResponse(ok: true, archive: archive, transfer: summary)
        case "import":
            guard let passphrase = request.passphrase, let archive = request.archive else { throw BackendFailure("缺少归档或口令。") }
            transfer = try await engine.importArchive(archive, passphrase: passphrase)
        default: throw BackendFailure("未知操作。")
        }
        let snapshot = await engine.snapshot()
        let projects = try? await engine.projectCatalog().projects
        return DaemonResponse(ok: true, library: snapshot.0, status: snapshot.1, projects: catalog ?? projects, project: bound, transfer: transfer)
    } catch { return DaemonResponse(ok: false, error: backendReason(error)) }
}

func runDaemon() async throws {
    let engine = try HeadlessEngine(store: BackendStore(paths: paths))
    let server = LocalSocketServer(paths: paths) { request in await handle(request, engine: engine) }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termination.setEventHandler { server.stop() }; termination.resume()
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interruption.setEventHandler { server.stop() }; interruption.resume()
    // Status line events are taken in every second, on their own: a slow usage request or a switch in the full pass
    // never delays them. The full pass (scope check, reads, relay) runs every 15 seconds, every 3 near the threshold.
    let monitor = Task {
        var nextTick = ContinuousClock.now
        while !Task.isCancelled {
            if ContinuousClock.now >= nextTick {
                await engine.startTick()
                nextTick = ContinuousClock.now.advanced(by: .seconds(await engine.monitorInterval))
            }
            await engine.observe()
            try? await Task.sleep(for: .seconds(1))
        }
    }
    defer { monitor.cancel(); termination.cancel(); interruption.cancel() }
    try await server.run()
}

/// Replaces this process with the official CLI, so the project session is the very process the shell started: same
/// pid, terminal, process group, stdin, stdout and stderr, signals and exit status, with nothing in between. Arguments
/// after `--` go to the CLI as they are, never through a shell. Only the configuration directory is set, and the
/// variables that could put another login or provider in its place are removed.
func execOfficialClaude(_ plan: ProjectLaunchPlan, arguments: [String]) throws -> Never {
    guard let executable = OfficialLogin.executable?.path else { throw BackendFailure("未找到官方 Claude Code CLI；没有启动其他命令。") }
    var environment = ProcessInfo.processInfo.environment
    for key in plan.unsetEnvironment { environment.removeValue(forKey: key) }
    environment["CLAUDE_CONFIG_DIR"] = plan.configDirectory
    #if os(macOS)
    // On macOS the CLI keys its keychain item by this directory as well.
    environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = plan.configDirectory
    #endif
    // Started from inside the project the working directory stays where it is; from anywhere else it is the project.
    let root = ProjectBinding.normalizedRoot(plan.rootPath)
    let caller = ProjectBinding.normalizedRoot(FileManager.default.currentDirectoryPath)
    let directory = caller == root || caller.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? caller : root
    guard chdir(directory) == 0 else { throw BackendFailure("无法进入项目目录；没有启动 Claude。") }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    // This runs on a Swift concurrency thread, where libdispatch blocks signals, and the blocked mask survives
    // execve: the CLI would start deaf to Ctrl-C and SIGTERM. It gets the empty mask a shell would give it.
    var unblocked = sigset_t()
    sigemptyset(&unblocked)
    pthread_sigmask(SIG_SETMASK, &unblocked, nil)
    execve(executable, argv, envp)
    throw BackendFailure("无法启动官方 Claude Code CLI；没有回退到默认登录。")
}

func runProject(_ arguments: [String]) async throws -> Never {
    let separator = arguments.firstIndex(of: "--")
    let control = separator.map { Array(arguments[..<$0]) } ?? arguments
    let claudeArguments = separator.map { Array(arguments[arguments.index(after: $0)...]) } ?? []
    guard control.count == 2, control[0] == "--project", !control[1].isEmpty else {
        throw BackendFailure("使用 lilt run --project <目录> [-- <claude 参数>]。")
    }
    let response = try await send("project-launch", rootPath: control[1])
    guard let plan = response.launchPlan else { throw BackendFailure("daemon 没有返回项目启动计划；没有启动 Claude。") }
    try execOfficialClaude(plan, arguments: claudeArguments)
}

/// The passphrase comes from the controlling terminal with echo off, and from nowhere else: not an argument (process
/// lists), not the environment (inherited by children), not a pipe (shell history and scripts).
enum TerminalPassphrase {
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var descriptor: Int32 = -1

    static func read(_ prompt: String) throws -> String {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0 else { throw BackendFailure("需要在交互终端里输入口令；Lilt 不从参数、环境变量或管道读取口令。") }
        defer { close(fd) }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { throw BackendFailure("无法关闭终端回显，没有读取口令。") }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        saved = original; descriptor = fd
        // Interrupted while echo is off, the terminal is put back before the process goes.
        let restore: @convention(c) (Int32) -> Void = { number in
            var original = TerminalPassphrase.saved
            _ = tcsetattr(TerminalPassphrase.descriptor, TCSANOW, &original)
            signal(number, SIG_DFL); raise(number)
        }
        let previous = [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { ($0, signal($0, restore)) }
        defer {
            _ = tcsetattr(fd, TCSANOW, &original)
            for (number, handler) in previous { signal(number, handler) }
            descriptor = -1
        }
        // TCSANOW keeps whatever was typed ahead of the prompt; TCSAFLUSH would throw it away.
        guard tcsetattr(fd, TCSANOW, &quiet) == 0 else { throw BackendFailure("无法关闭终端回显，没有读取口令。") }
        _ = prompt.withCString { write(fd, $0, strlen($0)) }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Foundation.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 || byte == 0x0A || byte == 0x0D { break }
            bytes.append(byte)
            guard bytes.count <= 4096 else { throw BackendFailure("口令过长。") }
        }
        _ = "\n".withCString { write(fd, $0, 1) }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw BackendFailure("口令不是有效的 UTF-8。") }
        return text
    }
}

/// `lilt export <path>`: a new 0600 file, never one that exists, never stdout.
func exportAccounts(_ arguments: [String]) async throws {
    guard arguments.count == 1, let target = arguments.first, !target.hasPrefix("-") else {
        throw BackendFailure("使用 lilt export <新文件路径>。口令只从终端读取；不接受 --password，也不写到标准输出。")
    }
    let url = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: url.path), (try? url.checkResourceIsReachable()) != true else {
        throw BackendFailure("目标文件已存在；导出不会覆盖任何文件。")
    }
    print("导出文件包含可登录凭据。持有文件和口令的人可以使用这些账号；两台机器各自续期同一登录时，先续期的一方可能让另一方的副本失效。")
    let passphrase = try TerminalPassphrase.read("归档口令（至少 \(CredentialTransfer.minimumPassphraseCharacters) 个字符）：")
    let confirmation = try TerminalPassphrase.read("再次输入口令：")
    if let problem = CredentialTransfer.passphraseProblem(passphrase, confirmation: confirmation) { throw BackendFailure(problem) }
    let response = try await send("export", passphrase: passphrase)
    guard let archive = response.archive else { throw BackendFailure("daemon 没有返回归档；没有写入文件。") }
    do { try SecureFiles.create(archive, at: url) }
    catch SecureFileError.exists { throw BackendFailure("目标文件已存在；导出不会覆盖任何文件。") }
    catch { throw BackendFailure("无法写入导出文件；没有留下部分文件。") }
    print("已加密导出 \(response.transfer?.exported ?? 0) 个账号（文件权限 0600）。这不是同步：之后的变化不会跟着更新。")
}

/// `lilt import <path>`: adds accounts, never replaces any, and leaves every running session as it is.
func importAccounts(_ arguments: [String]) async throws {
    guard arguments.count == 1, let source = arguments.first, !source.hasPrefix("-") else {
        throw BackendFailure("使用 lilt import <归档路径>。口令只从终端读取；不接受 --password。")
    }
    let url = URL(fileURLWithPath: source, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0, size <= CredentialTransfer.maximumArchiveBytes, let archive = try? Data(contentsOf: url) else {
        throw BackendFailure("归档不存在、为空或超过大小上限。")
    }
    let passphrase = try TerminalPassphrase.read("归档口令：")
    let response = try await send("import", passphrase: passphrase, archive: archive)
    let summary = response.transfer ?? TransferSummary()
    print("新增 \(summary.added)，跳过 \(summary.skipped)，冲突 \(summary.conflicts)。")
    if summary.added > 0 { print("新账号默认停用，自动接力已关闭；默认登录、项目和正在运行的会话没有改动。确认后用 `lilt enable` 启用。") }
}

func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let json = flag("--json", in: arguments)
    let command = arguments.isEmpty ? "status" : arguments.removeFirst()
    switch command {
    case "help", "--help", "-h":
        print("""
        Lilt — Claude Pro/Max 账号额度与自动接力
        用法：
          lilt login [--label 备注]       官方完整 OAuth 登录
          lilt add-token [--label 备注]   从 stdin 读取 setup-token
          lilt takeover                   接管当前 Claude 默认登录
          lilt list [--json]              账号与额度
          lilt status [--json]            账号、接力与接入状态
          lilt switch <序号|备注|UUID>
          lilt refresh [账号]             刷新一个或全部账号
          lilt auto on|off|once
          lilt enable|disable|remove <账号>   remove 需要 --yes
          lilt rename <账号> --label 新备注
          lilt move <账号> up|down
          lilt project bind <目录> <账号> [--allow-shared]   项目固定账号，独立 Claude 配置
          lilt project list|status [目录] [--json]
          lilt project rebind <目录> <账号> [--allow-shared]
          lilt project unbind <目录>       保留项目配置与登录
          lilt run --project <目录> [-- <claude 参数>]   直接启动官方 claude
          lilt export <新文件>            口令加密导出账号库（口令从终端读取）
          lilt import <归档>              只新增账号，默认停用
          lilt config set five-hour-threshold|seven-day-threshold <0-20>
          lilt config set auto-sort|sooner-weekly on|off
          lilt statusline on|off
          lilt adopt|reclaim|keep-api
          lilt service install|uninstall|status
          lilt daemon                     前台运行守护进程
          lilt release                    停止接管，不退出当前 Claude 登录
        """)
    case "version", "--version": print("Lilt \(version) · Claude Code \(OfficialLogin.version())")
    case "daemon": try await runDaemon()
    case "run": try await runProject(arguments)
    case "export": try await exportAccounts(positionalExact(arguments))
    case "import": try await importAccounts(positionalExact(arguments))
    case "statusline-hook":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var projectID: UUID?
        if let value = option("--project", in: arguments) {
            guard let id = UUID(uuidString: value) else { throw BackendFailure("状态栏项目标识无效。") }
            projectID = id
        }
        FileHandle.standardOutput.write(try LiveUsageBridge.handle(store: BackendStore(paths: paths), input: input, projectID: projectID))
    case "project":
        guard let subcommand = arguments.first else { throw BackendFailure("使用 project bind、list、status、rebind 或 unbind。") }
        arguments.removeFirst()
        let values = positional(arguments)
        let response: DaemonResponse
        switch subcommand {
        case "list":
            guard values.isEmpty else { throw BackendFailure("project list 不接受目录参数。") }
            response = try await send("project-list")
        case "status":
            guard values.count <= 1 else { throw BackendFailure("使用 project status [path]。") }
            response = try await send("project-status", rootPath: values.first ?? ".")
        case "bind", "rebind":
            guard values.count == 2 else { throw BackendFailure("使用 project \(subcommand) <path> <账号> [--allow-shared]。") }
            let id = try await account(values[1])
            response = try await send("project-\(subcommand)", id: id, rootPath: values[0], allowShared: flag("--allow-shared", in: arguments))
        case "unbind":
            guard values.count == 1 else { throw BackendFailure("使用 project unbind <path>。") }
            response = try await send("project-unbind", rootPath: values[0])
        default: throw BackendFailure("未知 project 操作。")
        }
        if json { try outputJSON(response) } else { printProjects(response) }
    case "login":
        _ = try await send("list")
        let result = try OfficialLogin.login(store: BackendStore(paths: paths))
        let response = try await send("add", label: option("--label", in: arguments), credential: result.credential.data, identity: result.identity)
        if json { try outputJSON(response) } else { printStatus(response) }
    case "add-token":
        _ = try await send("list")
        guard positional(arguments).isEmpty else { throw BackendFailure("Token 不能放在命令行参数里；请通过 stdin 输入。") }
        let token = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let credential = try Credential.manual(token)
        let response = try await send("add", label: option("--label", in: arguments), credential: credential.data)
        if json { try outputJSON(response) } else { printStatus(response) }
    case "takeover", "release", "adopt", "reclaim", "keep-api":
        let response = try await send(command, label: option("--label", in: arguments))
        if json { try outputJSON(response) } else { printStatus(response) }
    case "list", "status":
        let response = try await send(command)
        if json { try outputJSON(response) } else { printStatus(response) }
    case "switch", "refresh", "enable", "disable", "remove", "rename", "move":
        let values = positional(arguments)
        if command == "refresh", values.isEmpty {
            let response = try await send("refresh")
            if json { try outputJSON(response) } else { printStatus(response) }
            break
        }
        guard let selector = values.first else { throw BackendFailure("缺少账号。") }
        if command == "remove", !flag("--yes", in: arguments) { throw BackendFailure("删除本地凭据需要显式加 --yes；不会向官方撤销授权。") }
        let id = try await account(selector)
        var response: DaemonResponse
        switch command {
        case "switch": response = try await send("apply", id: id)
        case "refresh": response = try await send("refresh", id: id)
        case "rename": response = try await send("rename", id: id, label: option("--label", in: arguments))
        case "move": response = try await send("move", id: id, amount: values.dropFirst().first == "up" ? -1 : 1)
        default: response = try await send(command, id: id)
        }
        if json { try outputJSON(response) } else { printStatus(response) }
    case "auto":
        guard let value = positional(arguments).first else { throw BackendFailure("使用 auto on、auto off 或 auto once。") }
        if value == "once" {
            let response = try await send("tick")
            if json { try outputJSON(response) } else { printStatus(response) }
        } else {
            guard ["on", "off"].contains(value) else { throw BackendFailure("使用 auto on 或 auto off。") }
            let response = try await send("auto", enabled: value == "on")
            if json { try outputJSON(response) } else { printStatus(response) }
        }
    case "config":
        let values = positional(arguments)
        guard values.count >= 3, values[0] == "set" else { throw BackendFailure("使用 lilt config set <设置> <值>。") }
        let action: String, amount: Double?, enabled: Bool?
        switch values[1] {
        case "five-hour-threshold", "seven-day-threshold":
            guard let value = Double(values[2]) else { throw BackendFailure("阈值必须是数字。") }
            action = values[1] == "five-hour-threshold" ? "threshold-five" : "threshold-week"; amount = value; enabled = nil
        case "auto-sort", "sooner-weekly":
            guard ["on", "off"].contains(values[2]) else { throw BackendFailure("设置值为 on 或 off。") }
            action = values[1]; amount = nil; enabled = values[2] == "on"
        default: throw BackendFailure("未知设置。")
        }
        let response = try await send(action, enabled: enabled, amount: amount)
        if json { try outputJSON(response) } else { printStatus(response) }
    case "statusline":
        guard let value = positional(arguments).first, ["on", "off"].contains(value) else { throw BackendFailure("使用 statusline on 或 off。") }
        let response = try await send("statusline", enabled: value == "on")
        if json { try outputJSON(response) } else { printStatus(response) }
    case "service":
        guard let value = positional(arguments).first else { throw BackendFailure("使用 service install、uninstall 或 status。") }
        switch value {
        case "install": try SystemdService.install(paths: paths); print("已安装并启动 liltd 用户服务。")
        case "uninstall": try SystemdService.uninstall(paths: paths); print("已停止并移除 liltd 用户服务；账号和当前登录未删除。")
        case "status": print(try SystemdService.status())
        default: throw BackendFailure("未知 service 操作。")
        }
    default: throw BackendFailure("未知命令“\(command)”；运行 `lilt help` 查看用法。")
    }
}

do { try await run() }
catch {
    FileHandle.standardError.write(Data(("Lilt: \(backendReason(error))\n").utf8))
    exit(1)
}
