import Foundation
import LiltCore
import LiltBackend

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func expectThrowing(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    if try !condition() { fatalError(message) }
}
func credential(_ name: String) -> Credential {
    Credential(data: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": "fixture-access-\(name)", "refreshToken": "fixture-refresh-\(name)",
        "expiresAt": Int64(Date.now.timeIntervalSince1970 * 1000 + 28_800_000), "scopes": ["user:profile", "user:inference"]
    ]]))
}
func identity(_ name: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["accountUuid": "fixture-account-\(name)", "emailAddress": "\(name)@example.invalid", "organizationUuid": "fixture-org"])
}
func fixture() throws -> (BackendStore, URL) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("work/backend-tests-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let paths = BackendPaths(environment: ["HOME": home.path])
    let store = BackendStore(paths: paths); try store.prepare()
    return (store, root)
}
func initialConfig(_ store: BackendStore) throws {
    let config: [String: Any] = ["oauthAccount": ["accountUuid": "fixture-account-a"], "projects": ["/fixture": ["history": []]], "userID": "fixture-user"]
    try SecureFiles.write(try JSONSerialization.data(withJSONObject: config), to: store.paths.globalClaudeConfig)
    let settings: [String: Any] = ["env": ["ANTHROPIC_API_KEY": "fixture-api", "HTTPS_PROXY": "http://proxy.invalid"], "hooks": ["fixture": true]]
    try SecureFiles.write(try JSONSerialization.data(withJSONObject: settings), to: store.paths.settings)
}
struct FakeUsage: UsageFetching {
    let snapshots: [String: UsageSnapshot]
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        guard let token = credential.token, let snapshot = snapshots[token] else { throw UsageFailure.invalidResponse }
        return snapshot
    }
}
actor ScriptedUsage: UsageFetching {
    let snapshot: UsageSnapshot
    var scripts: [String: [UsageFailure?]]
    var calls = 0
    init(snapshot: UsageSnapshot, scripts: [String: [UsageFailure?]]) { self.snapshot = snapshot; self.scripts = scripts }
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        calls += 1
        let token = credential.token ?? ""
        if var script = scripts[token], !script.isEmpty {
            let failure = script.removeFirst(); scripts[token] = script
            if let failure { throw failure }
        }
        return snapshot
    }
    func reset(_ newScripts: [String: [UsageFailure?]]) { scripts = newScripts; calls = 0 }
}
struct FakeIdentity: IdentityFetching {
    let identities: [String: Data]
    func fetch(_ credential: Credential) async -> Data? { credential.token.flatMap { identities[$0] } }
}
struct FakeRenewer: TokenRenewing { func renew(_ credential: Credential) async throws -> Credential { credential } }
/// Counts renewals and hands back the same login good for eight more hours.
actor ExtendingRenewer: TokenRenewing {
    var count = 0
    func renew(_ credential: Credential) async throws -> Credential {
        count += 1
        var oauth = (try JSONSerialization.jsonObject(with: credential.data) as! [String: Any])["claudeAiOauth"] as! [String: Any]
        oauth["expiresAt"] = Int64(Date.now.timeIntervalSince1970 * 1000 + 28_800_000)
        return Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]))
    }
}

func testSecureRuntime() throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try initialConfig(store)
    let runtime = FileRuntimeScope(store: store)
    try SecureFiles.write(credential("a").data, to: store.paths.credentials)
    try runtime.rebaseline()
    try runtime.apply(credential("b"), identity: identity("b"), replacingExternalState: true)
    try expectThrowing(try runtime.currentCredential()?.token == "fixture-access-b", "runtime switch")
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.globalClaudeConfig)) as! [String: Any]
    expect(config["projects"] != nil && config["userID"] != nil, "config preservation")
    expect((config["oauthAccount"] as! [String: Any])["accountUuid"] as? String == "fixture-account-b", "identity switch")
    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.settings)) as! [String: Any]
    let env = settings["env"] as! [String: Any]
    expect(env["ANTHROPIC_API_KEY"] == nil && env["HTTPS_PROXY"] != nil && settings["hooks"] != nil, "API cleanup preserves unrelated settings")
    try SecureFiles.write(credential("external").data, to: store.paths.credentials)
    do {
        try runtime.apply(credential("a"), identity: identity("a"))
        fatalError("external modification accepted")
    } catch {}
    try expectThrowing(try runtime.currentCredential()?.token == "fixture-access-external", "external state overwritten")
}

func testStatusLine() throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let original = "{\"statusLine\":{\"type\":\"command\",\"command\":\"cat\"}}"
    try SecureFiles.write(Data(original.utf8), to: store.paths.settings)
    try LiveUsageBridge.install(store: store)
    let input = Data(#"{"session_id":"not-saved","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":2000000000}}}"#.utf8)
    let output = try LiveUsageBridge.handle(store: store, input: input)
    expect(output == input, "status line did not preserve original output: got \(output.count) bytes, expected \(input.count)")
    let files = try FileManager.default.contentsOfDirectory(atPath: store.paths.runtimeScope.spool.path).filter { $0.hasSuffix(".json") }
    expect(files.count == 1, "one event file per report")
    let kept = try String(contentsOf: store.paths.runtimeScope.spool.appendingPathComponent(files[0]), encoding: .utf8)
    expect(!kept.contains("session_id") && !kept.contains("not-saved"), "only rate limits are kept")
    let batch = LiveUsageBridge.drain(store: store)
    expect(batch.events.count == 1 && batch.events[0].snapshot.fiveHour?.used == 42 && !batch.hasGaps, "status line reading")
    // Five sessions reporting at once: every event arrives, none overwrites another.
    DispatchQueue.concurrentPerform(iterations: 5) { session in
        for round in 0..<8 {
            let used = [61, 74, 57, 73, 68][(session + round) % 5]
            let event = Data(#"{"rate_limits":{"five_hour":{"used_percentage":\#(used),"resets_at":2000000000}}}"#.utf8)
            _ = try? LiveUsageBridge.handle(store: store, input: event)
        }
    }
    let concurrent = LiveUsageBridge.drain(store: store)
    expect(concurrent.events.count == 40 && !concurrent.hasGaps, "concurrent events lost: \(concurrent.events.count)")
    expect(concurrent.events.map { $0.snapshot.fiveHour!.used }.max() == 74, "high-water mark")
    // A session on another configuration directory does not report for the default login.
    setenv("CLAUDE_CONFIG_DIR", root.appendingPathComponent("elsewhere").path, 1)
    _ = try LiveUsageBridge.handle(store: store, input: input)
    unsetenv("CLAUDE_CONFIG_DIR")
    expect(LiveUsageBridge.drain(store: store).events.isEmpty, "foreign configuration reported for the default login")
    try LiveUsageBridge.uninstall(store: store)
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.settings)) as! [String: Any]
    expect((restored["statusLine"] as! [String: Any])["command"] as? String == "cat", "status line restore")
    expect(!FileManager.default.fileExists(atPath: store.paths.runtimeScope.spool.path), "status line cleanup")
}

func testRefreshRecovery() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("refresh-a"), b = credential("refresh-b")
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [a.token!: [.network, nil], b.token!: [.rateLimited(120), nil]])
    let clock = Clock()
    let renewer = ExtendingRenewer()
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: renewer, now: { clock.value }, requestGap: 0)
    let aID = try await engine.add(a, identity: identity("refresh-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    await Task.yield()
    await engine.refresh(aID)
    await engine.refresh(aID, manually: true)
    let previousCheck = await engine.account(aID)?.lastChecked
    await usage.reset([a.token!: [.network, nil], b.token!: [.rateLimited(120), nil]])
    await engine.refresh(aID)
    await engine.refresh(aID)
    let automaticCalls = await usage.calls
    expect(automaticCalls == 1, "automatic refresh ignored ordinary backoff: calls=\(automaticCalls)")
    let failedState = await engine.snapshot()
    expect(failedState.0.accounts[0].lastChecked == previousCheck && failedState.0.accounts[0].issue == UsageFailure.network.message,
           "failed request advanced the last successful reading")
    await engine.refresh(aID, manually: true)
    let manualCalls = await usage.calls
    expect(manualCalls == 2, "manual refresh did not override ordinary backoff: calls=\(manualCalls)")
    let state = await engine.snapshot()
    expect(state.0.accounts[0].usage?.fiveHour?.used == 25 && state.1.message == "额度已更新", "manual refresh recovery")
    let bID = try await engine.add(b, identity: identity("refresh-b"), label: "B", kind: .oauth)
    await engine.refresh(bID, manually: true)
    await engine.refresh(bID, manually: true)
    let limitedCalls = await usage.calls
    expect(limitedCalls == 3, "manual refresh bypassed server 429")
    await engine.refresh(aID, manually: true)
    let independentCalls = await usage.calls
    expect(independentCalls == 4, "one account's 429 paused another account")
    let independentState = await engine.snapshot()
    expect(independentState.1.usageRetryAt == nil, "one account's 429 published a global pause")
    // Two accounts refused in a row, with nothing answered between, pause every read.
    let c = credential("refresh-c")
    let cID = try await engine.add(c, identity: identity("refresh-c"), label: "C", kind: .oauth)
    var soon = (try JSONSerialization.jsonObject(with: credential("refresh-d").data) as! [String: Any])["claudeAiOauth"] as! [String: Any]
    soon["expiresAt"] = Int64(Date.now.timeIntervalSince1970 * 1000 + 600_000)
    let dID = try await engine.add(Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": soon])),
                                   identity: identity("refresh-d"), label: "D", kind: .oauth)
    await usage.reset([a.token!: [.rateLimited(120)], c.token!: [.rateLimited(120)]])
    await engine.refresh(aID, manually: true)
    let soloState = await engine.snapshot()
    expect(soloState.1.usageRetryAt == nil, "a single refusal paused every account")
    await engine.refresh(cID, manually: true)
    await engine.refresh(cID, manually: true)
    let pausedCalls = await usage.calls
    expect(pausedCalls == 2, "reads went on after two accounts were refused: calls=\(pausedCalls)")
    let limitedState = await engine.snapshot()
    expect(limitedState.1.usageRetryAt == clock.value.addingTimeInterval(120), "daemon did not publish the global retry time")
    // A login about to expire is renewed while every read waits, without a quota read.
    await engine.refresh(dID)
    let renewedCount = await renewer.count
    let renewedCalls = await usage.calls
    expect(renewedCount == 1 && renewedCalls == 2, "expiring login was not renewed during the pause")
    let renewedExpiry = await engine.account(dID)?.expiresAt ?? .distantPast
    expect(renewedExpiry > Date.now.addingTimeInterval(3600), "renewed expiry not recorded")
    clock.value = clock.value.addingTimeInterval(121)
    await engine.refresh(aID, manually: true)
    let recoveredCalls = await usage.calls
    expect(recoveredCalls == 3, "queries did not recover after the global cooldown")
}

func testAlternatePolling() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("poll-a"), b = credential("poll-b")
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [:])
    let clock = Clock()
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), now: { clock.value }, requestGap: 0)
    _ = try await engine.add(a, identity: identity("poll-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    _ = try await engine.add(b, identity: identity("poll-b"), label: "B", kind: .oauth)
    await engine.refreshAll()
    await usage.reset([:])
    clock.value = clock.value.addingTimeInterval(3599)
    await engine.tick()
    var calls = await usage.calls
    expect(calls == 1, "alternate refreshed before its cadence, or the active account did not refresh: \(calls)")
    await usage.reset([:])
    clock.value = clock.value.addingTimeInterval(1)
    await engine.tick()
    calls = await usage.calls
    expect(calls == 1, "alternate was left stale at its scheduled poll: \(calls)")
}

/// Logins due for renewal sort first among spare accounts. Two of them waiting out a backoff send no read, so they
/// must not take the pass's two slots: the spare account behind them is read on schedule.
func testWaitingAccountsTakeNoPollSlot() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    func expiring(_ name: String) throws -> Credential {
        var oauth = (try JSONSerialization.jsonObject(with: credential(name).data) as! [String: Any])["claudeAiOauth"] as! [String: Any]
        oauth["expiresAt"] = Int64(Date.now.timeIntervalSince1970 * 1000 + 600_000)
        return Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]))
    }
    let a = credential("slot-a"), b = try expiring("slot-b"), c = try expiring("slot-c"), d = credential("slot-d")
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [:])
    let clock = Clock()
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), now: { clock.value }, requestGap: 0)
    _ = try await engine.add(a, identity: identity("slot-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    let bID = try await engine.add(b, identity: identity("slot-b"), label: "B", kind: .oauth)
    let cID = try await engine.add(c, identity: identity("slot-c"), label: "C", kind: .oauth)
    let dID = try await engine.add(d, identity: identity("slot-d"), label: "D", kind: .oauth)
    await engine.refreshAll()
    clock.value = clock.value.addingTimeInterval(3600)
    await usage.reset([b.token!: [.authentication], c.token!: [.authentication]])
    await engine.refresh(bID, manually: true)
    await engine.refresh(cID, manually: true)
    await usage.reset([:])
    await engine.tick()
    let calls = await usage.calls
    let checked = await engine.account(dID)?.lastChecked
    expect(calls == 2 && checked == clock.value, "accounts in a backoff took the poll slots: calls=\(calls)")
}

/// Answers each token with its own reading and remembers who was asked.
actor TokenUsage: UsageFetching {
    let readings: [String: UsageSnapshot]
    var asked: [String] = []
    init(_ readings: [String: UsageSnapshot]) { self.readings = readings }
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        let token = credential.token ?? ""; asked.append(token)
        return readings[token] ?? UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    }
    func reset() { asked = [] }
}

/// Exhausted spare accounts are not read before their reset, so they keep the oldest reading and sort first. Two of
/// them must not take the pass's two slots: the account behind them is read on schedule.
func testExhaustedAccountsTakeNoPollSlot() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock()
    let a = credential("held-a"), b = credential("held-b"), c = credential("held-c"), d = credential("held-d")
    let spent = UsageSnapshot(fiveHour: UsageWindow(used: 10), sevenDay: UsageWindow(used: 100, resetsAt: clock.value.addingTimeInterval(3 * 86400)))
    let usage = TokenUsage([b.token!: spent, c.token!: spent])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), now: { clock.value }, requestGap: 0)
    _ = try await engine.add(a, identity: identity("held-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    _ = try await engine.add(b, identity: identity("held-b"), label: "B", kind: .oauth)
    _ = try await engine.add(c, identity: identity("held-c"), label: "C", kind: .oauth)
    let dID = try await engine.add(d, identity: identity("held-d"), label: "D", kind: .oauth)
    await engine.refreshAll()
    clock.value = clock.value.addingTimeInterval(10)
    await engine.refresh(dID, manually: true)
    clock.value = clock.value.addingTimeInterval(3600)
    await usage.reset()
    await engine.tick()
    let asked = await usage.asked
    expect(asked.contains(d.token!) && !asked.contains(b.token!) && !asked.contains(c.token!),
           "exhausted accounts took the poll slots: asked \(asked.count), D read \(asked.contains(d.token!))")
}

func testExhaustedPollingWaitsForReset() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("spent-a"), b = credential("spent-b")
    let clock = Clock()
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: clock.value.addingTimeInterval(3600)),
                                 sevenDay: UsageWindow(used: 100, resetsAt: clock.value.addingTimeInterval(10800)), sampledAt: clock.value)
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [:])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), now: { clock.value }, requestGap: 0)
    let aID = try await engine.add(a, identity: identity("spent-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    let bID = try await engine.add(b, identity: identity("spent-b"), label: "B", kind: .oauth)
    await engine.refreshAll()
    await usage.reset([:])
    clock.value = clock.value.addingTimeInterval(7200)
    await engine.tick()
    await engine.refresh(aID)
    await engine.refresh(bID)
    var calls = await usage.calls
    expect(calls == 0, "an exhausted account was polled before every known exhausted window reset: \(calls)")
    clock.value = clock.value.addingTimeInterval(3605)
    await engine.tick()
    calls = await usage.calls
    expect(calls == 2, "accounts did not resume polling after their exhausted windows reset: \(calls)")
}

func testExpiringExhaustedAlternateRenewsBeforeReset() async throws {
    final class Clock: @unchecked Sendable { var value = Date.now }
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock()
    let expiring = Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": "fixture-access-spent-expiring", "refreshToken": "fixture-refresh-spent-expiring",
        "expiresAt": Int64(clock.value.timeIntervalSince1970 * 1000 + 1_800_000), "scopes": ["user:profile", "user:inference"]
    ]]))
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: clock.value.addingTimeInterval(7200)),
                                 sevenDay: UsageWindow(used: 20), sampledAt: clock.value)
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [:])
    let renewer = CountingRenewer()
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: renewer, now: { clock.value }, requestGap: 0)
    _ = try await engine.add(credential("spent-current"), identity: identity("spent-current"), label: "Current", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    let id = try await engine.add(expiring, identity: identity("spent-expiring"), label: "Spare", kind: .oauth)
    await engine.refreshAll()
    await usage.reset([:])
    let initialRenewals = await renewer.renewals
    clock.value = clock.value.addingTimeInterval(1)
    await engine.refresh(id)
    let calls = await usage.calls, renewals = await renewer.renewals
    expect(calls == 1 && renewals == initialRenewals + 1, "an expiring exhausted alternate did not renew before its quota reset: calls=\(calls), renewals=\(renewals)")
}

func testFreshServerTakeover() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try HeadlessEngine(store: store, usageClient: FakeUsage(snapshots: [:]), identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let a = credential("fresh")
    let id = try await engine.add(a, identity: identity("fresh"), label: "First", kind: .oauth)
    let taken = try await engine.takeOver(label: nil)
    expect(taken == id, "fresh server takeover account")
    try expectThrowing(try FileRuntimeScope(store: store).currentCredential()?.token == a.token, "fresh server runtime credential")
    let state = await engine.snapshot().0
    expect(state.preferences.scopeEnabled && state.activeID == id, "fresh server scope enabled")
}

func testAutomaticRelay() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try initialConfig(store)
    let a = credential("a"), b = credential("b")
    try SecureFiles.write(a.data, to: store.paths.credentials)
    let now = Date.now
    let snapshots = [
        a.token!: UsageSnapshot(fiveHour: UsageWindow(used: 99, resetsAt: now.addingTimeInterval(1000)), sevenDay: UsageWindow(used: 20), sampledAt: now),
        b.token!: UsageSnapshot(fiveHour: UsageWindow(used: 5, resetsAt: now.addingTimeInterval(2000)), sevenDay: UsageWindow(used: 30), sampledAt: now)
    ]
    let engine = try HeadlessEngine(store: store, usageClient: FakeUsage(snapshots: snapshots), identityClient: FakeIdentity(identities: [a.token!: identity("a"), b.token!: identity("b")]), renewer: FakeRenewer(), requestGap: 0)
    let activeID = try await engine.takeOver(label: "A")
    _ = try await engine.apply(activeID)
    let bID = try await engine.add(b, identity: identity("b"), label: "B", kind: .oauth)
    await engine.refreshAll()
    try await engine.setAuto(true)
    await engine.tick()
    let after = await engine.snapshot()
    expect(after.0.activeID == bID, "automatic relay active account: \(String(describing: after.1.message)) \(String(describing: after.1.relayPause))")
    try expectThrowing(try FileRuntimeScope(store: store).currentCredential()?.token == b.token, "automatic relay runtime credential")
    try SecureFiles.write(a.data, to: store.paths.credentials)
    var externalConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.globalClaudeConfig)) as! [String: Any]
    externalConfig["oauthAccount"] = try JSONSerialization.jsonObject(with: identity("a"))
    try SecureFiles.write(try JSONSerialization.data(withJSONObject: externalConfig), to: store.paths.globalClaudeConfig)
    let vault = store.paths.dataRoot.appendingPathComponent("secrets").appendingPathComponent(bID.uuidString)
    let backup = vault.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: vault, to: backup)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
    await engine.tick()
    let waiting = await engine.snapshot()
    expect(waiting.0.preferences.autoRelay == true && waiting.1.scopeUnreadable != nil, "local read failure became a permanent stop")
    try FileManager.default.removeItem(at: vault)
    try FileManager.default.moveItem(at: backup, to: vault)
    await engine.tick()
    let stopped = await engine.snapshot().0
    expect(stopped.preferences.autoRelay == false, "foreign login did not stop automatic relay")
    expect(stopped.preferences.autoRelayStopReason != nil, "safety stop reason missing")
}

// The checks must not depend on the shell that runs them: a configuration directory set there would change scopes.
for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"] { unsetenv(key) }
expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256")
expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty")
try testSecureRuntime()
try testStatusLine()
try await testRefreshRecovery()
try await testAlternatePolling()
try await testWaitingAccountsTakeNoPollSlot()
try await testExhaustedAccountsTakeNoPollSlot()
try await testExhaustedPollingWaitsForReset()
try await testExpiringExhaustedAlternateRenewsBeforeReset()
try await testFreshServerTakeover()
try await testAutomaticRelay()
try await testProjects()
try await testObservationIsNotBlocked()
try await testRelayRunsOnce()
try await testTransfer()
try await testProjectAccountsAreNotRenewed()
print("LiltBackendChecks: PASS (17 groups: digest, secure runtime, API preservation, per-event status line with concurrent sessions, refresh recovery with per-account 429, alternate polling, waiting and exhausted accounts take no poll slot, exhausted polling reset, expiring exhausted alternate renewal, fresh server, automatic relay, two isolated projects, observation during a hung request, one hand-off per trigger, encrypted transfer, no renewal of project logins)")
