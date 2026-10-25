import Foundation
import LiltCore

/// Holds requests for chosen tokens until released, so a check can look at the model while a read is out.
@MainActor final class HeldReads {
    var held: Set<String> = []
    var waiting: [CheckedContinuation<Void, Never>] = []
    var answers: [String: UsageSnapshot] = [:]
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        let token = credential.token ?? ""
        if held.contains(token) { await withCheckedContinuation { waiting.append($0) } }
        guard let answer = answers[token] else { throw UsageFailure.invalidResponse }
        return answer
    }
    func release() { held = []; let all = waiting; waiting = []; for each in all { each.resume() } }
}

/// In-memory keychain items, one per project, so no check ever touches a real keychain item. The scope reads and
/// writes them from the I/O queue, hence the lock.
final class ProjectKeychains: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: Data] = [:]
    private var count = 0
    var items: [UUID: Data] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func scope(_ project: ProjectBinding) -> RuntimeScope {
        let home = FileManager.default.homeDirectoryForCurrentUser, id = project.id
        return RuntimeScope(fixtureHome: home, project: project, credentials: .init(
            read: { self.items[id] },
            write: { data in self.lock.lock(); self.stored[id] = data; self.count += 1; self.lock.unlock() },
            delete: { self.items[id] = nil }))
    }
}

/// Built once per name: JSON encoders do not promise one key order from one call to the next, and the checks compare bytes.
nonisolated(unsafe) var fixtureLogins: [String: Data] = [:]
func fixtureLogin(_ name: String) -> Data {
    if let made = fixtureLogins[name] { return made }
    let made = Data(#"{"claudeAiOauth":{"accessToken":"fixture-access-\#(name)","refreshToken":"fixture-refresh-\#(name)","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}"#.utf8)
    fixtureLogins[name] = made
    return made
}
func fixtureIdentity(_ name: String) -> Data { Data(#"{"accountUuid":"fixture-account-\#(name)"}"#.utf8) }
let fixtureFive = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 3600)
let fixtureSeven = fixtureFive.addingTimeInterval(80000)
func fixtureUsage(_ remaining: Double, at date: Date = .now) -> UsageSnapshot {
    UsageSnapshot(fiveHour: UsageWindow(used: 100 - remaining, resetsAt: fixtureFive), sevenDay: UsageWindow(used: 30, resetsAt: fixtureSeven), sampledAt: date)
}
func writeEvent(_ used: Double, scope: String, to spool: URL, at date: Date = .now) throws {
    let limits: [String: Any] = ["five_hour": ["used_percentage": used, "resets_at": fixtureFive.timeIntervalSince1970],
                                 "seven_day": ["used_percentage": 30.0, "resets_at": fixtureSeven.timeIntervalSince1970]]
    let id = UUID().uuidString
    try LiveUsageSpool.write(try LiveUsageSpool.record(id: id, scope: scope, at: date, limits: limits), id: id, at: date, to: spool)
}

/// Status line events are taken in while a quota read is out, while a switch runs and while the scope does not read;
/// none of those stops observation, though the last one stops writing.
@MainActor func observationChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"), "Run through scripts/check-relay-model.sh")
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    var active = Account(label: "Fixture A", kind: .oauth); active.usage = fixtureUsage(60, at: .now.addingTimeInterval(-30)); active.usageCapability = .verified
    var spare = Account(label: "Fixture B", kind: .oauth); spare.usage = fixtureUsage(80); spare.usageCapability = .verified
    var library = Library()
    library.accounts = [active, spare]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    try AccountVault.write(fixtureLogin("observe-a"), account: active.id.uuidString)
    try AccountVault.write(fixtureLogin("observe-b"), account: spare.id.uuidString)
    var held: Data? = fixtureLogin("observe-a")
    var failing = false
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        if failing { throw AppFailure("钥匙串没有响应，可能在等你允许访问。") }
        return held
    }, write: { held = $0 }, delete: { held = nil }))
    try scope.rebaseline()
    let reads = HeldReads()
    reads.answers = ["fixture-access-observe-b": fixtureUsage(80)]
    reads.held = ["fixture-access-observe-b"]
    let model = AppModel(fixture: library, runtime: scope, usageFetch: { try await reads.fetch($0) })
    let out = Task { await model.refresh(spare.id, manually: true) }
    try await Task.sleep(for: .milliseconds(50))
    precondition(model.loading, "the read should still be out")
    try writeEvent(47, scope: LiveUsageEvent.defaultScope, to: StatusLineBridge.spoolDirectory)
    await model.ingestLiveUsage()
    precondition(model.active?.usage?.fiveHour?.used == 47, "a quota read out held up observation")
    // A switch in progress does not hold it up either.
    model.busy = true
    try writeEvent(51, scope: LiveUsageEvent.defaultScope, to: StatusLineBridge.spoolDirectory)
    await model.ingestLiveUsage()
    precondition(model.active?.usage?.fiveHour?.used == 51, "a switch held up observation")
    model.busy = false
    // Nor a scope that does not read: that only keeps Lilt from writing.
    failing = true
    _ = await model.reconcileScope()
    precondition(model.scopeUnreadable != nil)
    try writeEvent(55, scope: LiveUsageEvent.defaultScope, to: StatusLineBridge.spoolDirectory)
    await model.ingestLiveUsage()
    precondition(model.active?.usage?.fiveHour?.used == 55, "an unreadable scope stopped observation")
    // A lower figure from an idle session never lowers the record, and a gap is reported.
    try writeEvent(40, scope: LiveUsageEvent.defaultScope, to: StatusLineBridge.spoolDirectory)
    try SecureFiles.write(Data(), to: StatusLineBridge.spoolDirectory.appendingPathComponent(LiveUsageSpool.gapName))
    await model.ingestLiveUsage()
    precondition(model.active?.usage?.fiveHour?.used == 55 && model.statusLineIssue != nil, "high-water mark or gap lost")
    failing = false
    reads.release(); await out.value
    print("PASS: observation — events taken in while a read is out, during a switch and with the scope unreadable; high-water mark; gaps reported.")
}

/// Two passes that see one trigger at the same moment hand off once.
@MainActor func relayOnceChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var active = Account(label: "Fixture A", kind: .oauth); active.usage = fixtureUsage(0.5); active.usageCapability = .verified
    var spare = Account(label: "Fixture B", kind: .oauth); spare.usage = fixtureUsage(80); spare.usageCapability = .verified
    var third = Account(label: "Fixture C", kind: .oauth); third.usage = fixtureUsage(70); third.usageCapability = .verified
    var library = Library()
    library.accounts = [active, spare, third]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = false
    for (account, name) in [(active, "once-a"), (spare, "once-b"), (third, "once-c")] {
        try AccountVault.write(fixtureLogin(name), account: account.id.uuidString)
        try AccountVault.write(fixtureIdentity(name), account: Keychain.identityAccount(account.id))
    }
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-account-once-a"}}"#.utf8), to: home.appendingPathComponent(".claude.json"))
    var held: Data? = fixtureLogin("once-a"), writes = 0
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0; writes += 1 }, delete: { held = nil }))
    try scope.rebaseline()
    let model = AppModel(fixture: library, runtime: scope)
    async let first: Void = model.relay()
    async let second: Void = model.relay()
    _ = await (first, second)
    precondition(writes == 1 && model.active?.id == spare.id, "one trigger switched \(writes) times")
    // Turning relay off ends nothing already written, and the next pass does nothing.
    model.setAutoRelay(false)
    await model.relay()
    precondition(writes == 1)
    print("PASS: relay — one hand-off per trigger with two passes at once, the emptiest account taken, off means off.")
}

/// Two projects through the app model: separate scopes, accounts kept out of the default login, renewals taken
/// back, foreign logins refused, rebinding and unbinding.
@MainActor func projectModelChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let rootA = home.appendingPathComponent("Model Project A ' 项目", isDirectory: true), rootB = home.appendingPathComponent("Model Project B", isDirectory: true)
    for root in [rootA, rootB] { try SecureFiles.directory(root) }
    defer { for root in [rootA, rootB] { try? FileManager.default.removeItem(at: root) } }
    var main = Account(label: "Fixture default", kind: .oauth); main.usage = fixtureUsage(60); main.usageCapability = .verified
    var first = Account(label: "Fixture P1", kind: .oauth); first.usage = fixtureUsage(70); first.usageCapability = .verified
    var second = Account(label: "Fixture P2", kind: .oauth); second.usage = fixtureUsage(90); second.usageCapability = .verified
    var library = Library()
    library.accounts = [main, first, second]; library.activeID = main.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = true
    for (account, name) in [(main, "model-main"), (first, "model-p1"), (second, "model-p2")] {
        try AccountVault.write(fixtureLogin(name), account: account.id.uuidString)
        try AccountVault.write(fixtureIdentity(name), account: Keychain.identityAccount(account.id))
    }
    var held: Data? = fixtureLogin("model-main")
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0 }, delete: { held = nil }))
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-account-model-main"}}"#.utf8), to: home.appendingPathComponent(".claude.json"))
    try scope.rebaseline()
    let keychains = ProjectKeychains()
    let model = AppModel(fixture: library, runtime: scope, usageFetch: { _ in throw UsageFailure.network },
                         projectRuntime: { keychains.scope($0) })
    let defaultBefore = held

    let step1 = await model.bindProject(root: rootA.path, accountID: first.id, allowShared: false)
    precondition(step1, model.message ?? "bind A")
    let a = try require(model.projectCatalog.binding(rootPath: rootA.path))
    precondition(a.phase == .ready && keychains.items[a.id] == fixtureLogin("model-p1"), "project A does not hold its account")
    let signal = keychains.scope(a).directory.appendingPathComponent(".credentials.json")
    precondition((try? Data(contentsOf: signal)) == RuntimeScope.signal, "project A's file must only be the signal")
    let aItem = keychains.items[a.id]
    let step2 = await model.bindProject(root: rootB.path, accountID: second.id, allowShared: false)
    precondition(step2, model.message ?? "bind B")
    let b = try require(model.projectCatalog.binding(rootPath: rootB.path))
    precondition(keychains.items[a.id] == aItem && keychains.items[b.id] == fixtureLogin("model-p2"), "binding B touched A")
    precondition(held == defaultBefore, "binding projects changed the default login")
    precondition((try? Data(contentsOf: Disk.file("projects.json"))) != nil, "projects.json not written")

    // Accounts fixed to projects never serve the default login.
    let step3 = await model.apply(first.id)
    precondition(step3 == false && model.active?.id == main.id, "default login took a project account")
    model.remove(first.id)
    precondition(model.accounts.contains { $0.id == first.id }, "a bound account was removed")
    precondition(model.relayBlocker == "还需要一个能读额度的备用账号（项目专用账号不算）", "project accounts counted as spares")
    let step4 = await model.bindProject(root: rootA.path, accountID: second.id, allowShared: true)
    precondition(step4 == false, "one directory bound twice")
    let step5 = await model.rebindProject(a.id, accountID: second.id, allowShared: false)
    precondition(step5 == false, "shared without consent")

    // The project's CLI renewed its login: a launch takes it back and writes nothing.
    var renewedLogin = try JSONSerialization.jsonObject(with: fixtureLogin("model-p1")) as! [String: Any]
    var oauth = renewedLogin["claudeAiOauth"] as! [String: Any]
    oauth["accessToken"] = "fixture-access-model-p1-renewed"; oauth["expiresAt"] = 4_102_444_900_000.0
    renewedLogin["claudeAiOauth"] = oauth
    let renewed = try JSONSerialization.data(withJSONObject: renewedLogin)
    keychains.items[a.id] = renewed
    let writes = keychains.writes
    let plan = try await model.projectLaunchPlan(a.id, executable: "/fixture/Claude Code/claude")
    precondition(keychains.writes == writes && keychains.items[a.id] == renewed, "a launch rewrote a renewed project login")
    let step6 = try AccountVault.read(account: first.id.uuidString)
    precondition(step6 == renewed, "the project renewal was not taken back")
    precondition(plan.command.contains(shellQuote(keychains.scope(a).directory.path)) && plan.command.contains(shellQuote(a.rootPath)))

    // Rebinding A writes A only; B stays byte for byte.
    let bItem = keychains.items[b.id]
    let step7 = await model.rebindProject(a.id, accountID: second.id, allowShared: true)
    precondition(step7, model.message ?? "rebind A")
    precondition(keychains.items[a.id] == fixtureLogin("model-p2") && keychains.items[b.id] == bItem, "rebinding A touched B")
    let step8 = await model.rebindProject(a.id, accountID: first.id, allowShared: false)
    precondition(step8, model.message ?? "rebind A back")

    // Someone put another account's login into project B: nothing is overwritten and the project says so.
    let foreign = fixtureLogin("model-someone-else")
    keychains.items[b.id] = foreign
    do { _ = try await model.projectLaunchPlan(b.id, executable: "/fixture/claude"); preconditionFailure("a foreign project login launched") } catch {}
    precondition(keychains.items[b.id] == foreign && model.projectCatalog.binding(id: b.id)?.phase == .conflict, "foreign login overwritten")
    keychains.items[b.id] = bItem
    let step9 = await model.rebindProject(b.id, accountID: second.id, allowShared: false)
    precondition(step9, model.message ?? "rebind B")

    // A session of project B reports quota: it goes to B's account and to nothing else.
    try writeEvent(25, scope: b.eventScope, to: ProjectStatusLineBridge.spool(b))
    await model.ingestLiveUsage()
    precondition(model.accounts.first { $0.id == second.id }?.usage?.fiveHour?.used == 25, "project event not taken in")
    precondition(model.active?.usage?.fiveHour?.used == 40, "project event went to the default login")
    precondition(model.projectCatalog.binding(id: b.id)?.appliedPending == false, "project session report not recorded")

    // Unbinding keeps the project's login and frees the account for the default login.
    model.unbindProject(a.id)
    precondition(model.projectCatalog.binding(id: a.id) == nil && keychains.items[a.id] != nil, "unbinding removed the project login")
    let step10 = await model.apply(first.id)
    precondition(step10 && model.active?.id == first.id, "an unbound account stayed reserved")
    let reloaded = try Disk.loadProjects()
    precondition(reloaded.projects.map(\.id) == [b.id], "projects.json does not match")
    print("PASS: projects through the app model — separate scopes and keychain items, the signal file, accounts kept out of the default login, renewal read back, foreign login refused, rebinding, events per project, unbinding.")
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw AppFailure("Fixture missing") }
    return value
}
