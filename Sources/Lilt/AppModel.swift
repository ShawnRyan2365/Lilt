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
    private(set) var relayPause: String?
    private(set) var apiModeDetected = false
    var keepsAPIMode: Bool { library.preferences.keepAPIMode == true }
    var displayedActiveID: UUID? { apiModeDetected || keepsAPIMode || scopeIssue != nil ? nil : library.activeID }
    private var relayRetryAt: Date?
    private let retryClock: () -> Date
    /// Where the selected account's login goes. Files from before there was a choice always meant Lilt's own directory;
    /// anything set up now takes over Claude Code's default login.
    var scopeTarget: ScopeTarget { library.preferences.scopeTarget ?? (library.preferences.scopeEnabled ? .dedicated : .system) }
    var runtime: RuntimeScope { RuntimeScope(target: scopeTarget) }
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
    private var liveStamp: Date?
    private var lastStatusLineCheck = Date.distantPast
    private var lastStatusLineRepair = Date.distantPast
    private var latch = RelayLatch()
    /// Who automatic relay just left, and when. `RelayPolicy.coolingDown` decides whether that still blocks them.
    private var departedID: UUID?
    private var departedAt: Date?
    private var monitor: Task<Void, Never>?
    private var usageClient = UsageClient()
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
        if storageAvailable, library.preferences.scopeEnabled { _ = checkAPIMode() }
        if storageAvailable, managesDefaultLogin, liveUsageEnabled, !apiModeDetected { connectStatusLine() }
        Task { version = await CLILogin.version() }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
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
    private func restoreRelayPreference() {
        autoRelay = library.preferences.autoRelay == true && relayBlocker == nil
        relayPause = library.preferences.autoRelay == true ? relayBlocker : library.preferences.autoRelayStopReason
    }
    var accounts: [Account] { library.accounts }
    var active: Account? { accounts.first { $0.id == library.activeID } }
    var enabledCount: Int { accounts.filter(\.enabled).count }
    var threshold: Double { library.preferences.threshold }
    /// Off unless the user turns it on. Nil in an older preferences file means off.
    var soonerWeekly: Bool { library.preferences.soonerWeekly == true }
    var canAdd: Bool { !demo && !busy && storageAvailable }
    var setupComplete: Bool { !accounts.isEmpty && library.preferences.scopeEnabled && active != nil }
    func save() {
        guard !demo else { return }
        persist(library)
    }
    private func persist(_ value: Library) {
        guard storageAvailable else { return }
        do { try Disk.save(value) } catch {
            autoRelay = false; storageAvailable = false
            relayPause = "本地数据保存失败，请检查存储后重新打开 Lilt。"
            lastEvent = relayPause!; message = "本地数据保存失败，自动接力已停止。"
        }
    }
    /// Preferences belong to the real library even while a demo is on screen, so a change made there still sticks.
    private func updatePreferences(_ change: (inout Preferences) -> Void) {
        change(&library.preferences)
        if demo, var real = savedLibrary { change(&real.preferences); savedLibrary = real; persist(real) } else { save() }
    }
    func setThreshold(_ value: Double) { updatePreferences { $0.threshold = min(20, max(0, value)) } }
    func setSoonerWeekly(_ on: Bool) { updatePreferences { $0.soonerWeekly = on } }
    func setShortcut(_ key: UInt32) { updatePreferences { $0.shortcutKey = key } }
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
    @discardableResult private func checkAPIMode() -> Bool {
        do { observeAPIMode(try runtime.hasAPIOverride()); return apiModeDetected }
        catch {
            scopeIssue = (error as? AppFailure)?.message ?? "无法读取 Claude 登录配置。"
            stopRelay(because: scopeIssue!)
            return true
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
    func move(_ id: UUID, by offset: Int) {
        guard !busy, let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset; guard library.accounts.indices.contains(next) else { return }
        library.accounts.swapAt(index, next); save()
    }
    /// Drop semantics: the dragged account takes the target's place and the ones between shift by one.
    func move(_ id: UUID, to target: UUID) {
        guard !busy, id != target, let from = library.accounts.firstIndex(where: { $0.id == id }),
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
        if (try? runtime.check()) == nil { try? runtime.rebaseline() }
        await apply(id)
    }
    /// True while `credential` is still what is stored for the account. An answer that arrives after the stored
    /// credential was replaced describes the old one and must not be recorded against the new one.
    private func isCurrent(_ credential: Credential, for id: UUID) -> Bool {
        guard let stored = (try? storedSecret(id.uuidString)) ?? nil else { return false }
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
            library.accounts.append(account); save()
        }
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
    private func credential(for id: UUID) throws -> Credential {
        guard let data = try storedSecret(id.uuidString) else { throw AppFailure("没有找到这个账号的本地凭据，请重新授权。") }
        let result = Credential(data: data); try result.validate(); return result
    }
    private func identity(for id: UUID) -> Data? { (try? storedSecret(Keychain.identityAccount(id))) ?? nil }
    /// A stored full login, renewed first when it is about to expire. Never for the account in the scope: there the
    /// official CLI renews it and Lilt reads the result back, so the two cannot spend the same refresh token.
    /// The lead is `RelayPolicy.renewalLead` (ten minutes), twice Claude Code's own five-minute refresh buffer,
    /// so the token written into the scope is not already due for the CLI to refresh it again.
    private func renewedCredential(for id: UUID) async throws -> Credential {
        let stored = try credential(for: id)
        guard !demo, id != library.activeID, stored.refreshable, stored.expires(within: RelayPolicy.renewalLead) else { return stored }
        do {
            let fresh = try await TokenRenewer().renew(stored)
            // Saved before anything else uses it: the old refresh token may already be spent.
            try AccountVault.write(fresh.data, account: id.uuidString)
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
    @discardableResult
    private func reconcileScope() async -> Bool {
        guard !demo, library.preferences.scopeEnabled, let active else { return true }
        if checkAPIMode() || keepsAPIMode { return false }
        do { try runtime.check(); scopeIssue = nil; return true }
        catch {
            switch await readBack(into: active) {
            case .adopt, .unchanged: scopeIssue = nil; return true
            case nil: return false // could not tell this time (no network); look again on the next pass
            case .unverifiable, .foreign:
                stopRelay(because: "无法确认当前登录仍属于所选账号，请到“接入”检查并决定采纳还是改回。")
                scopeIssue = (error as? AppFailure)?.message ?? "登录检查失败。"; status = "\(scopeName)被别处改了，管理已暂停"
                return false
            }
        }
    }
    /// What the scope holds relative to `account`'s stored login, taking it in when it is the same login renewed.
    /// The CLI's own note of who is logged in is checked first, as ORCA does; when that cannot settle it, the official
    /// profile endpoint is asked. Nil when the question could not be answered at all.
    private func readBack(into account: Account) async -> OAuthDocument.ReadBack? {
        guard !runtime.transactionPending,
              let stored = (try? storedSecret(account.id.uuidString)) ?? nil,
              let found = (try? runtime.currentCredential()) ?? nil, (try? found.validate()) != nil else { return .unverifiable }
        let mine = OAuthDocument.Identity(oauthAccount: identity(for: account.id))
        var verdict = OAuthDocument.readBack(stored: stored, runtime: found.data, storedIdentity: mine,
                                             runtimeIdentity: .init(oauthAccount: runtime.readIdentity()))
        if verdict == .unverifiable || verdict == .foreign, mine.account != nil, found.refreshable {
            // The config file can be stale; the server's answer for this very token cannot.
            guard let asked = await IdentityClient().fetch(found) else { return nil }
            verdict = OAuthDocument.readBack(stored: stored, runtime: found.data, storedIdentity: mine, runtimeIdentity: .init(oauthAccount: asked))
        }
        guard verdict == .adopt || verdict == .unchanged else { return verdict }
        do {
            if verdict == .adopt { try AccountVault.write(found.data, account: account.id.uuidString) }
            try runtime.rebaseline()
            if verdict == .adopt {
                update(account.id) { $0.expiresAt = found.expiresAt; $0.issue = nil; $0.refreshRejected = nil }
                failures[account.id] = nil; backoffs[account.id] = nil; status = "已同步官方 CLI 续期的凭据"
            }
            return verdict
        } catch { return .unverifiable }
    }
    static func wait(until date: Date, from now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        return seconds < 60 ? "约 \(Int(seconds.rounded(.up))) 秒" : "约 \(Int((seconds / 60).rounded(.up))) 分钟"
    }
    func refresh(_ id: UUID) async {
        guard !busy, !loading else { return }
        if demo { touchDemoSamples(); status = "已刷新演示数据"; return }
        if let until = usagePausedUntil, until > .now { status = "额度接口要求稍后再查，\(Self.wait(until: until))后继续"; return }
        if let next = backoffs[id]?.nextAttempt, next > .now { status = "接口退避中，\(Self.wait(until: next))后可重试"; return }
        loading = true
        defer { loading = false }
        // Requests stay a couple of seconds apart, even when several accounts are due at once.
        let gap = Date.now.timeIntervalSince(lastUsageRequest)
        if gap < 2 { try? await Task.sleep(for: .seconds(2 - gap)) }
        lastUsageRequest = .now
        var asked: Credential?
        do {
            // The account in the scope may have been renewed by the CLI since Lilt last looked.
            if id == library.activeID { await reconcileScope() }
            let credential = try await renewedCredential(for: id)
            asked = credential
            let snapshot = try await usageClient.fetch(credential)
            guard accounts.contains(where: { $0.id == id }), isCurrent(credential, for: id) else { return }
            update(id) { $0.usage = snapshot; $0.usageCapability = .verified; $0.lastChecked = .now; $0.issue = nil }
            backoffs[id, default: Backoff()].succeed(); failures[id] = nil; status = "额度已更新"
            // Logins added before Lilt kept identities get theirs once, while the token is known to work.
            if identity(for: id) == nil, credential.refreshable, let record = await IdentityClient().fetch(credential), isCurrent(credential, for: id) {
                try? AccountVault.write(record, account: Keychain.identityAccount(id))
            }
        } catch {
            // Likewise a failure: if the credential was replaced while the request was out, it says nothing about the new one.
            if let asked, !isCurrent(asked, for: id) { return }
            let failure = error as? UsageFailure ?? .authentication
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
        for account in accounts where account.enabled { await refresh(account.id) }
    }
    /// The panel just opened or the window came forward: what is on screen should not be a minute old.
    func refreshIfStale() async {
        guard !demo, let active, backoffs[active.id]?.nextAttempt ?? .distantPast <= .now, (usagePausedUntil ?? .distantPast) <= .now,
              Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= 120 else { return }
        await refresh(active.id)
    }
    @discardableResult
    func apply(_ id: UUID, automatically: Bool = false) async -> Bool {
        guard !busy, !loading, storageAvailable, let target = accounts.first(where: { $0.id == id }), target.enabled else { return false }
        if automatically, apiModeDetected || keepsAPIMode { return false }
        if !demo && !library.preferences.scopeEnabled { selectedPage = .scope; message = "请先接管 Claude Code 默认登录。"; return false }
        busy = true
        defer { busy = false }
        do {
            if !demo {
                // Keep whatever the CLI renewed for the account being left; without this its stored login would go stale.
                if (try? runtime.hasAPIOverride()) == false, (try? runtime.check()) == nil,
                   let leaving = active, leaving.id != id { _ = await readBack(into: leaving) }
                let credential: Credential
                // A network hiccup is no reason to refuse: the CLI can renew an expired login itself.
                do { credential = try await renewedCredential(for: id) } catch UsageFailure.network { credential = try self.credential(for: id) }
                try runtime.apply(credential, replacingExternalState: !automatically)
                try? runtime.writeIdentity(identity(for: id))
            }
            library.activeID = id; appliedPending = !demo; relayPause = nil; relayRetryAt = nil; scopeIssue = nil
            apiModeDetected = false; library.preferences.keepAPIMode = nil
            library.preferences.autoRelayStopReason = nil; save()
            if !demo {
                lastSwitchAt = .now
                if managesDefaultLogin, liveUsageEnabled { StatusLineBridge.setLabel(target.label) }
                // Status line readings are matched to the account by when its windows reset, so the account just put in
                // place needs one current reading of its own.
                if !(target.usage?.isFresh(at: .now) ?? false) { Task { await self.refresh(id) } }
            }
            status = demo ? "演示账号已应用" : "已切换到“\(target.label)”"
            // The relay card records relays; a switch made by hand is not one.
            if demo { lastEvent = "演示：已接力至 \(target.label)" }
            return true
        } catch {
            let wasRelaying = autoRelay
            stopRelay(because: "凭据切换未完成，请检查登录和存储状态后重新开启。"); status = "切换未完成"
            message = ((error as? AppFailure)?.message ?? (error as? UsageFailure)?.message ?? "凭据应用失败。") + (wasRelaying ? " 自动接力已关闭。" : "")
            return false
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
        let scope = RuntimeScope(target: .system)
        let wanted = library.activeID
        busy = true
        var adopted: UUID?
        do {
            if let found = try scope.currentCredential(), (try? found.validate()) != nil {
                let identity = scope.readIdentity()
                let twin = twin(of: identity, besides: nil)
                try store(found, label: "当前登录", kind: found.refreshable ? .oauth : .setupToken, replacing: twin?.id, identity: identity)
                adopted = twin?.id ?? accounts.last?.id
            }
            try scope.rebaseline()
        } catch {
            busy = false
            message = (error as? AppFailure)?.message ?? "无法接管默认登录，没有改动任何东西。"; return
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
    private func checkStatusLine() {
        guard managesDefaultLogin, liveUsageEnabled, Date.now.timeIntervalSince(lastStatusLineCheck) >= 300 else { return }
        lastStatusLineCheck = .now
        guard !StatusLineBridge.isInstalled else { statusLineIssue = nil; return }
        guard Date.now.timeIntervalSince(lastStatusLineRepair) >= 600 else {
            statusLineIssue = "状态栏被别的工具换掉了，Lilt 稍后再接上；在这之前按时查询额度。"; return
        }
        lastStatusLineRepair = .now
        connectStatusLine()
    }
    /// The latest reading a Claude Code session handed its status line, if it is about the account in use.
    private func ingestLiveUsage() {
        guard !demo, managesDefaultLogin, liveUsageEnabled, let active,
              let live = StatusLineBridge.latest(), live.sampledAt != liveStamp else { return }
        liveStamp = live.sampledAt
        let now = Date.now
        // A session that has not picked the new login up yet still reports the previous account; its readings are
        // older than the switch, or its windows reset at other times than this account's.
        guard live.sampledAt > lastSwitchAt, now.timeIntervalSince(live.sampledAt) < 600,
              let known = active.usage, live.sampledAt > known.sampledAt, live.sharesWindows(with: known, at: now) else { return }
        update(active.id) { $0.usage = live; $0.usageCapability = .verified; $0.issue = nil }
        failures[active.id] = nil
    }
    /// When the last status line reading arrived, for the 接入 page.
    var liveUsageSampledAt: Date? { StatusLineBridge.latest()?.sampledAt }
    /// Stop managing the default login. It keeps whatever account is in it; nothing is logged out.
    func releaseDefaultLogin() {
        guard !demo, managesDefaultLogin else { return }
        setAutoRelay(false)
        updatePreferences { $0.scopeEnabled = false }
        scopeIssue = nil; appliedPending = false
        disconnectStatusLine()
        status = "Lilt 不再管理默认登录"
    }
    func startDemo() {
        guard !busy, !loading, !demo else { return }
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
        let used = 100 - threshold // read before `update` takes exclusive access to the library
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
        let triggered = snapshot.exhausted(threshold: threshold, at: .now, lifetime: lifetime)
        // The weekly preference may move before the threshold, but only off a fresh reading of the account in use.
        // Once the threshold is reached that preference stays out of the decision.
        let early = library.preferences.soonerWeekly == true && !triggered && snapshot.isFresh(at: .now)
        guard triggered || early else {
            if snapshot.available(threshold: threshold, at: .now) { relayPause = nil; relayRetryAt = nil }
            return
        }
        // While the endpoint has asked Lilt to wait, the other accounts cannot be read; wait with it rather than
        // give up on relaying.
        if !demo, let until = usagePausedUntil, until > .now {
            if triggered { waitForRelay(because: "额度接口要求稍后再查，恢复后自动重试。", until: until) }
            return
        }
        if let relayRetryAt, relayRetryAt > retryClock() { return }
        let policy = RelayPolicy(
            threshold: threshold,
            allowUnverifiedHotSwitch: !demo,
            leftRecently: RelayPolicy.coolingDown(departedID, since: departedAt, at: .now),
            soonerWeekly: early
        )
        if !demo {
            if triggered {
                // Other accounts are read only now, when a hand-off is due: in priority order, and only until one qualifies.
                // A rejected refresh token is not asked again, and the account just left is not read in order to come back.
                for candidate in accounts where candidate.id != active.id && candidate.enabled && candidate.usageCapability != .unavailable {
                    if candidate.refreshRejected == true || candidate.id == policy.leftRecently { continue }
                    if policy.obstacle(for: candidate, at: .now) == nil { break }
                    await refresh(candidate.id)
                    if let fresh = accounts.first(where: { $0.id == candidate.id }), policy.obstacle(for: fresh, at: .now) == nil { break }
                }
            } else if let activeReset = snapshot.sevenDay?.resetsAt, activeReset > .now {
                // Only a stored weekly reset that is already earlier can justify a read. Unknown resets stay out,
                // and a recent check is not repeated on the 15-second monitor.
                for candidate in accounts where candidate.id != active.id && candidate.enabled && candidate.usageCapability != .unavailable {
                    if candidate.refreshRejected == true || candidate.id == policy.leftRecently { continue }
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
        switch policy.decide(active: self.active, candidates: accounts, at: .now, holdActiveReading: !demo && triggered) {
        case .select(let id):
            // Claim only once a candidate is actually chosen. Claiming before the other accounts were
            // read used up the event whenever that reading took longer than the freshness window:
            // the decision then came back as "wait" and this exact sample could never trigger again.
            guard latch.claim(account: active.id, snapshot: snapshot) else { return }
            let name = accounts.first { $0.id == id }?.label ?? ""
            if await apply(id, automatically: true) {
                departedID = active.id; departedAt = .now
                if !demo { lastEvent = "已自动接力至 \(name)"; status = "已自动接力至 \(name)" }
            }
        case .pause(let reason):
            // An early look that finds nobody must not stop relay: the account in use still has room.
            guard triggered else { break }
            let reasons = accounts.filter { $0.id != active.id }
                .compactMap { account in policy.obstacle(for: account, at: .now).map { "\(account.label)：\($0)" } }
            let detail = reasons.isEmpty ? reason : reasons.joined(separator: "；")
            waitForRelay(because: "\(detail) 保持开启，稍后自动重查。", until: retryClock().addingTimeInterval(120))
        case .wait: break
        }
    }
    /// Someone is likely reading or spending quota right now: a terminal or editor is frontmost, or Lilt itself is on screen.
    private var watching: Bool {
        if NSApp.isActive { return true }
        let foreground = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "").lowercased()
        return ["terminal", "iterm", "warp", "orca", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "vscode", "cursor", "zed"].contains { foreground.contains($0) }
    }
    private func tick() async {
        clock = .now
        guard !busy, !loading else { return }
        if demo { touchDemoSamples(); await relay(); return }
        guard await reconcileScope() else { return }
        checkStatusLine()
        ingestLiveUsage()
        guard let active else { return }
        // Readings from a working session arrive with every response; the endpoint is only asked when none has come
        // for five minutes (ORCA waits the same).
        if let usage = active.usage, usage.source == UsageParser.statusLineSource, Date.now.timeIntervalSince(usage.sampledAt) < 300 {
            await relay(); return
        }
        let remaining = [active.usage?.fiveHour, active.usage?.sevenDay].compactMap { active.usage?.lastKnownRemaining($0, at: .now) }.min()
        let low = remaining.map { $0 <= 10 } ?? false
        // ORCA asks every 15 minutes, and only while its window is in front. With relay on Lilt has to keep watching
        // in the background, but no faster than the endpoint puts up with: every 2 minutes when the account is nearly
        // out, every 5 while relay is on or a terminal is in front, every 15 otherwise.
        let interval: Double = autoRelay ? (low ? 120 : 300) : (watching ? 300 : 900)
        if Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= interval { await refresh(active.id) }
        await relay()
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
    func perform(_ action: Notice.Action) {
        switch action {
        case .reauthorize(let id): requestAdd(replacing: id)
        case .refresh(let id): Task { await refresh(id) }
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
        do {
            guard let credential = try runtime.currentCredential() else { throw AppFailure("\(scopeName)里没有可采纳的登录。") }
            try credential.validate()
            try AccountVault.write(credential.data, account: active.id.uuidString)
            try runtime.rebaseline()
            update(active.id) {
                $0.expiresAt = credential.expiresAt; $0.issue = nil
                // What was adopted decides what the account is: a login that can renew itself is a full login.
                $0.kind = credential.refreshable ? .oauth : .setupToken; $0.usageCapability = .unknown
            }
            failures[active.id] = nil; backoffs[active.id] = nil
            scopeIssue = nil; status = "已采纳，继续管理\(scopeName)"
            // Reading the quota also records whose login this is, so the next renewal can be taken in unasked.
            Task { await refresh(active.id) }
        } catch { message = (error as? AppFailure)?.message ?? "采纳失败，未改动任何凭据。" }
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
        let text = "\(AppBuild.description)\nBuild: \(AppBuild.timestamp)\nSource: \(AppBuild.revision)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCLI: \(version)\nAccounts: \(accounts.count)\nScope enabled: \(library.preferences.scopeEnabled)\nScope target: \(scopeTarget.rawValue)\nMode: \(demo ? "demo" : "live")\nNative Liquid Glass: enabled\nHot switch: NOT VALIDATED\nAutomatic live relay: available, hot switch not validated\nCache continuity: UNKNOWN\n"
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "已导出脱敏诊断" } catch { message = "诊断文件保存失败。" }
    }
}
