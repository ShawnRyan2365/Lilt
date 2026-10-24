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
        "expiresAt": Int64(Date.now.timeIntervalSince1970 * 1000 + 3_600_000), "scopes": ["user:profile", "user:inference"]
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
}
struct FakeIdentity: IdentityFetching {
    let identities: [String: Data]
    func fetch(_ credential: Credential) async -> Data? { credential.token.flatMap { identities[$0] } }
}
struct FakeRenewer: TokenRenewing { func renew(_ credential: Credential) async throws -> Credential { credential } }

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
    expect(LiveUsageBridge.latest(store: store)?.fiveHour?.used == 42, "status line reading")
    try LiveUsageBridge.uninstall(store: store)
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.settings)) as! [String: Any]
    expect((restored["statusLine"] as! [String: Any])["command"] as? String == "cat", "status line restore")
    expect(LiveUsageBridge.latest(store: store) == nil, "status line cleanup")
}

func testRefreshRecovery() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("refresh-a"), b = credential("refresh-b")
    let snapshot = UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    let usage = ScriptedUsage(snapshot: snapshot, scripts: [a.token!: [.network, nil], b.token!: [.rateLimited(120), nil]])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let aID = try await engine.add(a, identity: identity("refresh-a"), label: "A", kind: .oauth)
    _ = try await engine.takeOver(label: nil)
    await engine.refresh(aID)
    await engine.refresh(aID)
    expect(await usage.calls == 1, "automatic refresh ignored ordinary backoff")
    await engine.refresh(aID, manually: true)
    expect(await usage.calls == 2, "manual refresh did not override ordinary backoff")
    let state = await engine.snapshot()
    expect(state.0.accounts[0].usage?.fiveHour?.used == 25 && state.1.message == "额度已更新", "manual refresh recovery")
    _ = try await engine.add(b, identity: identity("refresh-b"), label: "B", kind: .oauth)
    let bID = state.0.activeID == aID ? try await engine.snapshot().0.accounts.first { $0.label == "B" }!.id : aID
    await engine.refresh(bID, manually: true)
    await engine.refresh(bID, manually: true)
    expect(await usage.calls == 3, "manual refresh bypassed server 429")
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
    await engine.tick()
    let stopped = await engine.snapshot().0
    expect(stopped.preferences.autoRelay == false, "foreign login did not stop automatic relay")
    expect(stopped.preferences.autoRelayStopReason != nil, "safety stop reason missing")
}

expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256")
expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty")
try testSecureRuntime()
try testStatusLine()
try await testFreshServerTakeover()
try await testAutomaticRelay()
print("LiltBackendChecks: PASS (6 groups: digest, secure runtime, API preservation, status line, fresh server, automatic relay)")
