import Foundation
import LiltCore
import LiltTransfer
import LiltBackend

/// A usage endpoint that answers by token and can be held: a request for a held token waits until `release`.
actor GatedUsage: UsageFetching {
    var snapshots: [String: UsageSnapshot]
    var held: Set<String> = []
    var waiting: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    init(_ snapshots: [String: UsageSnapshot]) { self.snapshots = snapshots }
    func set(_ token: String, _ snapshot: UsageSnapshot) { snapshots[token] = snapshot }
    func hold(_ token: String) { held.insert(token) }
    func release() { held = []; let all = waiting; waiting = []; for each in all { each.resume() } }
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        calls += 1
        let token = credential.token ?? ""
        if held.contains(token) { await withCheckedContinuation { waiting.append($0) } }
        guard let snapshot = snapshots[token] else { throw UsageFailure.invalidResponse }
        return snapshot
    }
}

func window(_ remaining: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
    UsageWindow(used: 100 - remaining, resetsAt: Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60 + resetsIn))
}
func roomy(_ remaining: Double = 80) -> UsageSnapshot { UsageSnapshot(fiveHour: window(remaining), sevenDay: window(70, resetsIn: 86400)) }
func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

/// Two projects side by side: each has its own scope, an account fixed to one never serves the default login or
/// the other project, renewals are taken back, anything unaccounted for stops a launch, and unbinding keeps files.
func testProjects() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("default"), b = credential("project-b"), c = credential("project-c")
    try SecureFiles.write(a.data, to: store.paths.credentials)
    let usage = GatedUsage([a.token!: roomy(), b.token!: roomy(), c.token!: roomy()])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let defaultID = try await engine.takeOver(label: "Default")
    let bID = try await engine.add(b, identity: identity("project-b"), label: "B", kind: .oauth)
    let cID = try await engine.add(c, identity: identity("project-c"), label: "C", kind: .oauth)
    let rootA = root.appendingPathComponent("Project A ' 项目", isDirectory: true), rootB = root.appendingPathComponent("Project B", isDirectory: true)
    for directory in [rootA, rootB] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let defaultBefore = bytes(store.paths.credentials)

    let projectA = try await engine.bindProject(rootPath: rootA.path, accountID: bID, allowShared: false)
    let scopeA = store.paths.projectRuntime(projectA.id)
    expect(bytes(scopeA.credentials) == b.data, "project A holds its account")
    let scopeABefore = bytes(scopeA.credentials), journalA = bytes(scopeA.stateRoot.appendingPathComponent("transaction-system.json"))
    let projectB = try await engine.bindProject(rootPath: rootB.path, accountID: cID, allowShared: false)
    let scopeB = store.paths.projectRuntime(projectB.id)
    expect(bytes(scopeB.credentials) == c.data, "project B holds its account")
    expect(bytes(scopeA.credentials) == scopeABefore && bytes(scopeA.stateRoot.appendingPathComponent("transaction-system.json")) == journalA,
           "binding B changed A")
    expect(bytes(store.paths.credentials) == defaultBefore, "binding a project changed the default login")
    expect(scopeA.claudeDirectory != scopeB.claudeDirectory && scopeA.stateRoot != scopeB.stateRoot, "projects share a directory")

    // Accounts fixed to projects stay out of the default login entirely.
    let candidates = await engine.globalRelayCandidates().map(\.id)
    expect(candidates == [defaultID], "project accounts in the default relay: \(candidates)")
    do { _ = try await engine.apply(bID); fatalError("default login took a project account") } catch {}
    do { try await engine.remove(bID); fatalError("a bound account was removed") } catch {}
    do { _ = try await engine.bindProject(rootPath: rootA.path + "/", accountID: cID, allowShared: true); fatalError("one directory bound twice") } catch {}
    let rootC = root.appendingPathComponent("Project C", isDirectory: true)
    try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: true)
    do { _ = try await engine.bindProject(rootPath: rootC.path, accountID: bID, allowShared: false); fatalError("shared without consent") } catch {}
    do { _ = try await engine.bindProject(rootPath: rootC.path, accountID: defaultID, allowShared: false); fatalError("default account without consent") } catch {}
    let shared = try await engine.bindProject(rootPath: rootC.path, accountID: bID, allowShared: true)
    _ = try await engine.unbindProject(rootPath: rootC.path)
    expect(FileManager.default.fileExists(atPath: store.paths.projectRuntime(shared.id).credentials.path), "unbinding removed the project login")

    // The project's CLI renewed its login: a launch takes the renewal in and writes nothing new.
    var renewedLogin = try JSONSerialization.jsonObject(with: b.data) as! [String: Any]
    var oauth = renewedLogin["claudeAiOauth"] as! [String: Any]
    oauth["accessToken"] = "fixture-access-project-b-renewed"; oauth["expiresAt"] = Int64(Date.now.timeIntervalSince1970 * 1000 + 7_200_000)
    renewedLogin["claudeAiOauth"] = oauth
    let renewed = try JSONSerialization.data(withJSONObject: renewedLogin)
    try SecureFiles.write(renewed, to: scopeA.credentials)
    let plan = try await engine.projectLaunch(rootPath: rootA.path)
    expect(plan.configDirectory == scopeA.claudeDirectory.path && plan.rootPath == projectA.rootPath, "launch plan")
    expect(plan.unsetEnvironment.contains("CLAUDE_CODE_OAUTH_TOKEN") && plan.unsetEnvironment.contains("ANTHROPIC_API_KEY"), "launch clears overrides")
    expect(bytes(scopeA.credentials) == renewed, "launch rewrote a renewed login")
    let adopted = try store.readSecret(bID.uuidString)
    expect(adopted == renewed, "renewal not taken back")
    expect(bytes(scopeB.credentials) == c.data, "launching A touched B")

    // Rebinding A writes only A, with the CLIs of project A following, and B is byte for byte as it was.
    let scopeBBefore = bytes(scopeB.credentials), journalB = bytes(scopeB.stateRoot.appendingPathComponent("transaction-system.json"))
    _ = try await engine.rebindProject(rootPath: rootA.path, accountID: cID, allowShared: true)
    expect(bytes(scopeA.credentials) == c.data, "rebind did not write the new account")
    expect(bytes(scopeB.credentials) == scopeBBefore && bytes(scopeB.stateRoot.appendingPathComponent("transaction-system.json")) == journalB, "rebinding A changed B")
    _ = try await engine.rebindProject(rootPath: rootA.path, accountID: bID, allowShared: false)

    // Someone put another account's login into project B: the launch stops and nothing is overwritten.
    let foreign = credential("someone-else")
    try SecureFiles.write(foreign.data, to: scopeB.credentials)
    do { _ = try await engine.projectLaunch(rootPath: rootB.path); fatalError("foreign project login launched") } catch {}
    expect(bytes(scopeB.credentials) == foreign.data, "foreign project login overwritten")
    let conflicted = try await engine.projectStatus(rootPath: rootB.path)
    expect(conflicted.phase == .conflict, "conflict not recorded")
    try SecureFiles.write(c.data, to: scopeB.credentials)
    _ = try await engine.rebindProject(rootPath: rootB.path, accountID: cID, allowShared: true)

    // An API key in the project's configuration or in the repository's own settings stops a launch.
    try SecureFiles.write(Data(#"{"env":{"ANTHROPIC_API_KEY":"fixture-key"}}"#.utf8), to: scopeA.settings)
    do { _ = try await engine.projectLaunch(rootPath: rootA.path); fatalError("API override launched") } catch {}
    try FileManager.default.removeItem(at: scopeA.settings)
    _ = try await engine.rebindProject(rootPath: rootA.path, accountID: bID, allowShared: false)
    try FileManager.default.createDirectory(at: rootA.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example.invalid"}}"#.utf8).write(to: rootA.appendingPathComponent(".claude/settings.json"))
    do { _ = try await engine.projectLaunch(rootPath: rootA.path); fatalError("repository override launched") } catch {}
    try FileManager.default.removeItem(at: rootA.appendingPathComponent(".claude/settings.json"))
    do { _ = try await engine.projectLaunch(rootPath: root.appendingPathComponent("unbound").path); fatalError("unbound directory launched") } catch {}

    // Status line events of project A go to its account only, and not before a reading to match them with.
    await engine.refresh(bID, manually: true)
    try LiveUsageBridge.ingest(store: store, scope: scopeA, input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":\#(window(80).resetsAt!.timeIntervalSince1970)},"seven_day":{"used_percentage":30,"resets_at":\#(window(70, resetsIn: 86400).resetsAt!.timeIntervalSince1970)}}}"#.utf8))
    await engine.observe()
    let projectUsage = await engine.account(bID)?.usage?.fiveHour?.used, defaultUsage = await engine.account(defaultID)?.usage?.fiveHour?.used
    expect(projectUsage == 55, "project event not taken in")
    expect(defaultUsage != 55, "project event went to the default login")

    // A daemon restarted after a project switch stopped halfway settles it when the login is one of its own.
    let journal = scopeA.stateRoot.appendingPathComponent("transaction-system.json")
    var stamp = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
    stamp["pending"] = true
    try SecureFiles.write(try JSONSerialization.data(withJSONObject: stamp), to: journal)
    let restarted = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let reloaded = try await restarted.projectCatalog().projects
    expect(reloaded.count == 2, "projects lost across restart")
    _ = try await restarted.projectLaunch(rootPath: rootA.path)
    expect(!FileRuntimeScope(store: store, scope: scopeA).transactionPending, "pending project switch not settled")

    // Unbinding keeps the configuration and makes the account available to the default login again.
    _ = try await restarted.unbindProject(rootPath: rootA.path)
    expect(FileManager.default.fileExists(atPath: scopeA.credentials.path), "unbind removed the project login")
    let released = await restarted.globalRelayCandidates().map(\.id)
    expect(released.contains(bID), "unbound account still reserved")
    expect(bytes(store.paths.credentials) == defaultBefore, "projects changed the default login")
}

/// Status line events are taken in while a usage request hangs: observation waits for nothing.
func testObservationIsNotBlocked() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("observe-a"), b = credential("observe-b")
    try SecureFiles.write(a.data, to: store.paths.credentials)
    let usage = GatedUsage([a.token!: roomy(60), b.token!: roomy()])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let aID = try await engine.takeOver(label: "A")
    let bID = try await engine.add(b, identity: identity("observe-b"), label: "B", kind: .oauth)
    await engine.refresh(aID, manually: true)
    await usage.hold(b.token!)
    let stuck = Task { await engine.refresh(bID, manually: true) }
    try await Task.sleep(for: .milliseconds(100))
    let five = window(60).resetsAt!.timeIntervalSince1970, seven = window(70, resetsIn: 86400).resetsAt!.timeIntervalSince1970
    try LiveUsageBridge.ingest(store: store, input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":\#(five)},"seven_day":{"used_percentage":30,"resets_at":\#(seven)}}}"#.utf8))
    await engine.observe()
    let observed = await engine.account(aID)?.usage?.fiveHour?.used
    expect(observed == 47, "observation waited for a usage request")
    await usage.release(); await stuck.value
}

/// A trigger seen by two passes at once hands off once.
func testRelayRunsOnce() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = credential("once-a"), b = credential("once-b"), c = credential("once-c")
    try SecureFiles.write(a.data, to: store.paths.credentials)
    let usage = GatedUsage([a.token!: UsageSnapshot(fiveHour: window(0.5), sevenDay: window(70, resetsIn: 86400)), b.token!: roomy(), c.token!: roomy(70)])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    _ = try await engine.takeOver(label: "A")
    let bID = try await engine.add(b, identity: identity("once-b"), label: "B", kind: .oauth)
    _ = try await engine.add(c, identity: identity("once-c"), label: "C", kind: .oauth)
    await engine.refreshAll()
    try await engine.setAuto(true)
    async let first: Void = engine.tick()
    async let second: Void = engine.observe()
    async let third: Void = engine.tick()
    _ = await (first, second, third)
    let log = (try? String(contentsOf: store.paths.stateRoot.appendingPathComponent("switches.log"), encoding: .utf8)) ?? ""
    let automatic = log.split(separator: "\n").filter { $0.hasSuffix(" auto") }.count
    expect(automatic == 1, "one trigger switched \(automatic) times")
    let switched = await engine.snapshot()
    expect(switched.0.activeID == bID && switched.1.appliedPending && !switched.1.sessionConfirmed, "relay did not take the emptiest account")
    // A session reporting the new account confirms that one session, and says no more than that.
    let five = window(80).resetsAt!.timeIntervalSince1970, seven = window(70, resetsIn: 86400).resetsAt!.timeIntervalSince1970
    try LiveUsageBridge.ingest(store: store, input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":21,"resets_at":\#(five)},"seven_day":{"used_percentage":30,"resets_at":\#(seven)}}}"#.utf8))
    await engine.observe()
    let confirmed = await engine.snapshot().1
    expect(!confirmed.appliedPending && confirmed.sessionConfirmed, "one session's report is not recorded as such")
}

/// An archive made on one machine adds its accounts on another, disabled and with relay off, and changes nothing
/// that is running there. A second import, a wrong passphrase and a damaged file add nothing.
func testTransfer() async throws {
    let (source, sourceRoot) = try fixture(); defer { try? FileManager.default.removeItem(at: sourceRoot) }
    let a = credential("transfer-a")
    try SecureFiles.write(a.data, to: source.paths.credentials)
    let exporter = try HeadlessEngine(store: source, usageClient: FakeUsage(snapshots: [:]), identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    _ = try await exporter.takeOver(label: "Transfer A")
    _ = try await exporter.add(try Credential.manual("sk-ant-oat01-fixture-transfer-0000000000"), identity: nil, label: "Transfer T", kind: .setupToken)
    let passphrase = "fixture-passphrase-long"
    do { _ = try await exporter.exportArchive(passphrase: "short"); fatalError("short passphrase accepted") } catch {}
    let (archive, exported) = try await exporter.exportArchive(passphrase: passphrase)
    expect(exported.exported == 2, "export count")
    let text = String(decoding: archive, as: UTF8.self)
    expect(!text.contains("fixture-access") && !text.contains("Transfer A") && !text.contains("example.invalid"), "archive shows plaintext")

    let (target, targetRoot) = try fixture(); defer { try? FileManager.default.removeItem(at: targetRoot) }
    let own = credential("target-own")
    try SecureFiles.write(own.data, to: target.paths.credentials)
    let importer = try HeadlessEngine(store: target, usageClient: FakeUsage(snapshots: [:]), identityClient: FakeIdentity(identities: [:]), renewer: FakeRenewer(), requestGap: 0)
    let ownID = try await importer.takeOver(label: "Own")
    try await importer.setAuto(true)
    let runtimeBefore = bytes(target.paths.credentials), journalBefore = bytes(target.paths.stateRoot.appendingPathComponent("transaction-system.json"))
    do { _ = try await importer.importArchive(archive, passphrase: "fixture-wrong-passphrase"); fatalError("wrong passphrase accepted") } catch {}
    do { _ = try await importer.importArchive(archive.prefix(archive.count - 10), passphrase: passphrase); fatalError("damaged archive accepted") } catch {}
    let summary = try await importer.importArchive(archive, passphrase: passphrase)
    expect(summary.added == 2 && summary.skipped == 0 && summary.conflicts == 0, "import counts \(summary)")
    let library = await importer.snapshot().0
    expect(library.activeID == ownID && library.preferences.autoRelay == false, "import changed the account in use or left relay on")
    expect(library.accounts.filter { $0.id != ownID }.allSatisfy { !$0.enabled }, "imported accounts enabled")
    expect(library.accounts.first { $0.label == "Transfer T" }?.usageCapability == .unavailable, "setup-token gained quota reading")
    expect(bytes(target.paths.credentials) == runtimeBefore && bytes(target.paths.stateRoot.appendingPathComponent("transaction-system.json")) == journalBefore,
           "import touched the runtime login")
    let again = try await importer.importArchive(archive, passphrase: passphrase)
    expect(again.added == 0 && again.skipped == 2, "second import added accounts")
    let secrets = try FileManager.default.contentsOfDirectory(atPath: target.secretsDirectory.path)
    expect(!secrets.contains { $0.contains("import") }, "import left its journal behind")
    // The CLI writes the archive itself; it never replaces a file.
    let file = targetRoot.appendingPathComponent("accounts.\(CredentialTransfer.fileExtension)")
    try SecureFiles.create(archive, at: file)
    let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
    expect(mode == 0o600, "export mode")
    do { try SecureFiles.create(Data("other".utf8), at: file); fatalError("export replaced a file") } catch {}
    expect(bytes(file) == archive, "existing file changed")
}

actor CountingRenewer: TokenRenewing {
    var renewals = 0
    func renew(_ credential: Credential) async throws -> Credential { renewals += 1; return credential }
}

/// A login about to expire is renewed by Lilt only while no scope holds it. Once an account is fixed to a project,
/// that project's CLI renews it and Lilt reads the result back; two renewals of one refresh token would leave one side
/// with a token the server already spent.
func testProjectAccountsAreNotRenewed() async throws {
    let (store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try SecureFiles.write(credential("renew-default").data, to: store.paths.credentials)
    let expiring = Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": "fixture-access-renew-p", "refreshToken": "fixture-refresh-renew-p",
        "expiresAt": Int64(Date.now.timeIntervalSince1970 * 1000 + 120_000), "scopes": ["user:profile", "user:inference"]]]))
    let renewer = CountingRenewer()
    let usage = GatedUsage([expiring.token!: roomy(), "fixture-access-renew-default": roomy()])
    let engine = try HeadlessEngine(store: store, usageClient: usage, identityClient: FakeIdentity(identities: [:]), renewer: renewer, requestGap: 0)
    _ = try await engine.takeOver(label: "Default")
    let id = try await engine.add(expiring, identity: identity("renew-p"), label: "P", kind: .oauth)
    await engine.refresh(id, manually: true)
    let before = await renewer.renewals
    expect(before == 1, "an unbound expiring login was not renewed: \(before)")
    let project = root.appendingPathComponent("Renew Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    _ = try await engine.bindProject(rootPath: project.path, accountID: id, allowShared: false)
    await engine.refresh(id, manually: true)
    _ = try await engine.projectLaunch(rootPath: project.path)
    let after = await renewer.renewals
    expect(after == 1, "Lilt renewed a login a project scope holds")
}
