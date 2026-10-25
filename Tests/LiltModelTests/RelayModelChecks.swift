import Foundation
import Darwin
import LiltCore

@main struct RelayModelChecks {
    @MainActor static func main() async throws {
        func snapshot(_ used: Double, age: TimeInterval = 0) -> UsageSnapshot {
            UsageSnapshot(fiveHour: UsageWindow(used: used), sevenDay: UsageWindow(used: 20), sampledAt: .now.addingTimeInterval(-age))
        }
        var source = Library()
        var active = Account(label: "Fixture A", kind: .oauth)
        active.usage = snapshot(100); active.usageCapability = .verified; active.hotSwitchCapability = .verified
        var spare = Account(label: "Fixture B", kind: .oauth)
        spare.usage = snapshot(100); spare.usageCapability = .verified; spare.hotSwitchCapability = .verified
        source.accounts = [active, spare]; source.activeID = active.id; source.preferences.autoRelay = true

        var retryTime = Date.now
        let model = AppModel(preview: source, retryClock: { retryTime })
        await model.relay()
        precondition(model.autoRelay && model.library.preferences.autoRelay == true, "No candidate must not turn relay off")
        precondition(model.active?.id == active.id && model.relayExplanation?.contains("等待") == true)
        precondition(model.library.preferences.autoRelayStopReason == nil)

        // A candidate recovers, but repeated monitor ticks must respect the retry delay.
        model.library.accounts[1].usage = snapshot(20)
        await model.relay()
        precondition(model.active?.id == active.id, "Wait must not poll/switch on every tick")
        retryTime = retryTime.addingTimeInterval(121)
        await model.relay()
        precondition(model.autoRelay && model.active?.id == spare.id, "Recovery must resume without toggling relay")
        precondition(model.relayPause == nil)

        // Missing, stale and partial data keep relay armed, but never justify a switch. The account taken must have
        // been read in the last two minutes (`RelayPolicy.confirmLifetime`), so stale means older than that.
        for usage: UsageSnapshot? in [nil, snapshot(20, age: 121), UsageSnapshot(fiveHour: UsageWindow(used: 20))] {
            var fixture = source; fixture.accounts[1].usage = usage
            let waiting = AppModel(preview: fixture)
            await waiting.relay()
            precondition(waiting.autoRelay && waiting.active?.id == active.id)
            precondition(waiting.relayPause != nil)
        }

        // A rejected credential is never applied, even if its quota looks plentiful.
        var rejected = source; rejected.accounts[1].usage = snapshot(20); rejected.accounts[1].refreshRejected = true
        let quarantined = AppModel(preview: rejected)
        await quarantined.relay()
        precondition(quarantined.autoRelay && quarantined.active?.id == active.id)

        // Safety stops keep their explanation through persistence and relaunch.
        model.stopRelay(because: "Fixture safety stop")
        precondition(!model.autoRelay && model.relayExplanation?.contains("Fixture safety stop") == true)
        let encoded = try JSONEncoder().encode(model.library)
        let restarted = AppModel(preview: try JSONDecoder().decode(Library.self, from: encoded))
        precondition(!restarted.autoRelay && restarted.relayPause == "Fixture safety stop")
        await restarted.relay()
        precondition(restarted.active?.id == spare.id)

        // Explicit off stays off even when the next account becomes usable.
        let manual = AppModel(preview: source)
        await manual.relay()
        manual.setAutoRelay(false)
        manual.library.accounts[1].usage = snapshot(20)
        await manual.relay()
        precondition(!manual.autoRelay && manual.active?.id == active.id && manual.relayPause == nil)
        let api = AppModel(preview: source)
        api.observeAPIMode(true)
        await api.relay()
        precondition(api.autoRelay && api.active?.id == active.id && api.displayedActiveID == nil)
        precondition(api.notice()?.text == "检测到 API 模式")
        api.keepAPI()
        precondition(!api.autoRelay && api.keepsAPIMode && api.library.preferences.autoRelay == false)
        api.observeAPIMode(false)
        precondition(api.keepsAPIMode && api.relayPause?.contains("API 配置已移除") == true)
        api.observeAPIMode(true)
        let automaticApplied = await api.apply(spare.id, automatically: true)
        precondition(!automaticApplied && api.keepsAPIMode)
        let manualApplied = await api.apply(spare.id)
        precondition(manualApplied && !api.apiModeDetected && !api.keepsAPIMode && api.displayedActiveID == spare.id)
        // Settings changes one window's threshold at a time; the other keeps the figure it had.
        let tuned = AppModel(preview: source)
        precondition(tuned.thresholds == Thresholds(1))
        tuned.setFiveHourThreshold(15)
        precondition(tuned.thresholds == Thresholds(fiveHour: 15, sevenDay: 1) && tuned.handOffRule.contains("5 小时剩余 ≤15%"))
        tuned.setSevenDayThreshold(3); tuned.setFiveHourThreshold(40)
        precondition(tuned.thresholds == Thresholds(fiveHour: 20, sevenDay: 3), "Both stay within 0–20%")
        try await pauseChecks()
        try await autoSortChecks()
        try await scopeWatchChecks()
        try await interruptedSwitchChecks()
        try await dualModelChecks()
        try await refreshRecoveryChecks()
        try await emptyFileTakeoverCheck()
        try fileRuntimeChecks()
        try runtimeChecks()
        try keychainCommandChecks()
        print("PASS: relay model — temporary unavailability, retry/recovery, stale/missing/partial quota, quarantine, persistent safety reason, manual off, retry timed to the next reset, grouped pause reasons, buttons usable during background reads, a switch by hand that does not wait for them, automatic order, scope and local reads that fail temporarily, switches the keychain stops halfway, quota refresh independent of the scope lock, manual retry vs server 429, the signal file for running CLIs, a threshold per window. No live credentials or requests.")
    }
}

/// How the live model watches the scope. A read that fails (the keychain stalls around sleep and wake) or a settings
/// file caught mid-write must leave relay on; only a scope that provably holds another account stops it.
/// Lilt's own files go under the fixture home the script sets; the scope is an in-memory credential store.
@MainActor func scopeWatchChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"), "Run through scripts/check-relay-model.sh, which points the home directory at work/")
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    func document(_ access: String, refresh: String?) -> Data {
        var login: [String: Any] = ["accessToken": access]
        if let refresh { login["refreshToken"] = refresh }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": login])
    }
    func fresh(_ used: Double) -> UsageSnapshot { UsageSnapshot(fiveHour: UsageWindow(used: used), sevenDay: UsageWindow(used: 20)) }
    var active = Account(label: "Fixture A", kind: .oauth); active.usage = fresh(30); active.usageCapability = .verified
    var spare = Account(label: "Fixture B", kind: .oauth); spare.usage = fresh(10); spare.usageCapability = .verified
    var library = Library()
    library.accounts = [active, spare]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = false
    // Neither login can be renewed by Lilt or checked with the profile endpoint here: no expiry, and the identities
    // settle every question locally, so no request is ever sent.
    let mine = document("fixture-access-a", refresh: "fixture-refresh-a")
    let theirs = document("fixture-access-b", refresh: "fixture-refresh-b")
    try AccountVault.write(mine, account: active.id.uuidString)
    try AccountVault.write(theirs, account: spare.id.uuidString)
    try AccountVault.write(Data(#"{"accountUuid":"fixture-account-a"}"#.utf8), account: Keychain.identityAccount(active.id))
    try AccountVault.write(Data(#"{"accountUuid":"fixture-account-b"}"#.utf8), account: Keychain.identityAccount(spare.id))
    let config = home.appendingPathComponent(".claude.json")
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-account-a"}}"#.utf8), to: config)

    var held: Data? = mine
    var failing: [Bool] = [] // one entry per keychain read, true = that read fails; empty = reads succeed
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        if !failing.isEmpty, failing.removeFirst() { throw AppFailure("钥匙串没有响应，可能在等你允许访问。") }
        return held
    }, write: { held = $0 }, delete: { held = nil }))
    try scope.rebaseline()
    let model = AppModel(fixture: library, runtime: scope)
    precondition(model.autoRelay)
    var settled: Bool

    // The keychain does not answer: nothing is known, nothing changes, relay stays on.
    failing = [true]
    settled = await model.reconcileScope(); precondition(!settled)
    precondition(model.autoRelay && model.scopeIssue == nil && model.library.preferences.autoRelayStopReason == nil)
    precondition(model.notice() == nil, "A moment's failure is not worth a word")
    precondition(model.notice(at: .now.addingTimeInterval(121))?.text == "暂时读不到默认登录", "One that lasts is")
    settled = await model.reconcileScope(); precondition(settled && model.scopeUnreadable == nil)

    // The CLI renewed the login, and the read that would take it in fails: wait, then take it in on the next pass.
    let renewed = document("fixture-access-a2", refresh: "fixture-refresh-a2")
    held = renewed
    failing = [false, true]
    settled = await model.reconcileScope(); precondition(!settled)
    precondition(model.autoRelay && model.scopeIssue == nil)
    settled = await model.reconcileScope(); precondition(settled && model.autoRelay)
    let kept = try AccountVault.read(account: active.id.uuidString)
    precondition(kept == renewed, "The renewal is kept for the account")

    // A local credential read that throws is also temporary, not proof of an outside account.
    let vault = Disk.root.appendingPathComponent("secrets").appendingPathComponent(active.id.uuidString)
    let backup = vault.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: vault, to: backup)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
    held = document("fixture-access-a3", refresh: "fixture-refresh-a3")
    settled = await model.reconcileScope(); precondition(!settled)
    precondition(model.autoRelay && model.scopeIssue == nil, "A local read failure must not become a permanent safety stop")
    try FileManager.default.removeItem(at: vault)
    try FileManager.default.moveItem(at: backup, to: vault)
    held = renewed
    settled = await model.reconcileScope(); precondition(settled && model.autoRelay && model.scopeUnreadable == nil)

    // A settings file caught mid-write by another tool reads as malformed. That waits too.
    let settings = home.appendingPathComponent(".claude/settings.json")
    try SecureFiles.write(Data(#"{"env":{"#.utf8), to: settings)
    settled = await model.reconcileScope(); precondition(!settled)
    precondition(model.autoRelay && model.library.preferences.autoRelayStopReason == nil)
    try SecureFiles.write(Data("{}".utf8), to: settings)
    settled = await model.reconcileScope(); precondition(settled)

    // An automatic hand-off whose scope read fails right before writing leaves everything as it was, relay on.
    failing = [false, true]
    settled = await model.apply(spare.id, automatically: true); precondition(!settled)
    precondition(model.autoRelay && model.active?.id == active.id && held == renewed && !scope.transactionPending)
    settled = await model.apply(spare.id, automatically: true); precondition(settled && model.active?.id == spare.id)
    precondition(held == theirs)

    // Every switch leaves running CLIs the signal to look again: an empty document whose time moves, never a login.
    let signal = home.appendingPathComponent(".claude/.credentials.json")
    func signalTime() -> Date? { (try? FileManager.default.attributesOfItem(atPath: signal.path))?[.modificationDate] as? Date }
    precondition((try? Data(contentsOf: signal)) == RuntimeScope.signal, "A switch leaves the signal, not a login")
    let firstTime = signalTime()
    settled = await model.apply(active.id); precondition(settled && held == renewed)
    precondition(signalTime() != nil && signalTime() != firstTime, "Each switch moves the signal's time")
    settled = await model.apply(spare.id); precondition(settled && held == theirs)
    settled = await model.reconcileScope(); precondition(settled && model.autoRelay, "The signal is part of what was written, not an outside change")

    // Another Claude account in the scope still stops relay and asks the user.
    held = document("fixture-access-c", refresh: nil)
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-account-c"}}"#.utf8), to: config)
    settled = await model.reconcileScope(); precondition(!settled)
    precondition(!model.autoRelay && model.scopeIssue != nil && model.library.preferences.autoRelayStopReason != nil)
    // Stopping management takes the signal away again, so the CLI goes back to watching the keychain by itself.
    scope.removeSignal()
    precondition(!FileManager.default.fileExists(atPath: signal.path))
}

/// A hand-off the keychain stops halfway (a write or the read after it does not answer) keeps relay on. A switch that
/// left nothing changed leaves no unfinished journal; one that left the scope unknown is settled by the next check that
/// reads: forward when the new login landed, back when it did not. Anything else in the scope still stops relay.
@MainActor func interruptedSwitchChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"), "Run through scripts/check-relay-model.sh, which points the home directory at work/")
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    func document(_ access: String) -> Data { try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": access, "refreshToken": access + "-refresh"]]) }
    func fresh(_ used: Double) -> UsageSnapshot { UsageSnapshot(fiveHour: UsageWindow(used: used), sevenDay: UsageWindow(used: 20)) }
    var active = Account(label: "Fixture D", kind: .oauth); active.usage = fresh(99); active.usageCapability = .verified
    var spare = Account(label: "Fixture E", kind: .oauth); spare.usage = fresh(10); spare.usageCapability = .verified
    var library = Library()
    library.accounts = [active, spare]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = false
    let mine = document("fixture-access-d"), theirs = document("fixture-access-e")
    try AccountVault.write(mine, account: active.id.uuidString)
    try AccountVault.write(theirs, account: spare.id.uuidString)
    try AccountVault.write(Data(#"{"accountUuid":"fixture-account-d"}"#.utf8), account: Keychain.identityAccount(active.id))
    try AccountVault.write(Data(#"{"accountUuid":"fixture-account-e"}"#.utf8), account: Keychain.identityAccount(spare.id))
    let config = home.appendingPathComponent(".claude.json")
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-account-d"}}"#.utf8), to: config)
    let signal = home.appendingPathComponent(".claude/.credentials.json")
    try? FileManager.default.removeItem(at: signal)

    var held: Data? = mine
    var failing: [Bool] = [] // one entry per keychain read, true = that read fails
    var writes: [Bool] = []  // one entry per keychain write: true = it lands and then reports a failure, false = it fails without landing
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        if !failing.isEmpty, failing.removeFirst() { throw AppFailure("钥匙串没有响应，可能在等你允许访问。") }
        return held
    }, write: { data in
        guard !writes.isEmpty else { held = data; return }
        if writes.removeFirst() { held = data }
        throw AppFailure("钥匙串没有响应，可能在等你允许访问。")
    }, delete: { held = nil }))
    try scope.rebaseline()
    let model = AppModel(fixture: library, runtime: scope)
    var done: Bool

    // The write fails and everything reads back as before: nothing to settle, relay on and waiting to try again.
    writes = [false]
    done = await model.apply(spare.id, automatically: true); precondition(!done)
    precondition(model.autoRelay && model.library.preferences.autoRelayStopReason == nil && model.relayRetryAt != nil)
    precondition(model.active?.id == active.id && held == mine && !scope.transactionPending, "A clean rollback leaves no unfinished switch")
    precondition(model.relayPause?.contains("Fixture E") == true, "The wait says which account and why")

    // The write fails, and the keychain does not answer to the rollback either: the switch stays pending, relay stays on.
    // Reads: the check before writing and the switch's own two succeed; the rollback's and the final look fail.
    writes = [false]; failing = [false, false, false, false, false, true, true]
    done = await model.apply(spare.id, automatically: true); precondition(!done)
    precondition(model.autoRelay && model.library.preferences.autoRelayStopReason == nil && scope.transactionPending)
    // While the keychain still does not answer, the check waits rather than stopping anything.
    failing = [true]
    done = await model.reconcileScope(); precondition(!done && model.autoRelay && model.scopeIssue == nil)
    // Once it answers, the scope holds the login Lilt keeps for the account in use: the switch never landed.
    done = await model.reconcileScope(); precondition(done && model.autoRelay && model.scopeIssue == nil)
    precondition(model.active?.id == active.id && !scope.transactionPending && held == mine)

    // The write lands but reports a failure, and the keychain then stops answering: once it answers again, the
    // switch is finished, not undone.
    writes = [true]; failing = [false, false, false, false, false, true, true]
    done = await model.apply(spare.id, automatically: true); precondition(!done)
    precondition(model.autoRelay && scope.transactionPending && held == theirs && model.active?.id == active.id)
    done = await model.reconcileScope(); precondition(done && model.autoRelay && model.scopeIssue == nil)
    precondition(model.active?.id == spare.id && !scope.transactionPending, "The account that landed is the one in use")
    precondition((try? Data(contentsOf: signal)) == RuntimeScope.signal, "Running CLIs are told to look again")
    precondition(RuntimeScope.identity(at: config).flatMap { String(data: $0, encoding: .utf8) }?.contains("fixture-account-e") == true)
    done = await model.reconcileScope(); precondition(done && model.autoRelay)

    // A switch left pending with a login Lilt does not keep in the scope still stops relay and asks the user.
    writes = [false]; failing = [false, false, false, false, false, true, true]
    done = await model.apply(active.id, automatically: true); precondition(!done && scope.transactionPending)
    held = document("fixture-access-f")
    done = await model.reconcileScope(); precondition(!done)
    precondition(!model.autoRelay && model.scopeIssue != nil && model.library.preferences.autoRelayStopReason != nil)
    try? FileManager.default.removeItem(at: signal)
}

@MainActor func dualModelChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    let file = home.appendingPathComponent(".claude/.credentials.json")
    let journal = home.appendingPathComponent("lilt/transaction-system.json")
    try? FileManager.default.removeItem(at: journal)
    func document(_ value: String) -> Data { Data(#"{"claudeAiOauth":{"accessToken":""#.utf8) + Data(value.utf8) + Data(#""}}"#.utf8) }
    func fresh() -> UsageSnapshot { UsageSnapshot(fiveHour: UsageWindow(used: 10), sevenDay: UsageWindow(used: 20)) }
    var active = Account(label: "Fixture dual A", kind: .oauth); active.usage = fresh(); active.usageCapability = .verified
    var spare = Account(label: "Fixture dual B", kind: .oauth); spare.usage = fresh(); spare.usageCapability = .verified
    let mine = document("fixture-dual-a"), theirs = document("fixture-dual-b")
    try AccountVault.write(mine, account: active.id.uuidString)
    try AccountVault.write(theirs, account: spare.id.uuidString)
    try AccountVault.write(Data(#"{"accountUuid":"fixture-dual-a"}"#.utf8), account: Keychain.identityAccount(active.id))
    try AccountVault.write(Data(#"{"accountUuid":"fixture-dual-b"}"#.utf8), account: Keychain.identityAccount(spare.id))
    try SecureFiles.write(Data(#"{"oauthAccount":{"accountUuid":"fixture-dual-a"}}"#.utf8), to: home.appendingPathComponent(".claude.json"))
    var library = Library()
    library.accounts = [active, spare]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = false
    var held: Data? = mine
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0 }, delete: { held = nil }))
    try SecureFiles.write(RuntimeScope.signal, to: file)
    try scope.rebaseline()
    var refreshes = 0
    let model = AppModel(fixture: library, runtime: scope, usageFetch: { _ in refreshes += 1; return fresh() })

    held = theirs
    try SecureFiles.write(mine, to: file)
    var done = await model.reconcileScope()
    precondition(!done && model.dualConflict && !model.autoRelay && model.displayedActiveID == nil)
    done = await model.apply(spare.id, automatically: true)
    precondition(!done && held == theirs && (try! Data(contentsOf: file)) == mine)

    model.resolveDualConflict(useFile: true)
    while model.busy || model.loading { try await Task.sleep(for: .milliseconds(5)) }
    precondition(!model.dualConflict && model.active?.id == active.id && model.library.accounts.count == 2)
    precondition(held == mine && (try! Data(contentsOf: file)) == RuntimeScope.signal)

    held = theirs
    try SecureFiles.write(mine, to: file)
    done = await model.reconcileScope(); precondition(!done && model.dualConflict)
    model.resolveDualConflict(useFile: false)
    while model.busy || model.loading { try await Task.sleep(for: .milliseconds(5)) }
    precondition(!model.dualConflict && model.active?.id == spare.id && model.library.accounts.count == 2)
    precondition(held == theirs && (try! Data(contentsOf: file)) == RuntimeScope.signal)
    let config = home.appendingPathComponent(".claude.json")
    precondition(RuntimeScope.identity(at: config).flatMap { String(data: $0, encoding: .utf8) }?.contains("fixture-dual-b") == true)
    let storedIdentity = try AccountVault.read(account: Keychain.identityAccount(spare.id))
    precondition(storedIdentity.flatMap { String(data: $0, encoding: .utf8) }?.contains("fixture-dual-b") == true)

    // The file may belong to another vault account, not only the currently active one.
    held = theirs
    try SecureFiles.write(mine, to: file)
    done = await model.reconcileScope(); precondition(!done && model.dualConflict)
    model.resolveDualConflict(useFile: true)
    while model.busy || model.loading { try await Task.sleep(for: .milliseconds(5)) }
    precondition(!model.dualConflict && model.active?.id == active.id && model.library.accounts.count == 2)
    precondition(refreshes == 3, "Every successful resolution gets past busy and refreshes the final account")
}

/// Quota reads use the account's own stored login, not the scope's keychain or lock. Temporary local failures do not
/// become authentication failures; a person can retry through an ordinary backoff, but not through a server 429.
@MainActor func refreshRecoveryChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"))
    var active = Account(label: "Fixture refresh A", kind: .oauth)
    active.usage = UsageSnapshot(fiveHour: UsageWindow(used: 30), sevenDay: UsageWindow(used: 20))
    active.usageCapability = .verified
    var spare = Account(label: "Fixture refresh B", kind: .oauth)
    spare.usage = active.usage; spare.usageCapability = .verified
    var library = Library()
    library.accounts = [active, spare]; library.activeID = active.id
    library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
    library.preferences.autoRelay = true; library.preferences.liveUsage = false
    let login = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-refresh-access", "refreshToken": "fixture-refresh-token"]])
    try AccountVault.write(login, account: active.id.uuidString)
    var keychainCalls = 0
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        keychainCalls += 1
        throw AppFailure("Fixture keychain unavailable")
    }, write: { _ in }, delete: { }))
    var calls = 0
    var failures: [Error?] = []
    let model = AppModel(fixture: library, runtime: scope, usageFetch: { _ in
        calls += 1
        if !failures.isEmpty, let failure = failures.removeFirst() { throw failure }
        return UsageSnapshot(fiveHour: UsageWindow(used: 25), sevenDay: UsageWindow(used: 20))
    })

    await model.refresh(active.id, manually: true)
    precondition(calls == 1 && keychainCalls == 0, "A quota read neither reads nor waits for the scope keychain")
    precondition(model.active?.usage?.fiveHour?.used == 25 && model.status == "额度已更新")

    failures = [ScopeUnreadable(AppFailure("Fixture local read unavailable"))]
    await model.refresh(active.id)
    precondition(calls == 2 && model.active?.issue == nil && model.autoRelay)
    await model.refresh(active.id)
    precondition(calls == 3, "A temporary local failure creates no authentication backoff")

    failures = [UsageFailure.network]
    await model.refresh(active.id)
    precondition(calls == 4)
    await model.refresh(active.id)
    precondition(calls == 4, "Automatic reads respect an ordinary backoff")
    await model.refresh(active.id, manually: true)
    precondition(calls == 5 && model.status == "额度已更新", "A manual refresh can retry an ordinary backoff")

    model.busy = true
    await model.refresh(active.id, manually: true)
    precondition(model.status == "正在切换账号，完成后即可刷新")
    model.busy = false; model.loading = true
    await model.refresh(active.id, manually: true)
    precondition(model.status == "正在读取额度，请稍候")
    model.loading = false

    failures = [UsageFailure.rateLimited(120)]
    await model.refresh(active.id, manually: true)
    precondition(calls == 6)
    await model.refresh(active.id, manually: true)
    precondition(calls == 6 && model.status.contains("稍后再查"), "A server 429 still blocks a manual retry")
}

/// With every other account used up, relay waits for the first one to get its quota back and tries again then, not up
/// to two minutes later; many accounts sharing one reason are summed up in one phrase. Background reads leave the
/// notice's dismiss button and the account buttons usable.
@MainActor func pauseChecks() async throws {
    var library = Library()
    func spent(_ label: String, resetsIn seconds: TimeInterval) -> Account {
        var account = Account(label: label, kind: .oauth)
        account.usageCapability = .verified; account.hotSwitchCapability = .verified
        account.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: .now.addingTimeInterval(seconds)), sevenDay: UsageWindow(used: 20, resetsAt: .now.addingTimeInterval(86400)))
        return account
    }
    let active = spent("Fixture A", resetsIn: 3600)
    let others = (1...5).map { spent("Fixture \($0)", resetsIn: $0 == 3 ? 30 : 7200) }
    library.accounts = [active] + others; library.activeID = active.id; library.preferences.autoRelay = true
    var retryTime = Date.now
    let model = AppModel(preview: library, retryClock: { retryTime })
    await model.relay()
    precondition(model.autoRelay && model.active?.id == active.id)
    precondition(model.relayPause?.hasPrefix("5 个账号额度不足或不完整。") == true, "One phrase for one shared reason")
    precondition(model.relayPause?.contains("最早 1 分钟后有账号恢复") == true)
    // Fixture 3 gets its quota back in 30 seconds; the next try is due right after, well inside two minutes.
    let back = others[2].id
    model.update(back) { $0.usage = UsageSnapshot(fiveHour: UsageWindow(used: 0), sevenDay: UsageWindow(used: 20, resetsAt: .now.addingTimeInterval(86400))) }
    retryTime = retryTime.addingTimeInterval(20)
    await model.relay()
    precondition(model.active?.id == active.id, "Not before the reset")
    retryTime = retryTime.addingTimeInterval(20)
    await model.relay()
    precondition(model.active?.id == back, "Right after the reset")

    model.appliedPending = true
    model.loading = true
    precondition(!model.blocks(.confirmApplied) && !model.blocks(.openScope), "Dismissing a note never waits for a read")
    precondition(!model.blocks(.refresh(back)) && !model.blocks(.reauthorize(back)), "A manual refresh stays clickable and explains the read in progress")
    model.busy = true
    precondition(model.blocks(.reauthorize(back)) && !model.blocks(.confirmApplied))
    model.busy = false
    // A switch by hand goes ahead during a read in progress: it neither waits for the read nor is refused.
    let started = Date.now
    let switched = await model.apply(active.id)
    precondition(switched && model.active?.id == active.id && model.loading && Date.now.timeIntervalSince(started) < 0.2)
    model.loading = false
}

/// Sorting changes only the order the model shows and relays in. The user's own arrangement survives it, and a
/// hand-off still waits for the threshold, then takes the emptiest 5-hour window, the order deciding between equals.
@MainActor func autoSortChecks() async throws {
    func account(_ label: String, five: Double, week: Double, weekResetsIn days: Double) -> Account {
        var account = Account(label: label, kind: .oauth)
        account.usageCapability = .verified; account.hotSwitchCapability = .verified
        account.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100 - five), sevenDay: UsageWindow(used: 100 - week, resetsAt: .now.addingTimeInterval(days * 86400)))
        return account
    }
    var library = Library()
    let active = account("Fixture A", five: 60, week: 50, weekResetsIn: 3)
    let later = account("Fixture B", five: 100, week: 100, weekResetsIn: 6)
    let soonUsed = account("Fixture C", five: 40, week: 70, weekResetsIn: 1)
    let soonFresh = account("Fixture D", five: 100, week: 30, weekResetsIn: 1)
    library.accounts = [active, later, soonUsed, soonFresh]; library.activeID = active.id; library.preferences.autoRelay = true
    library.preferences.soonerWeekly = true
    let model = AppModel(preview: library)
    model.setAutoSort(true)
    precondition(model.autoSort && !model.soonerWeekly, "Sorting and the early weekly hand-off are one or the other")
    precondition(model.accounts.map(\.label) == ["Fixture C", "Fixture D", "Fixture A", "Fixture B"])
    precondition(model.library.accounts.map(\.label) == ["Fixture A", "Fixture B", "Fixture C", "Fixture D"])
    model.move(later.id, by: -1); model.move(later.id, to: active.id)
    precondition(model.library.accounts.map(\.label) == ["Fixture A", "Fixture B", "Fixture C", "Fixture D"], "No manual moves while sorted")
    // Still above the threshold: the account in use is kept, however the order looks.
    await model.relay()
    precondition(model.active?.id == active.id)
    model.library.accounts[0].usage?.fiveHour = UsageWindow(used: 99.5)
    await model.relay()
    precondition(model.active?.id == soonFresh.id, "The emptiest 5-hour window, and the relay order between equally empty ones")
    model.setSoonerWeekly(true)
    precondition(!model.autoSort && model.accounts.map(\.label) == ["Fixture A", "Fixture B", "Fixture C", "Fixture D"])
}

func keychainCommandChecks() throws {
    let fixture = try JSONSerialization.data(withJSONObject: [
        "claudeAiOauth": ["accessToken": "fixture-token", "refreshToken": "fixture-refresh"],
        "other": String(repeating: "x", count: 2200) + " 引号\" 反斜杠\\ $() `literal`"
    ], options: [.withoutEscapingSlashes])
    let service = "app.lilt.fixture-" + UUID().uuidString
    let command = try CLIKeychain.writeCommand(fixture, service: service, account: "fixture-user")
    precondition(command.contains(" -w ") && command.utf8.count < 3800)
    precondition(command.filter { $0 == "\n" }.count == 1)
    let multiline = Data("{\n\"fixture\":\"fictional-value\"\n}".utf8)
    let multilineCommand = try CLIKeychain.writeCommand(multiline, service: service, account: "fixture-user")
    precondition(multilineCommand.contains(" -X "))
    // Opt-in integration: a unique disposable item, never the CLI's real login or Lilt's stored accounts.
    if ProcessInfo.processInfo.environment["LILT_TEST_KEYCHAIN"] == "1" {
        defer { try? CLIKeychain.delete(service: service) }
        try CLIKeychain.write(fixture, service: service)
        let read = try CLIKeychain.read(service: service)
        guard read == fixture else { throw AppFailure("Fixture large JSON did not round-trip exactly.") }
        try CLIKeychain.write(multiline, service: service)
        let multilineRead = try CLIKeychain.read(service: service)
        guard multilineRead == multiline else { throw AppFailure("Fixture multiline JSON did not round-trip exactly.") }
        print("PASS: isolated macOS keychain item — large JSON and multiline JSON round-trip, no real credentials accessed.")
    }
}

/// First takeover works with no runtime login and always applies the selected account to the official keychain.
@MainActor func emptyFileTakeoverCheck() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"))
    for path in [".claude/.credentials.json", "lilt/transaction-system.json"] {
        try? FileManager.default.removeItem(at: home.appendingPathComponent(path))
    }
    var wanted = Account(label: "Fixture empty takeover", kind: .oauth)
    wanted.usage = UsageSnapshot(fiveHour: UsageWindow(used: 10), sevenDay: UsageWindow(used: 20))
    wanted.usageCapability = .verified
    var library = Library()
    library.accounts = [wanted]; library.activeID = wanted.id
    library.preferences.liveUsage = false
    let login = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-empty-takeover"]])
    try AccountVault.write(login, account: wanted.id.uuidString)
    var keychainCalls = 0
    var held: Data?
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        keychainCalls += 1; return held
    }, write: { keychainCalls += 1; held = $0 }, delete: { keychainCalls += 1; held = nil }))
    let model = AppModel(fixture: library, runtime: scope)
    await model.takeOverDefaultLogin()
    precondition(model.library.preferences.scopeEnabled && model.active?.id == wanted.id)
    precondition(try! scope.currentCredential()?.data == login)
    precondition(keychainCalls > 0 && !model.busy && model.status == "已接管默认登录")
}

/// The official keychain is authoritative; a real file login is only a conflict to resolve, never a second runtime.
func fileRuntimeChecks() throws {
    let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/Lilt-dual-runtime-fixture-" + UUID().uuidString)
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appendingPathComponent(".claude/.credentials.json")
    let earlier = Data(#"{"claudeAiOauth":{"accessToken":"fixture-keychain-earlier"}}"#.utf8)
    let subscription = Credential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-subscription"}}"#.utf8))
    let external = Data(#"{"claudeAiOauth":{"accessToken":"fixture-file-external"}}"#.utf8)
    var held: Data? = earlier
    var writes = 0
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: {
        writes += 1; held = $0
    }, delete: { held = nil }))
    try SecureFiles.write(external, to: file)

    // The original split-auth report: every ordinary path refuses before changing either side, even explicit force.
    for action in [{ try scope.check() }, { try scope.apply(subscription, replacingExternalState: true) }, { try scope.rebaseline() }, { try scope.settle() }] {
        do { try action(); fatalError("Expected dual-runtime conflict") } catch is DualRuntimeConflict {}
    }
    precondition(held == earlier && (try! Data(contentsOf: file)) == external && writes == 0)

    try scope.resolveDual(using: .keychain, expected: Credential(data: earlier))
    precondition(held == earlier && (try! Data(contentsOf: file)) == RuntimeScope.signal)
    try scope.check()

    // Pending never bypasses dual detection, and an expected snapshot is rechecked under the scope lock.
    try SecureFiles.write(external, to: file)
    let journal = home.appendingPathComponent("lilt/transaction-system.json")
    var transaction = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
    transaction["pending"] = true
    try SecureFiles.write(JSONSerialization.data(withJSONObject: transaction), to: journal)
    for action in [{ try scope.check() }, { try scope.settle() }, { try scope.apply(subscription, replacingExternalState: true) }] {
        do { try action(); fatalError("Expected pending dual-runtime conflict") } catch is DualRuntimeConflict {}
    }
    transaction["pending"] = false
    try SecureFiles.write(JSONSerialization.data(withJSONObject: transaction), to: journal)
    var raceReads = 0
    let raced = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        raceReads += 1; return raceReads == 1 ? earlier : external
    }, write: { _ in writes += 1 }, delete: {}))
    do { try raced.resolveDual(using: .keychain, expected: Credential(data: earlier)); fatalError("Expected later-change refusal") } catch {}
    precondition(raceReads >= 2 && writes == 1, "A renewal after the expected read must not be overwritten")
    do { try scope.resolveDual(using: .file, expected: subscription); fatalError("Expected changed-source refusal") } catch {}
    precondition(held == earlier && (try! Data(contentsOf: file)) == external)
    try scope.resolveDual(using: .file, expected: Credential(data: external))
    precondition(held == external && (try! Data(contentsOf: file)) == RuntimeScope.signal)
    try scope.check()

    // A file-only fallback also migrates into the official keychain instead of becoming a second runtime.
    held = nil
    try SecureFiles.write(external, to: file)
    do { try scope.check(); fatalError("Expected file-only conflict") } catch is DualRuntimeConflict {}
    try scope.resolveDual(using: .file, expected: Credential(data: external))
    precondition(held == external && (try! Data(contentsOf: file)) == RuntimeScope.signal)

    // Identical copies are normalized without an account switch; a missing file needs no conflict action.
    try SecureFiles.write(external, to: file)
    try scope.rebaseline()
    precondition((try! Data(contentsOf: file)) == RuntimeScope.signal)
    try scope.check()
    try FileManager.default.removeItem(at: file)
    try scope.rebaseline()
    try scope.check()
    precondition(held == external && writes == 3)
    print("PASS: keychain-only runtime — split-auth refusal, explicit authority choice, file-only migration and signal normalization.")
}

func runtimeChecks() throws {
    let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/Lilt-switch-fixture-" + UUID().uuidString)
    try SecureFiles.directory(home.appendingPathComponent(".claude"))
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = home.appendingPathComponent(".claude/settings.json")
    let api = Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-api","ANTHROPIC_BASE_URL":"https://provider.invalid","ANTHROPIC_MODEL":"fixture-provider-model","HTTPS_PROXY":"http://proxy.invalid","USER_NOTE":"keep"},"forceLoginMethod":"console","apiKeyHelper":"fixture-helper","model":"fixture-model","permissions":{"allow":["Read"]},"statusLine":{"command":"fixture-statusline"},"hooks":{},"enabledPlugins":{"fixture":true}}"#.utf8)
    let earlier = Data(#"{"claudeAiOauth":{"accessToken":"fixture-earlier"}}"#.utf8)
    let external = Data(#"{"claudeAiOauth":{"accessToken":"fixture-external"}}"#.utf8)
    let subscription = Credential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-subscription"}}"#.utf8))
    var held: Data? = earlier
    var onWrite: ((Data) throws -> Void)?
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: {
        held = $0; try onWrite?($0)
    }, delete: { held = nil }))
    try scope.rebaseline()
    held = external
    try SecureFiles.write(api, to: settings)
    func expectFailure(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected safe refusal") } catch {}
    }
    expectFailure { try scope.apply(subscription) }
    precondition(held == external && (try! Data(contentsOf: settings)) == api)
    try scope.apply(subscription, replacingExternalState: true)
    precondition(held == subscription.data && !(try! scope.hasAPIOverride()))
    let cleaned = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    let env = cleaned["env"] as! [String: String]
    precondition(env == ["HTTPS_PROXY": "http://proxy.invalid", "USER_NOTE": "keep"])
    precondition(cleaned["permissions"] != nil && cleaned["statusLine"] != nil && cleaned["hooks"] != nil && cleaned["enabledPlugins"] != nil)
    precondition(cleaned["forceLoginMethod"] == nil && cleaned["apiKeyHelper"] == nil && cleaned["model"] == nil)
    precondition((try! AuthenticationSettings.subscriptionSettings(Data(contentsOf: settings))) == nil)
    let healthy = Data(#"{"env":{"HTTPS_PROXY":"http://proxy.invalid"},"model":"opus","forceLoginMethod":"claudeai"}"#.utf8)
    precondition((try! AuthenticationSettings.subscriptionSettings(healthy)) == nil)
    try scope.check()
    // Identical file and keychain logins normalize to the signal; releasing management removes only that signal.
    let fallback = home.appendingPathComponent(".claude/.credentials.json")
    precondition((try! Data(contentsOf: fallback)) == RuntimeScope.signal)
    try SecureFiles.write(subscription.data, to: fallback)
    try scope.rebaseline()
    precondition((try! Data(contentsOf: fallback)) == RuntimeScope.signal)
    scope.removeSignal()
    precondition(!FileManager.default.fileExists(atPath: fallback.path))
    // CC Switch may only change settings, leaving the credential digest unchanged.
    try SecureFiles.write(api, to: settings)
    expectFailure { try scope.apply(subscription) }
    precondition((try! Data(contentsOf: settings)) == api)
    // An unrelated simultaneous settings write is not erased, even on the explicit force path.
    let concurrent = Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-new-api"},"hooks":{"fixture":"new"}}"#.utf8)
    held = external
    onWrite = { data in if data == subscription.data { try SecureFiles.write(concurrent, to: settings) } }
    expectFailure { try scope.apply(subscription, replacingExternalState: true) }
    precondition(held == external && (try! Data(contentsOf: settings)) == concurrent)
    precondition(scope.transactionPending)
    onWrite = nil
    // A manual retry can recover the pending transaction; automation still cannot.
    expectFailure { try scope.apply(subscription) }
    try scope.apply(subscription, replacingExternalState: true)
    try scope.check()
    // Another writer that gets in after preparation but before anything is written: refused, and no unfinished switch
    // is left behind, because nothing was written.
    var reads = 0
    let racing = Data(#"{"claudeAiOauth":{"accessToken":"fixture-racing"}}"#.utf8)
    let raced = RuntimeScope(fixtureHome: home, credentials: .init(read: {
        reads += 1
        return reads > 1 ? racing : held // early reads prepare; a later read verifies before writing
    }, write: { held = $0 }, delete: { held = nil }))
    let before = held
    expectFailure { try raced.apply(Credential(data: external)) }
    precondition(reads == 3 && held == before && !raced.transactionPending)
    let malformed = Data("not-json".utf8)
    try SecureFiles.write(malformed, to: settings)
    held = external
    expectFailure { try scope.apply(subscription, replacingExternalState: true) }
    precondition(held == external && (try! Data(contentsOf: settings)) == malformed)
    try SecureFiles.write(api, to: settings)
    let fd = open(home.appendingPathComponent("lilt/.lilt-lock-system").path, O_RDWR)
    precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    expectFailure { try scope.apply(subscription, replacingExternalState: true) }
    precondition(held == external && (try! Data(contentsOf: settings)) == api)
    flock(fd, LOCK_UN); close(fd)
    // A symlink is not a user settings file we may replace.
    let outside = home.appendingPathComponent("outside.json")
    try SecureFiles.write(api, to: outside)
    try FileManager.default.removeItem(at: settings)
    try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: outside)
    expectFailure { try scope.apply(subscription, replacingExternalState: true) }
    precondition(held == external && (try! Data(contentsOf: outside)) == api)
    print("PASS: API → subscription transaction — explicit replacement, automatic refusal, preserve unrelated settings, concurrent edit rollback, pending recovery, malformed settings, lock and symlink refusal. In-memory credentials only.")
}
