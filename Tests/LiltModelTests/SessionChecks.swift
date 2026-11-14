import Foundation
import LiltCore

/// In-memory keychain items for terminal session scopes, one per session id.
final class SessionKeychains: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: Data] = [:]
    var items: [UUID: Data] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func scope(_ id: UUID) -> RuntimeScope {
        RuntimeScope(session: id, fixtureHome: FileManager.default.homeDirectoryForCurrentUser, credentials: .init(
            read: { self.items[id] }, write: { data in self.items[id] = data }, delete: { self.items[id] = nil }))
    }
}

/// `lilt <account>…` through the live model, on fixture accounts and in-memory keychains: a session gets a scope of its
/// own and never touches the default login; its accounts are out of the default login's reach while it lasts; the same
/// accounts join one session; a pool hands off when the account in use runs low, keeping what the session's CLI
/// renewed; and once its terminals are gone the login is read back and the scope cleared.
@MainActor func sessionChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var main = Account(label: "Fixture default", kind: .oauth); main.usage = fixtureUsage(60); main.usageCapability = .verified
    var first = Account(label: "Fixture S1", kind: .oauth); first.usage = fixtureUsage(70); first.usageCapability = .verified
    var second = Account(label: "Fixture S2", kind: .oauth); second.usage = fixtureUsage(90); second.usageCapability = .verified
    var third = Account(label: "Fixture S3", kind: .oauth); third.usage = fixtureUsage(80); third.usageCapability = .verified
    third.enabled = false
    var library = Library()
    library.accounts = [main, first, second, third]; library.activeID = main.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    for (account, name) in [(main, "session-main"), (first, "session-s1"), (second, "session-s2"), (third, "session-s3")] {
        try AccountVault.write(fixtureLogin(name), account: account.id.uuidString)
        try AccountVault.write(fixtureIdentity(name), account: Keychain.identityAccount(account.id))
    }
    var held: Data? = fixtureLogin("session-main")
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0 }, delete: { held = nil }))
    try scope.rebaseline()
    let keychains = SessionKeychains()
    var alive: Set<Int32> = [101, 102]
    let model = AppModel(fixture: library, runtime: scope, usageFetch: { _ in throw UsageFailure.network },
                         identityFetch: { _ in nil }, sessionRuntime: { keychains.scope($0) }, leaseAlive: { alive.contains($0.pid) })
    let defaultBefore = held

    // The default login's account, or nothing at all, is refused.
    var reply = await model.startSession([main.id], lease: SessionLease(pid: 101, started: 1))
    precondition(!reply.ok && reply.lines[0].contains("默认登录"), "a session took the default login's account")
    reply = await model.startSession([first.id], lease: nil)
    precondition(!reply.ok)

    // Two accounts: the first listed is written into a scope of the session's own; the default login is untouched.
    reply = await model.startSession([first.id, second.id], lease: SessionLease(pid: 101, started: 1))
    let id = SessionRules.scopeID(pool: [first.id, second.id])
    guard reply.ok, let launch = reply.launch else { preconditionFailure("session did not start: \(reply.lines)") }
    precondition(launch.secureDirectory == keychains.scope(id).directory.path && launch.account == "Fixture S1" && !launch.joined && launch.bypass)
    precondition(keychains.items[id] == fixtureLogin("session-s1") && held == defaultBefore, "session wrote the wrong place")
    let signal = keychains.scope(id).directory.appendingPathComponent(".credentials.json")
    precondition((try? Data(contentsOf: signal)) == RuntimeScope.signal, "a session's file must only be the signal")
    precondition(model.sessionCatalog.session(id: id)?.holding == first.id && model.reservedAccountIDs.isSuperset(of: [first.id, second.id]))
    precondition(model.heldByCLI(first.id) && !model.heldByCLI(second.id), "only the account in the scope is the CLI's to renew")
    precondition((try? Data(contentsOf: Disk.file("sessions.json"))) != nil, "sessions.json not written")

    // Its accounts stay out of the default login and cannot be deleted or fixed to a project meanwhile.
    let taken = await model.apply(second.id)
    precondition(!taken && held == defaultBefore, "the default login took a session's spare account")
    model.remove(first.id)
    precondition(model.library.accounts.contains { $0.id == first.id }, "an account in a session was removed")
    let root = home.appendingPathComponent("Session Project", isDirectory: true)
    try SecureFiles.directory(root)
    let bound = await model.bindProject(root: root.path, accountID: second.id, allowShared: true)
    precondition(!bound, "a session's account was fixed to a project")
    try? FileManager.default.removeItem(at: root)
    precondition(model.relayBlocker == "还需要一个能读额度的备用账号（项目和独立会话用着的不算）", "session accounts counted as spares")

    // An account already in another session is refused; the same accounts in another order join the first.
    reply = await model.startSession([second.id, third.id], lease: SessionLease(pid: 102, started: 2))
    precondition(!reply.ok && reply.lines[0].contains("另一个独立会话"), "one account in two sessions")
    reply = await model.startSession([second.id, first.id], lease: SessionLease(pid: 102, started: 2))
    precondition(reply.ok && reply.launch?.joined == true && reply.launch?.account == "Fixture S1", "the same accounts did not join")
    precondition(model.sessionCatalog.sessions.count == 1 && model.sessionCatalog.session(id: id)?.leases.count == 2)
    let list = model.commandLineList()
    precondition(list.accounts?.first { $0.id == first.id }?.sessionHeld == true && list.accounts?.first { $0.id == second.id }?.sessionSpare == true)
    precondition(list.sessions?.first?.terminals == 2 && list.sessions?.first?.holding == "Fixture S1")

    // The session's CLI renewed S1 (same refresh token); S1 then runs low and the pool hands off to S2. The renewal is
    // kept, and S2's login goes into the session's scope only.
    var renewed = try JSONSerialization.jsonObject(with: fixtureLogin("session-s1")) as! [String: Any]
    var oauth = renewed["claudeAiOauth"] as! [String: Any]
    oauth["accessToken"] = "fixture-access-session-s1-renewed"; oauth["expiresAt"] = 4_102_444_900_000.0
    renewed["claudeAiOauth"] = oauth
    let renewedLogin = try JSONSerialization.data(withJSONObject: renewed)
    keychains.items[id] = renewedLogin
    model.update(first.id) { $0.usage = fixtureUsage(0.5) }
    await model.relaySessions()
    precondition(model.sessionCatalog.session(id: id)?.holding == second.id, "the pool did not hand off: \(model.sessionCatalog.session(id: id)?.note ?? "")")
    precondition(keychains.items[id] == fixtureLogin("session-s2") && held == defaultBefore)
    let keptRenewal = try AccountVault.read(account: first.id.uuidString)
    precondition(keptRenewal == renewedLogin, "the session's renewal was lost")
    precondition(!model.heldByCLI(first.id) && model.heldByCLI(second.id))

    // With nothing left to hand off to, the session waits and says why.
    model.update(second.id) { $0.usage = fixtureUsage(0.5) }
    model.update(first.id) { $0.usage = fixtureUsage(0.5) }
    await model.relaySessions()
    precondition(model.sessionCatalog.session(id: id)?.holding == second.id && model.sessionCatalog.session(id: id)?.note != nil)

    // Permission prompts: on by default, off when turned off, and the launch says so.
    model.setSessionBypass(false)
    alive = [101, 102, 103]
    reply = await model.startSession([first.id, second.id], lease: SessionLease(pid: 103, started: 3))
    precondition(reply.launch?.bypass == false && !model.sessionBypass)
    model.setSessionBypass(true)

    // The terminals end: the login is read back and the scope cleared, and the accounts are free again.
    alive = []
    await model.reapSessions()
    precondition(model.sessionCatalog.sessions.isEmpty && keychains.items[id] == nil, "an ended session kept its scope")
    precondition(!FileManager.default.fileExists(atPath: RuntimeScope.sessionBase(id).path) && model.reservedAccountIDs.isEmpty)
    let keptSecond = try AccountVault.read(account: second.id.uuidString)
    precondition(keptSecond == fixtureLogin("session-s2"))

    // An account switched off for the default login can still be named for a session of its own.
    alive = [104]
    reply = await model.startSession([third.id], lease: SessionLease(pid: 104, started: 4))
    precondition(reply.ok && keychains.items[SessionRules.scopeID(pool: [third.id])] == fixtureLogin("session-s3"))
    alive = []
    await model.reapSessions()
    precondition(model.sessionCatalog.sessions.isEmpty)
    print("PASS: terminal sessions — own scope and signal, default login untouched, default-login account refused, accounts reserved from default relay, deletion and projects, one account per session, same accounts join, pool hand-off keeping the CLI's renewal, waiting with a reason, permission bypass setting, read back and cleared when terminals end.")
}

/// The default status line script tells sessions apart: Lilt's own terminal sessions record into their own spool and
/// show their own account, any other separate login records nothing, and everything else is the default login.
func sessionStatusLineChecks() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent("Library/Application Support/Lilt", isDirectory: true)
    try SecureFiles.directory(root)
    let id = UUID()
    let base = RuntimeScope.sessionBase(id)
    try SecureFiles.directory(base.appendingPathComponent("secure", isDirectory: true))
    try Data("Lilt · Fixture S".utf8).write(to: base.appendingPathComponent("statusline-label.txt"))
    let spool = root.appendingPathComponent("fixture-default-spool", isDirectory: true)
    let label = root.appendingPathComponent("fixture-default-label.txt")
    try Data("Lilt · Fixture default".utf8).write(to: label)
    let script = root.appendingPathComponent("fixture-statusline.sh")
    try Data(StatusLineBridge.defaultScript(root: root.path, spool: spool.path, chain: root.appendingPathComponent("no-chain").path,
                                            label: label.path).utf8).write(to: script)
    func run(secure: String?) throws -> String {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        if let secure { environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = secure }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":4102444800}}}"#.utf8))
        try? input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: printed, as: UTF8.self)
    }
    let sessionSpool = base.appendingPathComponent("spool", isDirectory: true)
    let shown = try run(secure: base.appendingPathComponent("secure").path + "/")
    precondition(shown == "Lilt · Fixture S", "a session showed another account: \(shown)")
    let sessionBatch = LiveUsageSpool.drain(sessionSpool, scope: LiveUsageEvent.sessionScope(id))
    precondition(sessionBatch.events.count == 1 && !LiveUsageSpool.hasPending(spool), "a session's report went to the wrong spool")
    let elsewhere = try run(secure: "/fixture/elsewhere")
    precondition(elsewhere == "Lilt · Fixture default" && !LiveUsageSpool.hasPending(spool), "another login was recorded")
    let missing = RuntimeScope.sessionBase(UUID()).appendingPathComponent("secure").path
    _ = try run(secure: missing)
    _ = try run(secure: root.appendingPathComponent("sessions/../x/secure").path)
    precondition(!LiveUsageSpool.hasPending(spool), "an ended or malformed session was recorded")
    let plain = try run(secure: nil), claudeHome = try run(secure: home.appendingPathComponent(".claude").path)
    precondition(plain == "Lilt · Fixture default" && claudeHome == "Lilt · Fixture default")
    precondition(LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope).events.count == 2, "the default login was not recorded")
    try? FileManager.default.removeItem(at: base)
    for file in [spool, label, script] { try? FileManager.default.removeItem(at: file) }
    print("PASS: session status line — own spool and label for Lilt's sessions, other logins and ended sessions not recorded, default login as before.")
}
