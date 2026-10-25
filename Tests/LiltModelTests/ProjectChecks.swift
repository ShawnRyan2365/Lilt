import Foundation
import LiltCore

@MainActor
func projectChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"), "Project checks require the isolated model-check home")
    let rootA = home.appendingPathComponent("Project A ' 项目", isDirectory: true)
    let rootB = home.appendingPathComponent("Project B", isDirectory: true)
    try SecureFiles.directory(rootA)
    try SecureFiles.directory(rootB)
    let accountA = UUID(), accountB = UUID()
    var a = ProjectBinding(name: "A", rootPath: rootA.path, accountID: accountA, phase: .ready)
    let b = ProjectBinding(name: "B", rootPath: rootB.path, accountID: accountB, phase: .ready)
    let validated = try ProjectSupport.validate(root: rootA.path)
    precondition(validated.root == ProjectBinding.normalizedRoot(rootA.path) && validated.name == rootA.lastPathComponent)
    let catalog = ProjectCatalog(projects: [a, b])
    precondition(catalog.reservedAccountIDs == [accountA, accountB])
    precondition(catalog.binding(rootPath: rootA.path)?.id == a.id)

    let command = RuntimeScope(project: a).launchCommand(executable: "/fixture/Claude Code/claude", arguments: ["--resume", "fixture session", "$(touch pwned)"])
    precondition(command.hasPrefix("cd "), "Project launch must preserve its working directory")
    precondition(command.contains("CLAUDE_CONFIG_DIR=") && command.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR="))
    precondition(command.contains("'--resume' 'fixture session' '$(touch pwned)'") && !command.contains("fixture-access"))
    precondition(command.contains("-u CLAUDE_CODE_OAUTH_TOKEN") && command.contains("-u ANTHROPIC_API_KEY") && command.contains("exec env"))
    // The shell takes the command apart into exactly the arguments given, and runs nothing they contain.
    let echo = Process(), echoed = Pipe()
    echo.executableURL = URL(fileURLWithPath: "/bin/sh")
    let probe = RuntimeScope(project: a).launchCommand(executable: "/usr/bin/printf", arguments: ["%s|", "fixture session", "$(touch pwned)", "it's"])
    echo.arguments = ["-c", probe]; echo.standardOutput = echoed; echo.currentDirectoryURL = home
    try echo.run(); echo.waitUntilExit()
    precondition(String(decoding: echoed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "fixture session|$(touch pwned)|it's|")
    precondition(!FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path) && !FileManager.default.fileExists(atPath: rootA.appendingPathComponent("pwned").path))
    a.rootPath = rootB.path
    precondition(ProjectBinding.normalizedRoot(a.rootPath) == rootB.path)

    var heldA: Data?, heldB: Data?
    let scopeA = RuntimeScope(fixtureHome: home, project: ProjectBinding(name: "A", rootPath: rootA.path, accountID: accountA), credentials: .init(read: { heldA }, write: { heldA = $0 }, delete: { heldA = nil }))
    let scopeB = RuntimeScope(fixtureHome: home, project: b, credentials: .init(read: { heldB }, write: { heldB = $0 }, delete: { heldB = nil }))
    func credential(_ name: String) -> Credential {
        Credential(data: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-access-\(name)", "refreshToken": "fixture-refresh-\(name)", "expiresAt": 4_102_444_800_000.0, "scopes": ["user:profile", "user:inference"]]]))
    }
    try scopeA.apply(credential("A"))
    precondition(heldA != nil && heldB == nil, "Applying A must not touch B")
    let firstA = heldA
    try scopeB.apply(credential("B"))
    precondition(heldA == firstA && heldB != nil, "Applying B must not touch A")
    let signalA = try Data(contentsOf: scopeA.directory.appendingPathComponent(".credentials.json"))
    let signalB = try Data(contentsOf: scopeB.directory.appendingPathComponent(".credentials.json"))
    precondition(signalA == RuntimeScope.signal && signalB == RuntimeScope.signal)
    try scopeA.check()
    try scopeB.check()
    heldB = credential("outside").data
    precondition(throws: try scopeB.check())
    try scopeA.check()

    // The project's script records only sessions on the project's configuration, keeps only the rate limits, and
    // still runs the status line the project had before.
    let configuration = RuntimeScope(project: b).directory
    try SecureFiles.directory(configuration)
    try Data(#"{"statusLine":{"type":"command","command":"cat >/dev/null; printf fixture-previous"},"model":"fixture"}"#.utf8)
        .write(to: configuration.appendingPathComponent("settings.json"))
    try ProjectStatusLineBridge.install(b, accountLabel: "Fixture B")
    precondition(ProjectStatusLineBridge.isInstalled(b))
    let state = home.appendingPathComponent("Library/Application Support/Lilt/projects/\(b.id.uuidString)/state", isDirectory: true)
    let script = state.appendingPathComponent("statusline.sh")
    func run(configDirectory: String?) throws -> String {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        if let configDirectory { environment["CLAUDE_CONFIG_DIR"] = configDirectory }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let eventInput = #"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":4102444800}},"session_id":"fixture-do-not-store"}"#
        input.fileHandleForWriting.write(Data(eventInput.utf8)); try? input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: printed, as: UTF8.self)
    }
    let outside = try run(configDirectory: nil)
    precondition(outside == "fixture-previous", "the project's previous status line did not run")
    precondition(!LiveUsageSpool.hasPending(ProjectStatusLineBridge.spool(b)), "a session on another configuration was recorded")
    let inside = try run(configDirectory: configuration.path)
    precondition(inside == "fixture-previous")
    let eventFiles = try FileManager.default.contentsOfDirectory(at: ProjectStatusLineBridge.spool(b), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    precondition(eventFiles.count == 1)
    let eventText = String(decoding: try Data(contentsOf: eventFiles[0]), as: UTF8.self)
    precondition(!eventText.contains("session_id") && !eventText.contains("fixture-do-not-store"))
    let batch = LiveUsageSpool.drain(ProjectStatusLineBridge.spool(b), scope: b.eventScope)
    precondition(batch.events.count == 1 && batch.events[0].snapshot.fiveHour?.used == 42 && !batch.hasGaps)
    try ProjectStatusLineBridge.uninstall(b)
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration.appendingPathComponent("settings.json"))) as! [String: Any]
    precondition((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat >/dev/null; printf fixture-previous" && restored["model"] as? String == "fixture")
    try FileManager.default.removeItem(at: rootA)
    try FileManager.default.removeItem(at: rootB)
    print("PASS: project scopes — launch command quoting and injection, A/B scopes independent with in-memory keychains, signal-only file, outside change refused, per-project status line recording only its own sessions and restored on removal.")
}

private func precondition(throws body: @autoclosure () throws -> Void, file: StaticString = #file, line: UInt = #line) {
    do { try body(); preconditionFailure("Expected project scope check to fail", file: file, line: line) } catch {}
}
