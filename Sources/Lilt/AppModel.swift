import SwiftUI
import Observation
import LiltCore

/// Identify the running bundle consistently across the window, diagnostics and exports.
enum AppBuild {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    static let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未打包"
    static let revision = Bundle.main.object(forInfoDictionaryKey: "LiltSourceRevision") as? String ?? "未记录"
    static let timestamp = Bundle.main.object(forInfoDictionaryKey: "LiltBuildTime") as? String ?? "未记录"
    static var title: String { "Lilt \(version)" }
    static var description: String { "\(title)（构建 \(number)）" }
    static var date: String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// What the authorization sheet was opened for. One value, so "add" and "replace" cannot leak into each other.
struct AddRequest: Identifiable {
    let id = UUID()
    var replacing: UUID?
    var kind: AuthKind = .oauth
}
/// The one thing the user most needs to know about the applied account, with the next step when there is one.
struct Notice: Equatable {
    enum Action: Equatable {
        case reauthorize(UUID), refresh(UUID), refreshAll, openScope, confirmApplied, adoptScope
        var title: String {
            switch self {
            case .reauthorize: "重新授权"
            case .refresh: "刷新"
            case .refreshAll: "刷新全部额度"
            case .openScope: "查看接入"
            case .confirmApplied: "知道了"
            case .adoptScope: "处理"
            }
        }
        /// These continue in the management window, so the menu bar panel has to open it.
        var needsWindow: Bool { switch self { case .reauthorize, .openScope, .adoptScope: true; default: false } }
    }
    var symbol: String
    var text: String
    var detail: String?
    var warning = false
    var action: Action?
}

@MainActor @Observable
final class AppModel {
    var library = Library()
    var demo = false
    var loading = false
    var busy = false
    var loggingIn = false
    private(set) var autoRelay = false
    var status = "准备就绪"
    var message: String?
    var version = "检测中…"
    var selectedPage: Page = .overview
    var addRequest: AddRequest?
    /// The user asked to keep the scope's current credential; the window asks once more before it happens.
    var confirmingAdopt = false
    var appliedPending = false
    var lastEvent = "尚无接力记录"
    var shortcutIssue: String?
    var storageAvailable = true
    /// Advanced by the monitor so time-dependent views (staleness, backoff) re-evaluate without their own timers.
    private(set) var clock = Date.now
    private(set) var scopeIssue: String?
    /// Why the scope could not be read on the last pass, and since when. Nothing is known to be wrong meanwhile, so
    /// relay stays on and nothing is written until a pass reads it again.
    private(set) var scopeUnreadable: String?
    private var scopeUnreadableSince: Date?
    private(set) var relayPause: String?
    private(set) var apiModeDetected = false
    var keepsAPIMode: Bool { library.preferences.keepAPIMode == true }
    var displayedActiveID: UUID? { apiModeDetected || keepsAPIMode || scopeIssue != nil ? nil : library.activeID }
    private(set) var relayRetryAt: Date?
    private let retryClock: () -> Date
    /// Where the selected account's login goes. Files from before there was a choice always meant Lilt's own directory;
    /// anything set up now takes over Claude Code's default login.
    var scopeTarget: ScopeTarget { library.preferences.scopeTarget ?? (library.preferences.scopeEnabled ? .dedicated : .system) }
    var runtimeFileStorage: Bool { library.preferences.runtimeFileStorage == true }
    var runtime: RuntimeScope { fixtureRuntime ?? RuntimeScope(target: scopeTarget, fileStorage: runtimeFileStorage) }
    private var fixtureRuntime: RuntimeScope?
    /// Lilt is putting logins into Claude Code's default login, so a plain `claude` in any terminal uses them.
    var managesDefaultLogin: Bool { library.preferences.scopeEnabled && scopeTarget == .system }
    /// What the place Lilt writes to is called on screen.
    var scopeName: String { scopeTarget == .system ? "默认登录" : "Lilt 作用域" }
    let login = CLILogin()
    private var savedLibrary: Library?
    private var savedPending = false
    private var savedAPIMode = false
    private var backoffs: [UUID: Backoff] = [:]
    private var failures: [UUID: UsageFailure] = [:]
    /// The usage endpoint limits everything sent from this Mac, so a 429 for one account pauses them all (ORCA does
    /// the same). Readings already on screen stay there meanwhile.
    private(set) var usagePausedUntil: Date?
    private var lastUsageRequest = Date.distantPast
    /// Live quota from Claude Code's status line (see `StatusLineBridge`).
    var liveUsageEnabled: Bool { library.preferences.liveUsage != false }
    private(set) var statusLineIssue: String?
    private var lastSwitchAt = Date.distantPast
    private var lastFailureLogged: (text: String, at: Date)?
    private var liveStamp: Date?
    private var lastStatusLineCheck = Date.distantPast
    private var lastStatusLineRepair = Date.distantPast
    private var latch = RelayLatch()
    /// Who automatic relay just left, and when. `RelayPolicy.coolingDown` decides whether that still blocks them.
    private var departedID: UUID?
    private var departedAt: Date?
    /// Recent readings of the account in use, oldest first, for `UsagePace`. Emptied when another account takes over.
    private var paceReadings: [UsageSnapshot] = []
    private var paceAccount: UUID?
    private var scopeCheckedAt = Date.distantPast
    private var scopeRetryAt = Date.distantPast
    private var scopeReadFailures = 0
    private var preparedAt = Date.distantPast
    /// When the last status line reading was taken, for the 接入 page. Kept here so drawing the page reads no file.
    private(set) var liveUsageSampledAt: Date?
    /// One scope sequence at a time: a check and what it takes in, or a switch. Their reads and writes run on the I/O
    /// queue, so without this a pass of the monitor and a switch by hand could each read the scope halfway through the
    /// other changing it.
    private var scopeHeld = false
    private var scopeWaiting: [CheckedContinuation<Void, Never>] = []
    /// Renewals in flight, one per account. A switch and a background read of the same account share one, so the two
    /// never spend the same refresh token: the second spend is refused, and the account would need a new login.
    private var renewals: [UUID: Task<Credential, Error>] = [:]
    /// The library as it should be on disk, waiting for the I/O queue. Updates arriving meanwhile fold into one write.
    private var unsaved: Library?
    private var saving = false
    private var monitor: Task<Void, Never>?
    private var usageFetch: (Credential) async throws -> UsageSnapshot = { try await UsageClient().fetch($0) }
    let updater = Updater()
    enum Page: String, CaseIterable { case overview = "概览", accounts = "账号", scope = "接入", diagnostics = "诊断"
        var symbol: String { switch self { case .overview: "square.grid.2x2"; case .accounts: "person.2"; case .scope: "terminal"; case .diagnostics: "waveform.path.ecg" } }
    }
    init() {
        retryClock = { .now }
        do { library = try Disk.load() } catch { storageAvailable = false; message = "账号资料无法读取，已停止写入。请先检查本地数据；不会以空列表覆盖。" }
        // Being told to wait, or a dropped connection, is not a lasting problem with an account; earlier versions kept it as one.
        let passing: Set<String> = ["额度接口限流，已按服务端要求延后重试。", UsageFailure.rateLimited(0).message, UsageFailure.network.message]
        for index in library.accounts.indices where library.accounts[index].issue.map(passing.contains) == true { library.accounts[index].issue = nil }
        if storageAvailable {
            do { try CLILogin.cleanupStaleLogins() } catch { message = "上次授权的临时资料未能清理，请检查钥匙串与目录权限。" }
        }
        restoreRelayPreference()
        if storageAvailable, library.preferences.scopeEnabled {
            do { observeAPIMode(try runtime.hasAPIOverride()) } catch { noteUnreadable(error) }
        }
        if storageAvailable, managesDefaultLogin, liveUsageEnabled, !apiModeDetected { connectStatusLine() }
        Task { version = await CLILogin.version() }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                // A pass every 15 seconds, or within 3 of a session reporting quota while the account in use is close
                // to the threshold: a busy session can spend a few points in 15 seconds.
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    if await self.liveReadingWaiting() { break }
                }
                guard let self else { return }
                self.updater.checkIfDue(enabled: self.autoUpdateCheck)
                await self.tick()
            }
        }
    }
    /// A fully local model for previews and regression checks: no disk, keychain, network or monitor task.
    init(preview library: Library, retryClock: @escaping () -> Date = { .now }) {
        self.retryClock = retryClock
        demo = true
        self.library = library
        restoreRelayPreference()
    }
    /// A live model whose scope is an in-memory fixture, for regression checks of how the scope is watched. Lilt's own
    /// files still go under `Disk.root`, so the caller must point the home directory at a fixture first.
    init(fixture library: Library, runtime: RuntimeScope, usageFetch: ((Credential) async throws -> UsageSnapshot)? = nil) {
        retryClock = { .now }
        self.library = library
        fixtureRuntime = runtime
        if let usageFetch { self.usageFetch = usageFetch }
        restoreRelayPreference()
    }
    private func restoreRelayPreference() {
        autoRelay = library.preferences.autoRelay == true && relayBlocker == nil
        relayPause = library.preferences.autoRelay == true ? relayBlocker : library.preferences.autoRelayStopReason
    }
    /// The relay order: the user's own, or the sorted one while automatic sorting is on. `library.accounts` keeps the
    /// user's arrangement either way, so turning sorting off brings it back.
    var accounts: [Account] { autoSort ? RelayOrder.sorted(library.accounts, at: max(clock, .now)) : library.accounts }
    /// Looked up in the stored list: the order does not matter here, and sorting on every lookup was most of its cost.
    var active: Account? { library.accounts.first { $0.id == library.activeID } }
    var enabledCount: Int { accounts.filter(\.enabled).count }
    var thresholds: Thresholds { library.preferences.thresholds }
    /// When relay hands off, in the words the overview and the panel use.
    var handOffRule: String {
        let t = thresholds
        if t.fiveHour == t.sevenDay { return "剩余 ≤\(t.fiveHour.formatted())% 时换下一个" }
        return "5 小时剩余 ≤\(t.fiveHour.formatted())% 或 7 天剩余 ≤\(t.sevenDay.formatted())% 时换下一个"
    }
    /// Off unless the user turns it on. Nil in an older preferences file means off.
    var soonerWeekly: Bool { library.preferences.soonerWeekly == true }
    /// Off unless the user turns it on. Nil in an older preferences file means off.
    var autoSort: Bool { library.preferences.autoSort == true }
    var canAdd: Bool { !demo && !busy && storageAvailable }
    var setupComplete: Bool { !accounts.isEmpty && library.preferences.scopeEnabled && active != nil }
    func save() {
        guard !demo else { return }
        persist(library)
    }
    /// Written on the I/O queue; every quota reading saves, and a write waits for `fsync`.
    private func persist(_ value: Library) {
        guard storageAvailable else { return }
        unsaved = value
        guard !saving else { return }
        saving = true
        Task {
            while let next = unsaved, storageAvailable {
                unsaved = nil
                do { try await IOQueue.run { try Disk.save(next) } } catch { failStorage() }
            }
            unsaved = nil; saving = false
        }
    }
    /// For the few changes whose caller has to know at once that they reached the disk.
    private func saveNow() {
        guard !demo, storageAvailable else { return }
        unsaved = nil
        do { try IOQueue.sync { try Disk.save(library) } } catch { failStorage() }
    }
    /// Lilt is quitting: what is still waiting is written before it goes.
    func flushSaves() {
        guard let next = unsaved else { return }
        unsaved = nil
        IOQueue.sync { try? Disk.save(next) }
    }
    private func failStorage() {
        autoRelay = false; storageAvailable = false
        relayPause = "本地数据保存失败，请检查存储后重新打开 Lilt。"
        lastEvent = relayPause!; message = "本地数据保存失败，自动接力已停止。"
    }
    /// Preferences belong to the real library even while a demo is on screen, so a change made there still sticks.
    private func updatePreferences(_ change: (inout Preferences) -> Void) {
        change(&library.preferences)
        if demo, var real = savedLibrary { change(&real.preferences); savedLibrary = real; persist(real) } else { save() }
    }
    // Setting one keeps the other where it was: until now files without a weekly figure used the 5-hour one for both.
    func setFiveHourThreshold(_ value: Double) {
        updatePreferences { $0.weeklyThreshold = $0.weeklyThreshold ?? $0.threshold; $0.threshold = min(20, max(0, value)) }
    }
    func setSevenDayThreshold(_ value: Double) { updatePreferences { $0.weeklyThreshold = min(20, max(0, value)) } }
    /// The two cannot both be on. Sorting keeps an account until it reaches the threshold; the weekly preference
    /// would hand it off while it still has room.
    func setSoonerWeekly(_ on: Bool) { updatePreferences { $0.soonerWeekly = on; if on { $0.autoSort = false } } }
    func setAutoSort(_ on: Bool) { updatePreferences { $0.autoSort = on; if on { $0.soonerWeekly = false } } }
    func setShortcut(_ key: UInt32) { updatePreferences { $0.shortcutKey = key } }
    /// On unless the user turns it off. Nil in an older preferences file means on.
    var autoUpdateCheck: Bool { library.preferences.autoUpdateCheck != false }
    func setAutoUpdateCheck(_ on: Bool) { updatePreferences { $0.autoUpdateCheck = on } }
    /// Work that quitting for an update must not cut off. A token renewal runs under both flags, and stopping halfway
    /// through one could lose the only copy of a newly issued refresh token.
    var updateBlocker: String? {
        if loggingIn { return "正在添加账号，完成后再更新" }
        if busy { return "正在切换账号，完成后再更新" }
        if loading { return "正在读取额度，稍后再更新" }
        if saving || unsaved != nil { return "正在保存账号资料，稍后再更新" }
        return nil
    }
    func checkForUpdates() {
        Task {
            await updater.check(manual: true)
            switch updater.phase {
            case .current: status = "已是最新版本"
            case .available(let release): status = "发现新版本 \(release.version)"
            case .failed(let reason, _): status = reason
            default: break
            }
        }
    }
    func installUpdate() {
        Task {
            await updater.install { [weak self] in self?.updateBlocker }
            if case .failed(let reason, _) = updater.phase { status = "更新没有完成：\(reason)" }
        }
    }
    /// What still stands between the user and live automatic relay, in a few words; nil when it can be turned on.
    /// The demo has no prerequisites.
    var relayBlocker: String? {
        guard !demo else { return nil }
        if !storageAvailable { return "先恢复本地数据存储" }
        if apiModeDetected || keepsAPIMode { return "先选择订阅账号切回订阅模式" }
        if !library.preferences.scopeEnabled { return "先接管 Claude Code 默认登录" }
        guard let active else { return "先选一个账号" }
        // Without a reading for the account in use there is nothing to tell Lilt when to hand off.
        if active.usageCapability == .unavailable { return "当前账号读不到额度" }
        if !accounts.contains(where: { $0.id != active.id && $0.enabled && $0.usageCapability != .unavailable }) { return "还需要一个能读额度的备用账号" }
        return nil
    }
    /// Turning it on is the user's standing consent for Lilt to write the next account's credentials into the scope at the threshold.
    func setAutoRelay(_ on: Bool) {
        if on, let relayBlocker { status = relayBlocker; return }
        autoRelay = on
        relayPause = nil; relayRetryAt = nil
        if on { latch = RelayLatch() }
        if demo { library.preferences.autoRelay = on; library.preferences.autoRelayStopReason = nil }
        else { updatePreferences { $0.autoRelay = on; $0.autoRelayStopReason = nil } }
    }
    /// Relay stopped itself. The saved switch goes off too, so a relaunch does not quietly resume it.
    func stopRelay(because reason: String) {
        autoRelay = false
        relayRetryAt = nil
        relayPause = reason; status = "自动接力已停止：\(reason)"; lastEvent = reason
        library.preferences.autoRelay = false
        library.preferences.autoRelayStopReason = reason
        if !demo { logFailure("relay-stopped", reason) }
        if !demo, storageAvailable { save() }
    }
    /// Waiting for quota or a cooldown is not withdrawal of the user's consent.
    private func waitForRelay(because reason: String, until retryAt: Date) {
        relayPause = reason; relayRetryAt = retryAt
        status = "自动接力等待中"; lastEvent = reason
    }
    var relayExplanation: String? {
        guard let relayPause else { return nil }
        return "\(autoRelay ? "等待" : "已停止")：\(relayPause)"
    }
    /// The monitor only observes API settings. It never clears them without a manual account selection.
    /// True when Lilt must not write this pass: API mode, or a settings file that could not be read. Another tool
    /// writing the file in place can be caught halfway, so that waits for the next pass rather than stopping relay.
    @discardableResult private func checkAPIMode() async -> Bool {
        let runtime = self.runtime
        do { observeAPIMode(try await IOQueue.run { try runtime.hasAPIOverride() }); return apiModeDetected }
        catch { noteUnreadable(error); return true }
    }
    /// Runs `work` once no other scope sequence is running (see `scopeHeld`). Sequences already inside one call the
    /// parts they need directly, never this, so it is never waited for from inside itself.
    private func exclusively<T>(_ work: () async throws -> T) async rethrows -> T {
        if scopeHeld { await withCheckedContinuation { scopeWaiting.append($0) } } else { scopeHeld = true }
        defer { if scopeWaiting.isEmpty { scopeHeld = false } else { scopeWaiting.removeFirst().resume() } }
        return try await work()
    }
    private func noteUnreadable(_ error: Error) {
        if scopeUnreadableSince == nil { scopeUnreadableSince = .now; status = "暂时读不到\(scopeName)，稍后重试" }
        scopeUnreadable = (error as? LocalizedError)?.errorDescription ?? "读取失败，稍后重试。"
        if let since = scopeUnreadableSince, Date.now.timeIntervalSince(since) >= 120 {
            logFailure("scope-unreadable", scopeUnreadable)
        }
    }
    func observeAPIMode(_ detected: Bool) {
        guard detected != apiModeDetected else { return }
        apiModeDetected = detected
        if detected {
            relayPause = "检测到 API 配置；选择保留 API，或点击订阅账号切回。"
            relayRetryAt = nil; status = "检测到 API 模式，等待你的选择"
        } else {
            relayPause = keepsAPIMode ? "API 配置已移除；点击订阅账号恢复管理。" : nil
            status = "API 配置已移除"
        }
    }
    func keepAPI() {
        guard apiModeDetected, !busy else { return }
        setAutoRelay(false)
        updatePreferences { $0.keepAPIMode = true }
        status = "已保留 API 模式；点击任一订阅账号即可切回"
    }
    func requestAdd(_ kind: AuthKind = .oauth, replacing id: UUID? = nil) {
        guard canAdd else { return }
        if let id {
            guard let account = accounts.first(where: { $0.id == id }) else { return }
            // A long-lived token that cannot read quota is replaced by a browser login, not by another token.
            addRequest = AddRequest(replacing: id, kind: account.usageCapability == .unavailable ? .oauth : account.kind)
        } else { addRequest = AddRequest(kind: kind) }
    }
    func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&library.accounts[index]); save()
    }
    /// Manual moves only apply to the user's own order; while sorting is on the list is not theirs to arrange.
    func move(_ id: UUID, by offset: Int) {
        guard !busy, !autoSort, let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset; guard library.accounts.indices.contains(next) else { return }
        library.accounts.swapAt(index, next); save()
    }
    /// Drop semantics: the dragged account takes the target's place and the ones between shift by one.
    func move(_ id: UUID, to target: UUID) {
        guard !busy, !autoSort, id != target, let from = library.accounts.firstIndex(where: { $0.id == id }),
              let to = library.accounts.firstIndex(where: { $0.id == target }) else { return }
        let account = library.accounts.remove(at: from); library.accounts.insert(account, at: to); save()
    }
    func remove(_ id: UUID) {
        guard !busy else { return }
        guard library.activeID != id else { message = "此账号正在使用。请先切换到另一个账号，再删除本地记录。"; return }
        do {
            if !demo { try AccountVault.delete(account: id.uuidString) }
            if !demo { try? AccountVault.delete(account: Keychain.identityAccount(id)) }
            library.accounts.removeAll { $0.id == id }; backoffs[id] = nil; failures[id] = nil; save()
        } catch { message = "本地凭据未能删除。" }
    }
    /// Returns the reason when nothing was saved, so the sheet can show it in place.
    func addToken(label: String, token: String, replacing id: UUID? = nil) async -> String? {
        guard canAdd else { return "当前无法保存凭据。" }
        do {
            let credential = try Credential.manual(token)
            try store(credential, label: label, kind: .setupToken, replacing: id)
            status = "Token 已安全保存；能力待验证"
            await syncScope(afterReplacing: id)
            return nil
        } catch { return (error as? AppFailure)?.message ?? "无法保存凭据。" }
    }
    /// A new credential for the account in use belongs in the scope too; otherwise Lilt and the CLI would hold
    /// two different logins under one name without anyone being told.
    private func syncScope(afterReplacing id: UUID?) async {
        guard let id, id == library.activeID, !demo, library.preferences.scopeEnabled else { return }
        // Whatever the scope held for this account is superseded by what the user just saved.
        let runtime = self.runtime
        await exclusively { await IOQueue.perform { if (try? runtime.check()) == nil { try? runtime.rebaseline() } } }
        await apply(id)
    }
    /// True while `credential` is still what is stored for the account. An answer that arrives after the stored
    /// credential was replaced describes the old one and must not be recorded against the new one.
    private func isCurrent(_ credential: Credential, for id: UUID) async -> Bool {
        guard let stored = await IOQueue.perform({ (try? AccountVault.read(account: id.uuidString)) ?? nil }) else { return false }
        return OAuthDocument.accessToken(stored) == credential.token
    }
    /// The other account, if any, that is the same Claude account as this identity.
    private func twin(of identity: Data?, besides id: UUID?) -> Account? {
        guard let account = OAuthDocument.Identity(oauthAccount: identity).account else { return nil }
        return accounts.first { $0.id != id && OAuthDocument.Identity(oauthAccount: self.identity(for: $0.id)).account == account }
    }
    private func store(_ credential: Credential, label: String, kind: AuthKind, replacing id: UUID? = nil, identity: Data? = nil) throws {
        try credential.validate()
        if let id, !accounts.contains(where: { $0.id == id }) { throw AppFailure("要更新的账号已不存在，未保存任何凭据。") }
        // Without a server-verified stable identity, do not deduplicate by nickname or token.
        let accountID = id ?? UUID()
        try AccountVault.write(credential.data, account: accountID.uuidString)
        // Whose login this is, when the CLI recorded it. A credential without one must not inherit the previous owner's.
        if let identity { try AccountVault.write(identity, account: Keychain.identityAccount(accountID)) }
        else { try? AccountVault.delete(account: Keychain.identityAccount(accountID)) }
        if let id {
            update(id) { $0.kind = kind; $0.usageCapability = .unknown; $0.hotSwitchCapability = .unknown; $0.usage = nil; $0.expiresAt = credential.expiresAt; $0.issue = nil; $0.refreshRejected = nil }
            failures[id] = nil; backoffs[id] = nil
        } else {
            var account = Account(id: accountID, label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新账号 \(accounts.count + 1)" : label, kind: kind)
            account.expiresAt = credential.expiresAt
            library.accounts.append(account)
        }
        // A new login has to be on disk before the caller is told it was saved.
        saveNow()
        if !storageAvailable {
            if id == nil { try? AccountVault.delete(account: accountID.uuidString); library.accounts.removeAll { $0.id == accountID } }
            throw AppFailure("凭据保存后账号资料写入失败，请检查存储。")
        }
    }
    func browserLogin(label: String, replacing id: UUID? = nil) async -> String? {
        guard canAdd else { return "当前无法发起授权。" }
        let failure = await login(label: label, replacing: id)
        if failure == nil { await syncScope(afterReplacing: id) }
        return failure
    }
    private func login(label: String, replacing id: UUID?) async -> String? {
        busy = true; loggingIn = true; status = "请在浏览器完成官方授权"
        defer { busy = false; loggingIn = false }
        do {
            let (credential, recorded) = try await login.login()
            // Normally the CLI has written it down; if not, the profile endpoint says whose login this is.
            let identity = if let recorded { recorded } else { await IdentityClient().fetch(credential) }
            // The browser decides which account signs in. Two entries for one Claude account share one quota,
            // so relaying between them would achieve nothing.
            if let twin = twin(of: identity, besides: id) {
                status = "授权未保存"
                return "浏览器里登录的是和“\(twin.label)”同一个 Claude 账号，没有保存。先在浏览器里退出或换到另一个账号，再授权一次。"
            }
            try store(credential, label: label, kind: .oauth, replacing: id, identity: identity)
            status = "授权已保存"; return nil
        } catch { status = "授权未完成"; return (error as? AppFailure)?.message ?? "官方授权未完成。" }
    }
    /// Reads a stored secret, and the first time it still lives in the login keychain says so. That move can
    /// ask for the Mac password once; after the file exists, switching does not touch that item again.
    private func storedSecret(_ account: String) throws -> Data? {
        if !demo, !AccountVault.hasFile(account: account) {
            status = "正在把凭据从钥匙串移到本机，这一次之后切换不再询问密码"
        }
        return try AccountVault.read(account: account)
    }
    /// The stored login, read on the I/O queue.
    private func credential(for id: UUID) async throws -> Credential {
        if !demo, !AccountVault.hasFile(account: id.uuidString) { status = "正在把凭据从钥匙串移到本机，这一次之后切换不再询问密码" }
        let data: Data?
        do { data = try await IOQueue.run({ try AccountVault.read(account: id.uuidString) }) }
        catch let failure as ScopeUnreadable { throw failure }
        catch { throw ScopeUnreadable(AppFailure("本地凭据暂时读不出来，稍后自动重试。")) }
        guard let data else { throw AppFailure("没有找到这个账号的本地凭据，请重新授权。") }
        let result = Credential(data: data); try result.validate(); return result
    }
    private func identity(for id: UUID) -> Data? { (try? storedSecret(Keychain.identityAccount(id))) ?? nil }
    /// A stored full login, renewed first when it is about to expire. Never for the account in the scope: there the
    /// official CLI renews it and Lilt reads the result back, so the two cannot spend the same refresh token.
    /// The lead is `RelayPolicy.renewalLead` (ten minutes), twice Claude Code's own five-minute refresh buffer,
    /// so the token written into the scope is not already due for the CLI to refresh it again.
    private func renewedCredential(for id: UUID) async throws -> Credential {
        let renewal: Task<Credential, Error>
        if let running = renewals[id] { renewal = running } else {
            let stored = try await credential(for: id)
            guard !demo, id != library.activeID, stored.refreshable, stored.expires(within: RelayPolicy.renewalLead) else { return stored }
            if let running = renewals[id] { renewal = running } else {
                renewal = Task {
                    let fresh = try await TokenRenewer().renew(stored)
                    // Saved before anything else uses it: the old refresh token may already be spent.
                    try await IOQueue.run { try AccountVault.write(fresh.data, account: id.uuidString) }
                    return fresh
                }
                renewals[id] = renewal
            }
        }
        defer { if renewals[id] == renewal { renewals[id] = nil } }
        do {
            let fresh = try await renewal.value
            update(id) { $0.expiresAt = fresh.expiresAt; $0.refreshRejected = nil }
            return fresh
        } catch TokenRenewer.Failure.rejected {
            // A dead refresh token leaves automatic relay until the user authorizes again.
            // A later usage sample must not put it back. Network failures and 429 are not this error.
            update(id) { $0.refreshRejected = true }
            throw UsageFailure.authentication
        }
        catch is TokenRenewer.Failure { throw UsageFailure.network }
    }
    /// Compare the scope with what Lilt last wrote there. A renewal by the official CLI is taken in silently when it is
    /// provably the same login; anything else stops automatic work and waits for the user. True when the scope is in order.
    /// Only what was actually read can stop relay. A read that failed (the keychain stalls around sleep and wake) is
    /// tried again on the next pass; earlier versions took it for an outside change and switched relay off.
    @discardableResult
    func reconcileScope() async -> Bool {
        if scopeRetryAt > .now { return false }
        let settled = await exclusively { await reconcileScopeHeld() }
        if settled {
            scopeReadFailures = 0; scopeRetryAt = .distantPast
        } else if scopeUnreadable != nil {
            scopeReadFailures += 1
            let delay = scopeReadFailures < 2 ? 0 : min(60, 15 * pow(2, Double(min(scopeReadFailures - 2, 2))))
            scopeRetryAt = .now.addingTimeInterval(delay)
        }
        return settled
    }
    /// `reconcileScope` for a caller already running exclusively.
    private func reconcileScopeHeld() async -> Bool {
        guard !demo, library.preferences.scopeEnabled, let active else { return true }
        if await checkAPIMode() || keepsAPIMode { return false }
        let runtime = self.runtime
        do { try await IOQueue.run { try runtime.check() } }
        catch let failure as ScopeUnreadable { noteUnreadable(failure); return false }
        catch {
            guard let settled = await settleInterrupted() else { return false }
            if !settled {
                switch await readBack(into: active) {
                case .adopt, .unchanged: break
                case nil: return false // could not tell this time (no network, or the scope did not read); look again on the next pass
                case .unverifiable, .foreign:
                    stopRelay(because: "无法确认当前登录仍属于所选账号，请到“接入”检查并决定采纳还是改回。")
                    scopeIssue = (error as? AppFailure)?.message ?? "登录检查失败。"; status = "\(scopeName)被别处改了，管理已暂停"
                    return false
                }
            }
        }
        // Assigned only when something changes: every assignment redraws whatever reads it, even an equal value.
        if scopeIssue != nil || scopeUnreadable != nil || scopeUnreadableSince != nil { scopeIssue = nil; scopeUnreadable = nil; scopeUnreadableSince = nil }
        return true
    }
    /// A switch the selected storage left halfway leaves its journal pending. Once the scope reads again and holds,
    /// byte for byte, the login Lilt keeps for one of its accounts, the
    /// switch either never landed or landed on that account. Lilt wrote what is there either way, so it is settled
    /// without asking. Nil while the scope does not read; false when nothing is pending or the scope holds anything
    /// else, which the usual checks then look at.
    private func settleInterrupted() async -> Bool? {
        enum Outcome: Sendable { case settled(UUID), other, unreadable(ScopeUnreadable) }
        let runtime = self.runtime, ids = accounts.map(\.id), current = library.activeID
        let outcome: Outcome = await IOQueue.perform {
            guard runtime.transactionPending else { return .other }
            do {
                guard let held = try runtime.currentCredential() else { return .other }
                var matched: UUID?
                for id in ids where AccountVault.hasFile(account: id.uuidString) {
                    let saved = try AccountVault.read(account: id.uuidString)
                    if saved == held.data { matched = id; break }
                }
                guard let id = matched else { return .other }
                try runtime.settle()
                if id != current { try? runtime.writeIdentity((try? AccountVault.read(account: Keychain.identityAccount(id))) ?? nil) }
                return .settled(id)
            } catch let failure as ScopeUnreadable { return .unreadable(failure) }
            catch { return .unreadable(ScopeUnreadable(AppFailure("上次切换暂时无法收尾，稍后自动重试。"))) }
        }
        switch outcome {
        case .unreadable(let failure): noteUnreadable(failure); return nil
        case .other: return false
        case .settled(let id):
            SwitchLog.record("settled")
            // The reading that started the switch may start it again.
            latch = RelayLatch()
            guard id != library.activeID, let target = accounts.first(where: { $0.id == id }) else { status = "上次没切换成功，仍是原来的账号"; return true }
            departedID = library.activeID; departedAt = .now
            library.activeID = id; appliedPending = true; lastSwitchAt = .now; relayPause = nil; relayRetryAt = nil; save()
            if managesDefaultLogin, liveUsageEnabled { let label = target.label; await IOQueue.perform { StatusLineBridge.setLabel(label) } }
            status = "已切换到“\(target.label)”"
            return true
        }
    }
    /// What the scope holds relative to `account`'s stored login, taking it in when it is the same login renewed.
    /// The CLI's own note of who is logged in is checked first, as ORCA does; when that cannot settle it, the official
    /// profile endpoint is asked. Nil when the question could not be answered at all.
    private func readBack(into account: Account) async -> OAuthDocument.ReadBack? {
        enum Read: Sendable { case found(stored: Data, held: Credential, mine: Data?, theirs: Data?), unverifiable, unreadable(ScopeUnreadable) }
        let runtime = self.runtime, id = account.id
        // Everything needed from local files and the selected runtime storage, in one trip to the I/O queue.
        let read: Read = await IOQueue.perform {
            guard !runtime.transactionPending else { return .unverifiable }
            do {
                guard let stored = try AccountVault.read(account: id.uuidString) else { return .unverifiable }
                guard let held = try runtime.currentCredential(), (try? held.validate()) != nil else { return .unverifiable }
                let mine = try AccountVault.read(account: Keychain.identityAccount(id))
                return .found(stored: stored, held: held, mine: mine, theirs: runtime.readIdentity())
            } catch let failure as ScopeUnreadable { return .unreadable(failure) }
            catch { return .unreadable(ScopeUnreadable(AppFailure("本地登录资料暂时读不出来，稍后自动重试。"))) }
        }
        let stored: Data, found: Credential, mine: OAuthDocument.Identity, theirs: Data?
        switch read {
        case .unreadable(let failure): noteUnreadable(failure); return nil
        case .unverifiable: return .unverifiable
        case .found(let s, let h, let m, let t): stored = s; found = h; mine = .init(oauthAccount: m); theirs = t
        }
        var verdict = OAuthDocument.readBack(stored: stored, runtime: found.data, storedIdentity: mine,
                                             runtimeIdentity: .init(oauthAccount: theirs))
        if verdict == .unverifiable || verdict == .foreign, mine.account != nil, found.refreshable {
            // The config file can be stale; the server's answer for this very token cannot.
            guard let asked = await IdentityClient().fetch(found) else { return nil }
            verdict = OAuthDocument.readBack(stored: stored, runtime: found.data, storedIdentity: mine, runtimeIdentity: .init(oauthAccount: asked))
        }
        guard verdict == .adopt || verdict == .unchanged else { return verdict }
        let adopt = verdict == .adopt
        do {
            try await IOQueue.run {
                if adopt { try AccountVault.write(found.data, account: id.uuidString) }
                try runtime.rebaseline()
            }
            if verdict == .adopt {
                update(account.id) { $0.expiresAt = found.expiresAt; $0.issue = nil; $0.refreshRejected = nil }
                failures[account.id] = nil; backoffs[account.id] = nil; status = "已同步官方 CLI 续期的凭据"
            }
            return verdict
        } catch let failure as ScopeUnreadable {
            // What was taken in is already saved; the next pass finds it unchanged and records the baseline then.
            noteUnreadable(failure); return nil
        } catch {
            noteUnreadable(ScopeUnreadable(AppFailure("本地登录资料暂时无法保存，稍后自动重试。")))
            return nil
        }
    }
    static func wait(until date: Date, from now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        return seconds < 60 ? "约 \(Int(seconds.rounded(.up))) 秒" : "约 \(Int((seconds / 60).rounded(.up))) 分钟"
    }
    func refresh(_ id: UUID, manually: Bool = false) async {
        if demo { touchDemoSamples(); status = "已刷新演示数据"; return }
        if busy {
            if manually { status = "正在切换账号，完成后即可刷新" }
            return
        }
        if loading {
            if manually { status = "正在读取额度，请稍候" }
            return
        }
        if let until = usagePausedUntil, until > .now { status = "额度接口要求稍后再查，\(Self.wait(until: until))后继续"; return }
        if !manually, let next = backoffs[id]?.nextAttempt, next > .now {
            status = "接口退避中，\(Self.wait(until: next))后可重试"; return
        }
        loading = true
        defer { loading = false }
        // Requests stay a couple of seconds apart, even when several accounts are due at once.
        let gap = Date.now.timeIntervalSince(lastUsageRequest)
        if gap < 2 { try? await Task.sleep(for: .seconds(2 - gap)) }
        lastUsageRequest = .now
        var asked: Credential?
        do {
            let credential = try await renewedCredential(for: id)
            asked = credential
            let snapshot = try await usageFetch(credential)
            guard accounts.contains(where: { $0.id == id }), await isCurrent(credential, for: id) else { return }
            update(id) { $0.usage = snapshot; $0.usageCapability = .verified; $0.lastChecked = .now; $0.issue = nil }
            if id == library.activeID { notePace(snapshot, for: id) }
            if let backoff = backoffs[id], backoff.failures > 0 || backoff.nextAttempt != .distantPast { backoffs[id]?.succeed() }
            if failures[id] != nil { failures[id] = nil }
            if status != "额度已更新" { status = "额度已更新" }
            // Logins added before Lilt kept identities get theirs once, while the token is known to work.
            if credential.refreshable, !AccountVault.hasFile(account: Keychain.identityAccount(id)),
               let record = await IdentityClient().fetch(credential), await isCurrent(credential, for: id) {
                _ = try? await IOQueue.run { try AccountVault.write(record, account: Keychain.identityAccount(id)) }
            }
        } catch let failure as ScopeUnreadable {
            status = failure.message
        } catch let failure as AppFailure {
            status = failure.message
        } catch {
            // Likewise a failure: if the credential was replaced while the request was out, it says nothing about the new one.
            if let asked, await !isCurrent(asked, for: id) { return }
            let failure = error as? UsageFailure ?? .network
            backoffs[id, default: Backoff()].fail(failure, at: .now); failures[id] = failure
            if case .rateLimited(let seconds) = failure { usagePausedUntil = Date.now.addingTimeInterval(max(60, seconds)) }
            // Being told to wait, or a dropped connection, says nothing about the account: the last reading stays
            // on screen, as in ORCA, and nothing is flagged. Only an account with nothing to show says why.
            let passing: Bool
            switch failure { case .rateLimited, .network: passing = true; default: passing = false }
            let hasReading = accounts.first { $0.id == id }?.usage != nil
            update(id) { if !(passing && hasReading) { $0.issue = failure.message }; $0.lastChecked = .now; if failure == .permission { $0.usageCapability = .unavailable } }
            if case .rateLimited = failure, let until = usagePausedUntil { status = "额度接口要求稍后再查，\(Self.wait(until: until))后继续；先显示上次读数" }
            else { status = failure.message }
        }
    }
    /// A one-off pass the user asked for; never run on a timer.
    func refreshAll() async {
        if demo { touchDemoSamples(); status = "已刷新演示数据"; return }
        for account in accounts where account.enabled { await refresh(account.id, manually: true) }
    }
    /// The panel just opened or the window came forward: what is on screen should not be a minute old.
    func refreshIfStale() async {
        guard !demo, let active, backoffs[active.id]?.nextAttempt ?? .distantPast <= .now, (usagePausedUntil ?? .distantPast) <= .now,
              Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= 120 else { return }
        await refresh(active.id)
    }
    @discardableResult
    func apply(_ id: UUID, automatically: Bool = false) async -> Bool {
        // A quota read running in the background is no reason to hold up the user's own switch. Earlier versions waited
        // up to 30 seconds for it with nothing on screen; the two now share any renewal (`renewals`) and take turns at
        // the scope (`exclusively`), which is all the waiting was for.
        guard !busy, storageAvailable, let target = accounts.first(where: { $0.id == id }), target.enabled else { return false }
        if automatically, apiModeDetected || keepsAPIMode { return false }
        if !demo && !library.preferences.scopeEnabled { selectedPage = .scope; message = "请先接管 Claude Code 默认登录。"; return false }
        busy = true
        defer { busy = false }
        if !automatically, !demo { status = "正在切换到“\(target.label)”…" }
        do {
            if !demo {
                let credential: Credential
                // A network hiccup is no reason to refuse: the CLI can renew an expired login itself.
                do { credential = try await renewedCredential(for: id) } catch UsageFailure.network { credential = try await self.credential(for: id) }
                let runtime = self.runtime, leaving = active
                let wrote = try await exclusively { () async throws -> Bool in
                    if automatically {
                        // The CLI may have renewed the login in use while the other accounts were being read. Take that in
                        // right before writing. What cannot be settled now is left as it is for the next pass, which stops
                        // relay only when the scope provably holds something else.
                        guard await reconcileScopeHeld() else { return false }
                    } else if let leaving, leaving.id != id,
                              await IOQueue.perform({ (try? runtime.hasAPIOverride()) == false && (try? runtime.check()) == nil }) {
                        // Keep whatever the CLI renewed for the account being left; without this its stored login would go stale.
                        _ = await readBack(into: leaving)
                    }
                    // A failure here goes to the catch below, which keeps relay on whether or not anything was written.
                    try await IOQueue.run { try runtime.apply(credential, replacingExternalState: !automatically) }
                    await IOQueue.perform {
                        try? runtime.writeIdentity((try? AccountVault.read(account: Keychain.identityAccount(id))) ?? nil)
                    }
                    return true
                }
                guard wrote else { return false }
            }
            library.activeID = id; appliedPending = !demo; relayPause = nil; relayRetryAt = nil; scopeIssue = nil
            apiModeDetected = false; library.preferences.keepAPIMode = nil
            library.preferences.autoRelayStopReason = nil; save()
            if !demo {
                lastSwitchAt = .now
                SwitchLog.record(automatically ? "auto" : "manual")
                if managesDefaultLogin, liveUsageEnabled { let label = target.label; await IOQueue.perform { StatusLineBridge.setLabel(label) } }
                // Status line readings are matched to the account by when its windows reset, so the account just put in
                // place needs one current reading of its own.
                if !(target.usage?.isFresh(at: .now) ?? false) { Task { await self.refresh(id) } }
            }
            status = demo ? "演示账号已应用" : "已切换到“\(target.label)”"
            // The relay card records relays; a switch made by hand is not one.
            if demo { lastEvent = "演示：已接力至 \(target.label)" }
            return true
        } catch {
            let reason = Self.reason(error) ?? "凭据应用失败。"
            logFailure(automatically ? "auto-failed" : "manual-failed", reason)
            status = "切换未完成"
            // Relay stays on, as it does when a read fails. What stops a switch here passes by itself: the keychain not
            // answering for a while, another writer in the same moment, a renewal turned down for a moment. A switch
            // left halfway is finished or undone by the next scope check (`settleInterrupted`), and that check still
            // stops relay when the scope holds a login Lilt cannot account for. Earlier versions stopped relay here,
            // and it stayed off until the user came back.
            if automatically { waitForRelay(because: "没能换到“\(target.label)”：\(reason)稍后自动重试。", until: retryClock().addingTimeInterval(15)) }
            else { message = reason }
            return false
        }
    }
    /// Runs `work` up to three times, two seconds apart, while the scope does not read: the keychain stops answering
    /// for a while when many sessions use it, and a step the user asked for is better late than refused. Only for
    /// steps that can be repeated as they are.
    private static func patiently<T>(_ work: () async throws -> T) async throws -> T {
        for _ in 1..<3 {
            do { return try await work() } catch is ScopeUnreadable { try? await Task.sleep(for: .seconds(2)) }
        }
        return try await work()
    }
    /// Writes a failure to `switches.log`, once per kind and text in ten minutes: relay tries again every 15 seconds,
    /// and a failure that lasts would otherwise push the record of past switches out of the 200 lines kept.
    private func logFailure(_ kind: String, _ reason: String?) {
        let text = kind + (reason ?? "")
        if let last = lastFailureLogged, last.text == text, Date.now.timeIntervalSince(last.at) < 600 { return }
        lastFailureLogged = (text, .now)
        SwitchLog.record(kind, detail: reason)
    }
    /// The text an error of Lilt's own carries. Nil for anything else, whose description may name files and so is
    /// neither shown nor written to `switches.log`.
    private static func reason(_ error: Error) -> String? {
        switch error {
        case let failure as AppFailure: failure.message
        case let failure as ScopeUnreadable: failure.message
        case let failure as UsageFailure: failure.message
        default: nil
        }
    }
    /// The user's own check in the CLI. Lilt records it and does not present it as independent verification.
    func confirmApplied() {
        appliedPending = false
    }
    /// Take over Claude Code's default login, the way ORCA and CC Switch do: from now on a plain `claude` in any terminal
    /// uses the account selected here. Whatever is logged in now is kept as an account (or refreshes the entry that is
    /// the same Claude account), so nothing is lost and nothing is logged out.
    func takeOverDefaultLogin() async {
        guard !demo, !busy, storageAvailable else { return }
        let scope = fixtureRuntime ?? RuntimeScope(target: .system)
        let useFiles = runtimeFileStorage
        let wanted = library.activeID
        busy = true; status = "正在接管默认登录…"
        var adopted: UUID?
        do {
            try await exclusively {
                let current = try await Self.patiently {
                    try await IOQueue.run { () throws -> (Credential, Data?)? in
                        guard let found = try scope.currentCredential(), (try? found.validate()) != nil else { return nil }
                        return (found, scope.readIdentity())
                    }
                }
                if let (found, identity) = current {
                    let twin = twin(of: identity, besides: nil)
                    try store(found, label: "当前登录", kind: found.refreshable ? .oauth : .setupToken, replacing: twin?.id, identity: identity)
                    adopted = twin?.id ?? accounts.last?.id
                }
                try await Self.patiently { try await IOQueue.run {
                    if useFiles, current != nil { try scope.migrateCredentialStorage(toFile: true, replacingExternalState: true) }
                    else { try scope.rebaseline() }
                } }
            }
        } catch {
            busy = false; status = "接管未完成"
            let reason = Self.reason(error)
            logFailure("takeover-failed", reason)
            // The reason is shown: without it, a keychain that was not answering looked like something wrong for good.
            message = "无法接管默认登录。" + (reason.map { $0 + "默认登录没有改动，稍后再试。" } ?? "没有改动任何东西。"); return
        }
        updatePreferences { $0.scopeTarget = .system; $0.scopeEnabled = true }
        scopeIssue = nil; relayPause = nil; latch = RelayLatch(); appliedPending = false
        busy = false
        if liveUsageEnabled { connectStatusLine() }
        if let adopted {
            // What is logged in stays logged in; Lilt only starts keeping track of it.
            library.activeID = adopted; save()
            status = "已接管默认登录"
            await refresh(adopted)
        } else if let wanted, accounts.contains(where: { $0.id == wanted && $0.enabled }) {
            library.activeID = nil
            if await apply(wanted) { status = "已接管默认登录" }
        } else {
            library.activeID = nil; save(); status = "已接管默认登录"
        }
    }
    func setRuntimeFileStorage(_ on: Bool) {
        guard !demo, !busy, storageAvailable, on != runtimeFileStorage else { return }
        guard library.preferences.scopeEnabled else {
            updatePreferences { $0.runtimeFileStorage = on }
            status = on ? "接管后将使用本地登录文件" : "接管后将使用 macOS 钥匙串"
            return
        }
        let runtime = self.runtime
        busy = true; status = on ? "正在把登录迁到本地文件…" : "正在把登录迁回钥匙串…"
        Task {
            do {
                try await exclusively { try await IOQueue.run { try runtime.migrateCredentialStorage(toFile: on) } }
                updatePreferences { $0.runtimeFileStorage = on }
                scopeIssue = nil; scopeUnreadable = nil; scopeUnreadableSince = nil
                status = on ? "已改用本地登录文件" : "已改用 macOS 钥匙串"
            } catch {
                status = "登录存储方式未改变"
                message = Self.reason(error) ?? "登录存储迁移未完成，请稍后重试。"
            }
            busy = false
        }
    }
    func setLiveUsage(_ on: Bool) {
        guard !demo else { return }
        updatePreferences { $0.liveUsage = on }
        guard managesDefaultLogin else { return }
        if on { connectStatusLine() } else { disconnectStatusLine() }
    }
    private func connectStatusLine() {
        do { try StatusLineBridge.install(); statusLineIssue = nil; StatusLineBridge.setLabel(active?.label) }
        catch { statusLineIssue = (error as? AppFailure)?.message ?? "状态栏没有接上。" }
        lastStatusLineCheck = .now
    }
    private func disconnectStatusLine() {
        do { try StatusLineBridge.uninstall(); statusLineIssue = nil }
        catch { statusLineIssue = (error as? AppFailure)?.message ?? "原来的状态栏没能放回去。" }
    }
    /// Another tool (ORCA reinstalls its own) may put a different status line back. Lilt takes its place again at most
    /// every ten minutes, so the two never trade places in a loop.
    private func checkStatusLine() async {
        guard managesDefaultLogin, liveUsageEnabled, Date.now.timeIntervalSince(lastStatusLineCheck) >= 300 else { return }
        lastStatusLineCheck = .now
        guard !(await IOQueue.perform { StatusLineBridge.isInstalled }) else { statusLineIssue = nil; return }
        guard Date.now.timeIntervalSince(lastStatusLineRepair) >= 600 else {
            statusLineIssue = "状态栏被别的工具换掉了，Lilt 稍后再接上；在这之前按时查询额度。"; return
        }
        lastStatusLineRepair = .now
        connectStatusLine()
    }
    /// The latest reading a Claude Code session handed its status line, if it is about the account in use.
    private func ingestLiveUsage() async {
        guard !demo, managesDefaultLogin, liveUsageEnabled, let live = await IOQueue.perform({ StatusLineBridge.latest() }) else { return }
        if liveUsageSampledAt != live.sampledAt { liveUsageSampledAt = live.sampledAt }
        guard let active, live.sampledAt != liveStamp else { return }
        liveStamp = live.sampledAt
        let now = Date.now
        // A session that has not picked the new login up yet still reports the previous account; its readings are
        // older than the switch, or its windows reset at other times than this account's.
        guard live.sampledAt > lastSwitchAt, now.timeIntervalSince(live.sampledAt) < 600,
              let known = active.usage, live.sampledAt > known.sampledAt, live.sharesWindows(with: known, at: now) else { return }
        // An idle session reports what it saw at its own last request; a lower figure than Lilt has is older, not news.
        let reading = live.keepingHigher(than: known)
        update(active.id) { $0.usage = reading; $0.usageCapability = .verified; $0.issue = nil }
        if failures[active.id] != nil { failures[active.id] = nil }
        notePace(reading, for: active.id)
        // A session reporting this account's quota after the switch is using the new login, so the note that Lilt cannot
        // see whether sessions followed has nothing left to say. Sessions still on the previous account are not counted.
        if appliedPending { appliedPending = false }
    }
    private func notePace(_ reading: UsageSnapshot, for id: UUID) {
        if paceAccount != id { paceAccount = id; paceReadings = [] }
        paceReadings.removeAll { $0.sampledAt >= reading.sampledAt || reading.sampledAt.timeIntervalSince($0.sampledAt) > UsagePace.span }
        paceReadings.append(reading)
    }
    /// Stop managing the default login. It keeps whatever account is in it; nothing is logged out.
    func releaseDefaultLogin() {
        guard !demo, managesDefaultLogin else { return }
        let runtime = self.runtime
        setAutoRelay(false)
        updatePreferences { $0.scopeEnabled = false }
        scopeIssue = nil; appliedPending = false
        disconnectStatusLine()
        Task { await exclusively { await IOQueue.perform { runtime.removeSignal() } } }
        status = "Lilt 不再管理默认登录"
    }
    func startDemo() {
        // Not while a scope check is out on the I/O queue: it would come back to the demo's accounts.
        guard !busy, !loading, !scopeHeld, !demo else { return }
        savedLibrary = library; savedPending = appliedPending; demo = true; library = Library(); autoRelay = false; appliedPending = false; relayPause = nil
        savedAPIMode = apiModeDetected; apiModeDetected = false
        relayRetryAt = nil
        departedID = nil; departedAt = nil
        library.preferences = savedLibrary?.preferences ?? Preferences()
        library.preferences.keepAPIMode = nil
        for (i, name) in ["日常创作", "深度工作", "备用账号"].enumerated() {
            var account = Account(label: name, kind: i == 2 ? .setupToken : .oauth)
            account.usage = UsageSnapshot(fiveHour: UsageWindow(used: [28.0, 8, 56][i], resetsAt: .now.addingTimeInterval(7200)), sevenDay: UsageWindow(used: [46.0, 21, 62][i], resetsAt: .now.addingTimeInterval(259200)), source: "本地演示数据")
            account.usageCapability = .verified; account.hotSwitchCapability = .verified
            library.accounts.append(account)
        }
        library.activeID = library.accounts.first?.id; selectedPage = .overview; status = "演示模式 · 不读取或写入真实凭据"
    }
    func endDemo() {
        guard demo else { return }
        library = savedLibrary ?? Library(); savedLibrary = nil; demo = false; relayPause = nil; appliedPending = savedPending
        apiModeDetected = savedAPIMode
        departedID = nil; departedAt = nil
        relayRetryAt = nil; restoreRelayPreference()
        lastEvent = "尚无接力记录"; status = "已退出演示"; selectedPage = .overview
    }
    /// Demo samples stay current the way a live poll would keep them, so the walkthrough does not expire mid-read.
    private func touchDemoSamples() {
        guard demo else { return }
        for index in library.accounts.indices { library.accounts[index].usage?.sampledAt = .now; library.accounts[index].lastChecked = .now }
    }
    func simulateThreshold() async {
        guard demo, let id = active?.id else { return }
        touchDemoSamples()
        let used = 100 - thresholds.fiveHour // read before `update` takes exclusive access to the library
        update(id) {
            let old = $0.usage
            $0.usage = UsageSnapshot(fiveHour: UsageWindow(used: used, resetsAt: old?.fiveHour?.resetsAt), sevenDay: UsageWindow(used: old?.sevenDay?.used ?? 45, resetsAt: old?.sevenDay?.resetsAt), source: "本地演示数据")
        }
        if autoRelay { await relay() } else { status = "演示额度已到阈值，开启自动接力可查看结果" }
    }
    func relay() async {
        guard autoRelay, !busy, !loading, let active, let snapshot = active.usage else { return }
        guard storageAvailable, library.preferences.scopeEnabled || demo, scopeIssue == nil,
              !apiModeDetected, !keepsAPIMode else { return }
        // A status-line reading is already the session's own report, and the endpoint is not asked again
        // for five minutes. The hand-off has to be allowed to start from that reading for the whole five
        // minutes. An endpoint reading is only acted on while it is still the just-queried minute.
        let lifetime: TimeInterval = (!demo && snapshot.source == UsageParser.statusLineSource) ? 300 : 60
        let triggered = snapshot.exhausted(threshold: thresholds, at: .now, lifetime: lifetime)
        // At the pace the account is being spent it would pass the threshold before the next readings and the hand-off
        // are through, and a session that runs into the limit stops mid-task. Starting now keeps it running.
        let ahead = !demo && !triggered && paceAccount == active.id
            && UsagePace.nearing(snapshot, after: paceReadings, threshold: thresholds, at: .now, lifetime: lifetime)
        let due = triggered || ahead
        // The weekly preference may move before the threshold, but only off a fresh reading of the account in use.
        // Once a hand-off is due that preference stays out of the decision.
        let early = library.preferences.soonerWeekly == true && !due && snapshot.isFresh(at: .now)
        guard due || early else {
            if snapshot.available(threshold: thresholds, at: .now), relayPause != nil || relayRetryAt != nil { relayPause = nil; relayRetryAt = nil }
            return
        }
        // While the endpoint has asked Lilt to wait, the other accounts cannot be read; wait with it rather than
        // give up on relaying.
        if !demo, let until = usagePausedUntil, until > .now {
            if triggered { waitForRelay(because: "额度接口要求稍后再查，恢复后自动重试。", until: until) }
            return
        }
        if let relayRetryAt, relayRetryAt > retryClock() { return }
        let policy = relayPolicy(soonerWeekly: early)
        if !demo {
            if due {
                // The baton goes to the emptiest account, and that account is read right before unless it was read in
                // the last two minutes (`RelayPolicy.confirmLifetime`). When the reading shows less room than Lilt knew
                // of, the order changes and the account now in front is read instead, up to `handOffReads` of them.
                // An account whose read fails is passed over for this hand-off.
                var asked = Set<UUID>()
                while asked.count < RelayPolicy.handOffReads,
                      let next = policy.nextRead(relayCandidates(policy, besides: active.id), leaving: self.active, asked: asked, readable: readable, at: .now) {
                    asked.insert(next.id)
                    await refresh(next.id)
                    if let until = usagePausedUntil, until > .now { break }
                }
            } else if let activeReset = snapshot.sevenDay?.resetsAt, activeReset > .now {
                // Only a stored weekly reset that is already earlier can justify a read. Unknown resets stay out,
                // and a recent check is not repeated on the 15-second monitor.
                for candidate in relayCandidates(policy, besides: active.id) {
                    guard let reset = candidate.usage?.sevenDay?.resetsAt, reset > .now, reset < activeReset else { continue }
                    if policy.obstacle(for: candidate, at: .now) == nil { continue }
                    // Five minutes matches the ordinary relay watch, so opting in does not poll on every monitor tick.
                    if Date.now.timeIntervalSince(candidate.lastChecked ?? .distantPast) < 300 { continue }
                    await refresh(candidate.id)
                }
            }
            // The readings above took time; the user may have switched or turned relay off meanwhile.
            // A newer reading of the same account is a different event and is left for the next pass.
            guard autoRelay, self.active?.id == active.id, self.active?.usage?.sampledAt == snapshot.sampledAt else { return }
            // A candidate query can start a global backoff after the check above.
            if let until = usagePausedUntil, until > .now {
                if triggered { waitForRelay(because: "额度接口要求稍后再查，恢复后自动重试。", until: until) }
                return
            }
        }
        switch policy.decide(active: self.active, candidates: accounts, at: .now, holdActiveReading: !demo && triggered, ahead: ahead) {
        case .select(let id):
            // Claim only once a candidate is actually chosen. Claiming before the other accounts were
            // read used up the event whenever that reading took longer than the freshness window:
            // the decision then came back as "wait" and this exact sample could never trigger again.
            guard latch.claim(account: active.id, snapshot: snapshot) else { return }
            let name = accounts.first { $0.id == id }?.label ?? ""
            if await apply(id, automatically: true) {
                departedID = active.id; departedAt = .now
                if !demo { lastEvent = "已自动接力至 \(name)"; status = "已自动接力至 \(name)" }
            } else if autoRelay, demo || !runtime.transactionPending {
                // The hand-off never started, so this reading may try again on the next pass rather than wait for a new one.
                latch.release(account: active.id, snapshot: snapshot)
            }
        case .pause(let reason):
            // An early look that finds nobody must not stop relay: the account in use still has room.
            guard triggered else { break }
            let others = accounts.filter { $0.id != active.id }
            let blocked = others.compactMap { account in policy.obstacle(for: account, at: .now).map { (account.label, $0) } }
            // With many accounts, one line per account is a wall of text that mostly repeats one reason.
            let detail: String
            if blocked.isEmpty { detail = reason }
            else if blocked.count <= 3 { detail = blocked.map { "\($0.0)：\($0.1)" }.joined(separator: "；") }
            else {
                detail = Dictionary(grouping: blocked, by: \.1).sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
                    .map { "\($0.value.count) 个账号\($0.key)" }.joined(separator: "，")
            }
            // Try again when the first of them gets its quota back, rather than up to two minutes after it.
            let reset = policy.nextReset(of: others, at: .now)
            let wait = reset.map { min(120, max(5, $0.timeIntervalSinceNow + 5)) } ?? 120
            let next = reset.flatMap { Wording.resetAmount($0, now: .now) }.map { "最早 \($0)后有账号恢复，到时自动换上。" } ?? "保持开启，稍后自动重查。"
            let sentence = detail.hasSuffix("。") ? detail : detail + "。"
            waitForRelay(because: sentence + next, until: retryClock().addingTimeInterval(wait))
        case .wait: break
        }
    }
    /// Who may take over from the account in use, in relay order. A rejected refresh token stays out until the user
    /// authorizes again, and the account just left is not read in order to come back to it.
    private func relayCandidates(_ policy: RelayPolicy, besides activeID: UUID) -> [Account] {
        accounts.filter { $0.id != activeID && $0.enabled && $0.usageCapability != .unavailable && $0.refreshRejected != true && $0.id != policy.leftRecently }
    }
    private func relayPolicy(soonerWeekly: Bool = false) -> RelayPolicy {
        RelayPolicy(threshold: thresholds, allowUnverifiedHotSwitch: !demo,
                    leftRecently: RelayPolicy.coolingDown(departedID, since: departedAt, at: .now),
                    soonerWeekly: soonerWeekly)
    }
    /// The account is not in a backoff; asking now would only be refused.
    private func readable(_ id: UUID) -> Bool { (backoffs[id]?.nextAttempt ?? .distantPast) <= .now }
    /// A window of the account in use is within `RelayPolicy.preparationMargin` points of its threshold on its last reading.
    var nearThreshold: Bool {
        guard let usage = active?.usage else { return false }
        let t = thresholds
        return [(usage.fiveHour, t.fiveHour), (usage.sevenDay, t.sevenDay)].contains { window, limit in
            usage.lastKnownRemaining(window, at: .now).map { $0 <= limit + RelayPolicy.preparationMargin } ?? false
        }
    }
    /// A session has reported quota that the monitor has not taken in yet, and the account in use is close enough to
    /// the threshold that waiting for the next ordinary pass could carry it past.
    private func liveReadingWaiting() async -> Bool {
        guard autoRelay, !demo, !busy, !loading, managesDefaultLogin, liveUsageEnabled, scopeIssue == nil, scopeUnreadable == nil,
              nearThreshold else { return false }
        // Read beside the I/O queue rather than on it: a keychain call waiting there has nothing to do with this file.
        guard let sampled = await Task.detached(priority: .userInitiated, operation: { StatusLineBridge.latest()?.sampledAt }).value else { return false }
        return sampled != liveStamp
    }
    /// While the account in use is close to the threshold, read ahead the account a hand-off would go to first, so that
    /// what Lilt knows of it is at most five minutes old and the hand-off rarely finds it changed. When the read shows
    /// less room, the next pass reads whichever account is in front then. Passes come every few seconds near the
    /// threshold, so reads are at least 15 seconds apart.
    private func prepareHandOff() async {
        guard autoRelay, !demo, !busy, !loading, nearThreshold, let active, (usagePausedUntil ?? .distantPast) <= .now,
              (relayRetryAt ?? .distantPast) <= retryClock(), Date.now.timeIntervalSince(preparedAt) >= 15 else { return }
        let policy = relayPolicy()
        guard let next = policy.handOffOrder(relayCandidates(policy, besides: active.id), leaving: active, at: .now).first(where: { readable($0.id) }),
              Date.now.timeIntervalSince(next.usage?.sampledAt ?? .distantPast) >= 300 else { return }
        preparedAt = .now; await refresh(next.id)
    }
    /// Someone is likely reading or spending quota right now: a terminal or editor is frontmost, or Lilt itself is on screen.
    private var watching: Bool {
        if NSApp.isActive { return true }
        let foreground = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "").lowercased()
        return ["terminal", "iterm", "warp", "orca", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "vscode", "cursor", "zed"].contains { foreground.contains($0) }
    }
    private func tick() async {
        // Everything on screen that depends on time reads `clock`, and with sorting on so does the order of every
        // account, so each change redraws the whole window. Near the threshold passes come every 3 seconds; the
        // figures that depend on time change by the minute, so the clock moves at most every 15 seconds.
        if Date.now.timeIntervalSince(clock) >= 15 || Date.now < clock { clock = .now }
        guard !busy, !loading else { return }
        if demo { touchDemoSamples(); await relay(); return }
        // A pass woken early by a status line reading skips the scope check when one passed moments ago. Keychain checks
        // start a process, and an automatic hand-off checks the selected storage again before writing.
        if Date.now.timeIntervalSince(scopeCheckedAt) >= 10 {
            guard await reconcileScope() else { return }
            scopeCheckedAt = .now
        }
        await checkStatusLine()
        await ingestLiveUsage()
        guard let active else { return }
        // Readings from a working session arrive with every response; the endpoint is only asked when none has come
        // for five minutes (ORCA waits the same).
        if let usage = active.usage, usage.source == UsageParser.statusLineSource, Date.now.timeIntervalSince(usage.sampledAt) < 300 {
            await relay(); await prepareHandOff(); return
        }
        // ORCA asks every 15 minutes, and only while its window is in front. With relay on Lilt has to keep watching
        // in the background, but no faster than the endpoint puts up with: every 2 minutes when the account is close
        // to the threshold, every 5 while relay is on or a terminal is in front, every 15 otherwise.
        let interval: Double = autoRelay ? (nearThreshold ? 120 : 300) : (watching ? 300 : 900)
        if Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= interval { await refresh(active.id) }
        await relay()
        await prepareHandOff()
    }
    func notice(at now: Date = .now) -> Notice? {
        if !storageAvailable { return Notice(symbol: "externaldrive.badge.exclamationmark", text: "本地数据不可用，已停止写入", detail: "检查 ~/Library/Application Support/Lilt 的权限后重新打开 Lilt。", warning: true) }
        if apiModeDetected {
            return Notice(symbol: "arrow.triangle.branch", text: keepsAPIMode ? "已保留 API 模式" : "检测到 API 模式",
                          detail: "点击订阅账号会清除用户配置中的 API 覆盖项并应用所选登录。", warning: !keepsAPIMode)
        }
        if let scopeIssue {
            // The usual cause is harmless: the official CLI renewed the token of the account in use.
            guard let active else { return Notice(symbol: "exclamationmark.triangle", text: "\(scopeName)管理已暂停", detail: scopeIssue, warning: true, action: .openScope) }
            let cause = scopeTarget == .system ? "可能是 ORCA、/login 或别的工具换了账号。" : ""
            return Notice(symbol: "exclamationmark.triangle", text: "\(scopeName)被别处改了", detail: "\(cause)Lilt 没法确认它还是“\(active.label)”。在终端运行 claude 后用 /status 看是谁，再决定采纳还是改回。", warning: true, action: .adoptScope)
        }
        // A read can fail for a moment around sleep and wake; only one that lasts is worth a word.
        if library.preferences.scopeEnabled, let scopeUnreadable, let since = scopeUnreadableSince, now.timeIntervalSince(since) >= 120 {
            return Notice(symbol: "hourglass", text: "暂时读不到\(scopeName)", detail: "\(scopeUnreadable)Lilt 会继续重试\(autoRelay ? "，自动接力保持开启" : "")。", warning: true)
        }
        guard let active else {
            return accounts.isEmpty ? nil : Notice(symbol: "person.crop.circle.badge.questionmark", text: "尚未切换到任何账号", detail: "在账号列表里选择一个，点“切换”。")
        }
        if let issue = active.issue {
            var notice = Notice(symbol: "exclamationmark.circle", text: issue, warning: true)
            switch failures[active.id] {
            case .authentication: notice.action = .reauthorize(active.id)
            case .permission: notice.detail = Self.unreadableQuotaDetail(active.kind); notice.action = .reauthorize(active.id)
            case .accessExpired: notice.detail = "官方 CLI 下次请求时会自动续期，之后这里会提示采纳新凭据。"
            default:
                // After a relaunch the failure kind is gone but the capability it left behind is not.
                if active.usageCapability == .unavailable { notice.detail = Self.unreadableQuotaDetail(active.kind); notice.action = .reauthorize(active.id) }
                else if let next = backoffs[active.id]?.nextAttempt, next > now { notice.detail = "\(Self.wait(until: next, from: now))后自动重试。" }
                else { notice.action = .refresh(active.id) }
            }
            return notice
        }
        if let relayPause { return Notice(symbol: "pause.circle", text: autoRelay ? "自动接力等待中" : "自动接力已停止", detail: relayPause, warning: true, action: autoRelay ? .refreshAll : .openScope) }
        // Not a problem to fix: the switch is done on Lilt's side. What Lilt cannot see is whether a CLI that was
        // already running has picked the new login up, so it says so once and leaves it at that.
        if appliedPending { return Notice(symbol: "checkmark.circle", text: "已切换到“\(active.label)”", detail: scopeTarget == .system ? "新开的终端运行 claude 就是这个账号。已经在运行的会话有没有跟着换，Lilt 看不到；想确认就在里面运行 /status。" : "登录已写入 Lilt 作用域。正在运行的 CLI 有没有跟着换，Lilt 看不到；想确认就在 CLI 里运行 /status。", action: .confirmApplied) }
        // Readings are a few minutes apart by design; only one that has not been renewed for over half an hour is worth a word.
        if let usage = active.usage, now.timeIntervalSince(usage.sampledAt) > 1800 {
            let paused = (usagePausedUntil ?? .distantPast) > now
            return Notice(symbol: "clock", text: "额度是\(Wording.age(usage.sampledAt, now: now).replacingOccurrences(of: "更新", with: ""))的读数",
                          detail: paused ? "额度接口要求稍后再查，\(Self.wait(until: usagePausedUntil!, from: now))后自动继续。" : "接力前会重新读取。",
                          action: paused ? nil : .refresh(active.id))
        }
        return nil
    }
    static func unreadableQuotaDetail(_ kind: AuthKind) -> String {
        kind == .setupToken ? "长效 Token 只能发模型请求，官方额度接口不认它。改用浏览器登录后才能看额度、参与自动接力；模型请求本身不受影响。"
                            : "官方额度接口拒绝了这个凭据。重新用浏览器登录后再试。"
    }
    /// Whether the notice's button has to wait for work in progress. Dismissing a note or opening a page never does:
    /// the monitor reads quota in the background every few minutes, more often near the threshold, and those reads
    /// left the button greyed out while the notice stayed on screen.
    func blocks(_ action: Notice.Action) -> Bool {
        switch action {
        case .confirmApplied, .openScope, .refresh, .refreshAll: false
        case .reauthorize, .adoptScope: busy
        }
    }
    func perform(_ action: Notice.Action) {
        switch action {
        case .reauthorize(let id): requestAdd(replacing: id)
        case .refresh(let id): Task { await refresh(id, manually: true) }
        case .refreshAll: Task { await refreshAll() }
        case .openScope: selectedPage = .scope
        case .confirmApplied: confirmApplied()
        case .adoptScope: confirmingAdopt = true
        }
    }
    /// The user has confirmed the scope still belongs to the account in use: keep what the CLI left there as that
    /// account's credential (a renewed token replaces the old one for good) and resume managing the scope.
    func adoptScopeCredential() {
        guard !demo, !busy, let active else { return }
        let runtime = self.runtime, id = active.id, name = scopeName
        Task {
            do {
                let credential = try await exclusively {
                    try await IOQueue.run { () throws -> Credential in
                        guard let credential = try runtime.currentCredential() else { throw AppFailure("\(name)里没有可采纳的登录。") }
                        try credential.validate()
                        try AccountVault.write(credential.data, account: id.uuidString)
                        try runtime.rebaseline()
                        return credential
                    }
                }
                update(id) {
                    $0.expiresAt = credential.expiresAt; $0.issue = nil
                    // What was adopted decides what the account is: a login that can renew itself is a full login.
                    $0.kind = credential.refreshable ? .oauth : .setupToken; $0.usageCapability = .unknown
                }
                failures[id] = nil; backoffs[id] = nil
                scopeIssue = nil; status = "已采纳，继续管理\(name)"
                // Reading the quota also records whose login this is, so the next renewal can be taken in unasked.
                await refresh(id)
            } catch { message = (error as? AppFailure)?.message ?? "采纳失败，未改动任何凭据。" }
        }
    }
    /// The user says the scope should go back to the account Lilt put there, whatever is in it now.
    func reclaimScope() {
        guard !demo, !busy, let active else { return }
        Task { if await apply(active.id) { status = "已改回“\(active.label)”" } }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Lilt-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Fixed fields only: no nicknames, account IDs, paths, CLI output, or server error bodies.
        let text = "\(AppBuild.description)\nBuild: \(AppBuild.timestamp)\nSource: \(AppBuild.revision)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCLI: \(version)\nAccounts: \(accounts.count)\nScope enabled: \(library.preferences.scopeEnabled)\nScope target: \(scopeTarget.rawValue)\nRuntime storage: \(runtimeFileStorage ? "file" : "keychain")\nMode: \(demo ? "demo" : "live")\nNative Liquid Glass: enabled\nHot switch: NOT VALIDATED\nAutomatic live relay: available, hot switch not validated\nCache continuity: UNKNOWN\n"
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "已导出脱敏诊断" } catch { message = "诊断文件保存失败。" }
    }
}
