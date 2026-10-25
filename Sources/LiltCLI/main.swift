import Foundation
import LiltCore
import LiltBackend

let version = "0.2.5"
let paths = BackendPaths()
let client = LocalSocketClient(paths: paths)

func outputJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data([0x0A]))
}
func send(_ action: String, id: UUID? = nil, label: String? = nil, credential: Data? = nil, identity: Data? = nil, enabled: Bool? = nil, amount: Double? = nil) async throws -> DaemonResponse {
    let response = try await client.send(DaemonRequest(action: action, id: id, label: label, credential: credential, identity: identity, enabled: enabled, amount: amount))
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
    if let applied = status.appliedPending ? "凭据已应用；等待状态栏确认新账号读数" : nil { print(applied) }
    for text in [status.message, status.relayPause, status.scopeIssue, status.scopeUnreadable, status.statusLineIssue, status.lastEvent] {
        if let text, !text.isEmpty { print(text) }
    }
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
        if ["--label", "--weekly-threshold"].contains(argument) { skip = true; continue }
        if argument.hasPrefix("-") { continue }
        result.append(argument)
    }
    return result
}

func handle(_ request: DaemonRequest, engine: HeadlessEngine) async -> DaemonResponse {
    do {
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
        default: throw BackendFailure("未知操作。")
        }
        let snapshot = await engine.snapshot()
        return DaemonResponse(ok: true, library: snapshot.0, status: snapshot.1)
    } catch { return DaemonResponse(ok: false, error: backendReason(error)) }
}

func runDaemon() async throws {
    let engine = try HeadlessEngine(store: BackendStore(paths: paths))
    let server = LocalSocketServer(paths: paths) { request in await handle(request, engine: engine) }
    #if canImport(Darwin)
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    #else
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    #endif
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termination.setEventHandler { server.stop() }; termination.resume()
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interruption.setEventHandler { server.stop() }; interruption.resume()
    let monitor = Task {
        while !Task.isCancelled {
            await engine.tick()
            let interval = await engine.monitorInterval
            try? await Task.sleep(for: .seconds(interval))
        }
    }
    defer { monitor.cancel(); termination.cancel(); interruption.cancel() }
    try await server.run()
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
    case "statusline-hook":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        FileHandle.standardOutput.write(try LiveUsageBridge.handle(store: BackendStore(paths: paths), input: input))
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
