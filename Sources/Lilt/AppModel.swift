import SwiftUI
import Observation
import LiltCore

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
            case .openScope: "查看作用域"
            case .confirmApplied: "我已核对"
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
    let runtime = RuntimeScope()
    let login = CLILogin()
    private var savedLibrary: Library?
    private var savedPending = false
    private var backoffs: [UUID: Backoff] = [:]
    private var failures: [UUID: UsageFailure] = [:]
    private var latch = RelayLatch()
    private var monitor: Task<Void, Never>?
    private var usageClient = UsageClient()
    enum Page: String, CaseIterable { case overview = "概览", accounts = "账号", scope = "作用域", diagnostics = "诊断"
        var symbol: String { switch self { case .overview: "square.grid.2x2"; case .accounts: "person.2"; case .scope: "terminal"; case .diagnostics: "waveform.path.ecg" } }
    }
    init() {
        do { library = try Disk.load() } catch { storageAvailable = false; message = "账号资料无法读取，已停止写入。请先检查本地数据；不会以空列表覆盖。" }
        if storageAvailable {
            do { try CLILogin.cleanupStaleLogins() } catch { message = "上次授权的临时资料未能清理，请检查钥匙串与目录权限。" }
        }
        autoRelay = library.preferences.autoRelay == true && relayBlocker == nil
        Task { version = await CLILogin.version() }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                await self.tick()
            }
        }
    }
    var accounts: [Account] { library.accounts }
    var active: Account? { accounts.first { $0.id == library.activeID } }
    var enabledCount: Int { accounts.filter(\.enabled).count }
    var threshold: Double { library.preferences.threshold }
    var canAdd: Bool { !demo && !busy && storageAvailable }
    var setupComplete: Bool { !accounts.isEmpty && library.preferences.scopeEnabled && active != nil }
    func save() {
        guard !demo else { return }
        persist(library)
    }
    private func persist(_ value: Library) {
        guard storageAvailable else { return }
        do { try Disk.save(value) } catch { autoRelay = false; storageAvailable = false; message = "本地数据保存失败，自动接力已停止。" }
    }
    /// Preferences belong to the real library even while a demo is on screen, so a change made there still sticks.
    private func updatePreferences(_ change: (inout Preferences) -> Void) {
        change(&library.preferences)
        if demo, var real = savedLibrary { change(&real.preferences); savedLibrary = real; persist(real) } else { save() }
    }
    func setThreshold(_ value: Double) { updatePreferences { $0.threshold = min(20, max(0, value)) } }
    func setShortcut(_ key: UInt32) { updatePreferences { $0.shortcutKey = key } }
    /// What still stands between the user and live automatic relay, in a few words; nil when it can be turned on.
    /// The demo has no prerequisites.
    var relayBlocker: String? {
        guard !demo else { return nil }
        if !library.preferences.scopeEnabled { return "先启用 Lilt 作用域" }
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
        if on { relayPause = nil; latch = RelayLatch() }
        if !demo { updatePreferences { $0.autoRelay = on } }
    }
    /// Relay stopped itself. The saved switch goes off too, so a relaunch does not quietly resume it.
    private func stopRelay(because reason: String?) {
        autoRelay = false
        if let reason { relayPause = reason; status = "自动接力已暂停"; lastEvent = reason }
        if !demo, storageAvailable { updatePreferences { $0.autoRelay = false } }
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
        guard library.activeID != id else { message = "此账号仍应用于作用域。请先切换到另一个账号，再删除本地记录。"; return }
        do {
            if !demo { try Keychain.delete(account: id.uuidString) }
            if !demo { try? Keychain.delete(account: Keychain.identityAccount(id)) }
            library.accounts.removeAll { $0.id == id }; backoffs[id] = nil; failures[id] = nil; save()
        } catch { message = "本地凭据未能删除，请检查钥匙串。" }
    }
    /// Returns the reason when nothing was saved, so the sheet can show it in place.
    func addToken(label: String, token: String, replacing id: UUID? = nil) async -> String? {
        guard canAdd else { return "当前无法保存凭据。" }
        do {
            let credential = try Credential.manual(token)
            try store(credential, label: label, kind: .setupToken, replacing: id)
            status = "Token 已安全保存；能力待验证"
            return nil
        } catch { return (error as? AppFailure)?.message ?? "无法保存凭据。" }
    }
    private func store(_ credential: Credential, label: String, kind: AuthKind, replacing id: UUID? = nil, identity: Data? = nil) throws {
        try credential.validate()
        if let id, !accounts.contains(where: { $0.id == id }) { throw AppFailure("要更新的账号已不存在，未保存任何凭据。") }
        // Without a server-verified stable identity, do not deduplicate by nickname or token.
        let accountID = id ?? UUID()
        try Keychain.write(credential.data, account: accountID.uuidString)
        // Whose login this is, when the CLI recorded it. A credential without one must not inherit the previous owner's.
        if let identity { try Keychain.write(identity, account: Keychain.identityAccount(accountID)) }
        else { try? Keychain.delete(account: Keychain.identityAccount(accountID)) }
        if let id {
            update(id) { $0.kind = kind; $0.usageCapability = .unknown; $0.hotSwitchCapability = .unknown; $0.usage = nil; $0.expiresAt = credential.expiresAt; $0.issue = nil }
            failures[id] = nil; backoffs[id] = nil
        } else {
            var account = Account(id: accountID, label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新账号 \(accounts.count + 1)" : label, kind: kind)
            account.expiresAt = credential.expiresAt
            library.accounts.append(account); save()
        }
        if !storageAvailable {
            if id == nil { try? Keychain.delete(account: accountID.uuidString); library.accounts.removeAll { $0.id == accountID } }
            throw AppFailure("凭据保存后账号资料写入失败，请检查存储。")
        }
    }
    func browserLogin(label: String, replacing id: UUID? = nil) async -> String? {
        guard canAdd else { return "当前无法发起授权。" }
        busy = true; loggingIn = true; status = "请在浏览器完成官方授权"
        defer { busy = false; loggingIn = false }
        do {
            let (credential, recorded) = try await login.login()
            // Normally the CLI has written it down; if not, the profile endpoint says whose login this is.
            let identity = if let recorded { recorded } else { await IdentityClient().fetch(credential) }
            try store(credential, label: label, kind: .oauth, replacing: id, identity: identity)
            status = "授权已保存，等待能力验证"; return nil
        } catch { status = "授权未完成"; return (error as? AppFailure)?.message ?? "官方授权未完成。" }
    }
    private func credential(for id: UUID) throws -> Credential {
        guard let data = try Keychain.read(account: id.uuidString) else { throw AppFailure("钥匙串中未找到此账号，请重新授权。") }
        let result = Credential(data: data); try result.validate(); return result
    }
    private func identity(for id: UUID) -> Data? { (try? Keychain.read(account: Keychain.identityAccount(id))) ?? nil }
    /// A stored full login, renewed first when it is about to expire. Never for the account in the scope: there the
    /// official CLI renews it and Lilt reads the result back, so the two cannot spend the same refresh token.
    private func renewedCredential(for id: UUID) async throws -> Credential {
        let stored = try credential(for: id)
        guard !demo, id != library.activeID, stored.refreshable, stored.expires(within: 300) else { return stored }
        do {
            let fresh = try await TokenRenewer().renew(stored)
            // Saved before anything else uses it: the old refresh token may already be spent.
            try Keychain.write(fresh.data, account: id.uuidString)
            update(id) { $0.expiresAt = fresh.expiresAt }
            return fresh
        } catch TokenRenewer.Failure.rejected { throw UsageFailure.authentication }
        catch is TokenRenewer.Failure { throw UsageFailure.network }
    }
    /// Compare the scope with what Lilt last wrote there. A renewal by the official CLI is taken in silently when it is
    /// provably the same login; anything else stops automatic work and waits for the user. True when the scope is in order.
    @discardableResult
    private func reconcileScope() async -> Bool {
        guard !demo, library.preferences.scopeEnabled, let active else { return true }
        do { try runtime.check(); scopeIssue = nil; return true }
        catch {
            switch await readBack(into: active) {
            case .adopt, .unchanged: scopeIssue = nil; return true
            case nil: return false // could not tell this time (no network); look again on the next pass
            case .unverifiable, .foreign:
                stopRelay(because: nil)
                scopeIssue = (error as? AppFailure)?.message ?? "作用域检查失败。"; status = "作用域里的凭据变了，管理已暂停"
                return false
            }
        }
    }
    /// What the scope holds relative to `account`'s stored login, taking it in when it is the same login renewed.
    /// The CLI's own note of who is logged in is checked first, as ORCA does; when that cannot settle it, the official
    /// profile endpoint is asked. Nil when the question could not be answered at all.
    private func readBack(into account: Account) async -> OAuthDocument.ReadBack? {
        guard !runtime.transactionPending,
              let stored = (try? Keychain.read(account: account.id.uuidString)) ?? nil,
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
            if verdict == .adopt { try Keychain.write(found.data, account: account.id.uuidString) }
            try runtime.rebaseline()
            if verdict == .adopt {
                update(account.id) { $0.expiresAt = found.expiresAt; $0.issue = nil }
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
        if let next = backoffs[id]?.nextAttempt, next > .now { status = "接口退避中，\(Self.wait(until: next))后可重试"; return }
        loading = true
        defer { loading = false }
        do {
            // The account in the scope may have been renewed by the CLI since Lilt last looked.
            if id == library.activeID { await reconcileScope() }
            let credential = try await renewedCredential(for: id)
            let snapshot = try await usageClient.fetch(credential)
            guard accounts.contains(where: { $0.id == id }) else { return }
            update(id) { $0.usage = snapshot; $0.usageCapability = .verified; $0.lastChecked = .now; $0.issue = nil }
            backoffs[id, default: Backoff()].succeed(); failures[id] = nil; status = "额度已更新"
            // Logins added before Lilt kept identities get theirs once, while the token is known to work.
            if identity(for: id) == nil, credential.refreshable, let record = await IdentityClient().fetch(credential) {
                try? Keychain.write(record, account: Keychain.identityAccount(id))
            }
        } catch {
            let failure = error as? UsageFailure ?? .authentication
            backoffs[id, default: Backoff()].fail(failure, at: .now); failures[id] = failure
            update(id) { $0.issue = failure.message; $0.lastChecked = .now; if failure == .permission { $0.usageCapability = .unavailable } }
            status = failure.message
        }
    }
    /// A one-off pass the user asked for; never run on a timer.
    func refreshAll() async {
        if demo { touchDemoSamples(); status = "已刷新演示数据"; return }
        for account in accounts where account.enabled { await refresh(account.id) }
    }
    /// The panel just opened or the window came forward: what is on screen should not be a minute old.
    func refreshIfStale() async {
        guard !demo, let active, backoffs[active.id]?.nextAttempt ?? .distantPast <= .now,
              Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= 15 else { return }
        await refresh(active.id)
    }
    @discardableResult
    func apply(_ id: UUID) async -> Bool {
        guard !busy, !loading, let target = accounts.first(where: { $0.id == id }), target.enabled else { return false }
        if !demo && !library.preferences.scopeEnabled { selectedPage = .scope; message = "请先启用 Lilt 专属作用域，并查看影响范围。"; return false }
        busy = true
        defer { busy = false }
        do {
            if !demo {
                // Keep whatever the CLI renewed for the account being left; without this its stored login would go stale.
                if (try? runtime.check()) == nil, let leaving = active { _ = await readBack(into: leaving) }
                let credential: Credential
                // A network hiccup is no reason to refuse: the CLI can renew an expired login itself.
                do { credential = try await renewedCredential(for: id) } catch UsageFailure.network { credential = try self.credential(for: id) }
                try runtime.apply(credential)
                try? runtime.writeIdentity(identity(for: id))
            }
            library.activeID = id; appliedPending = !demo; relayPause = nil; scopeIssue = nil; save()
            status = demo ? "演示账号已应用" : "凭据已应用，等待请求身份验证"
            lastEvent = demo ? "演示：已接力至 \(target.label)" : "已应用本地凭据；未确认后续请求身份"
            return true
        } catch {
            let wasRelaying = autoRelay
            stopRelay(because: nil); status = "切换未完成"
            message = ((error as? AppFailure)?.message ?? (error as? UsageFailure)?.message ?? "凭据应用失败。") + (wasRelaying ? " 自动接力已关闭。" : "")
            return false
        }
    }
    /// The user's own check in the CLI. Lilt records it and does not present it as independent verification.
    func confirmApplied() {
        appliedPending = false; status = "已记录你的手动核对"
        lastEvent = "你已在 CLI 中手动核对账号；Lilt 未独立验证"
    }
    func enableScope() {
        guard !demo else { return }
        do { try runtime.check(); scopeIssue = nil; updatePreferences { $0.scopeEnabled = true }; status = "已启用 Lilt 专属作用域" }
        catch { message = (error as? AppFailure)?.message ?? "作用域检查失败。" }
    }
    func startDemo() {
        guard !busy, !loading, !demo else { return }
        savedLibrary = library; savedPending = appliedPending; demo = true; library = Library(); autoRelay = false; appliedPending = false; relayPause = nil
        library.preferences = savedLibrary?.preferences ?? Preferences()
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
        autoRelay = library.preferences.autoRelay == true && relayBlocker == nil
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
    private func relay() async {
        guard autoRelay, !busy, !loading, let active, let snapshot = active.usage,
              snapshot.exhausted(threshold: threshold, at: .now) else { return }
        guard latch.claim(account: active.id, snapshot: snapshot) else { return }
        let policy = RelayPolicy(threshold: threshold, allowUnverifiedHotSwitch: !demo)
        if !demo {
            // Other accounts are read only now, when a hand-off is due: in priority order, and only until one qualifies.
            for candidate in accounts where candidate.id != active.id && candidate.enabled && candidate.usageCapability != .unavailable {
                if policy.obstacle(for: candidate, at: .now) == nil { break }
                await refresh(candidate.id)
                if let fresh = accounts.first(where: { $0.id == candidate.id }), policy.obstacle(for: fresh, at: .now) == nil { break }
            }
            // The readings above took time; the user may have switched or turned relay off meanwhile.
            guard autoRelay, self.active?.id == active.id else { return }
        }
        switch policy.decide(active: self.active, candidates: accounts, at: .now) {
        case .select(let id):
            let name = accounts.first { $0.id == id }?.label ?? ""
            if await apply(id), !demo { lastEvent = "已自动接力至 \(name)；请求身份待核对"; status = "已自动接力至 \(name)" }
        case .pause(let reason):
            let reasons = accounts.filter { $0.id != active.id }
                .compactMap { account in policy.obstacle(for: account, at: .now).map { "\(account.label)：\($0)" } }
            stopRelay(because: reasons.isEmpty ? reason : reasons.joined(separator: "；"))
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
        guard let active else { return }
        let low = active.usage?.exhausted(threshold: 10, at: .now) ?? false
        // With relay on the user has asked to be watched, whatever app is in front.
        let interval: Double = (watching || autoRelay) ? (low ? 15 : 30) : 120
        if Date.now.timeIntervalSince(active.lastChecked ?? .distantPast) >= interval { await refresh(active.id) }
        await relay()
    }
    func notice(at now: Date = .now) -> Notice? {
        if !storageAvailable { return Notice(symbol: "externaldrive.badge.exclamationmark", text: "本地数据不可用，已停止写入", detail: "检查 ~/Library/Application Support/Lilt 的权限后重新打开 Lilt。", warning: true) }
        if let scopeIssue {
            // The usual cause is harmless: the official CLI renewed the token of the account in use.
            guard let active else { return Notice(symbol: "exclamationmark.triangle", text: "作用域管理已暂停", detail: scopeIssue, warning: true, action: .openScope) }
            return Notice(symbol: "exclamationmark.triangle", text: "作用域里的凭据变了", detail: "Lilt 没法确认它还属于“\(active.label)”。在 CLI 里用 /status 看一眼是谁，再决定采纳还是改回。", warning: true, action: .adoptScope)
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
        if let relayPause { return Notice(symbol: "pause.circle", text: "自动接力已暂停", detail: relayPause, warning: true, action: .refreshAll) }
        if appliedPending { return Notice(symbol: "hourglass", text: "凭据已应用，等待请求身份验证", detail: "在此作用域的 CLI 会话里运行 /status 核对账号；Lilt 目前无法自动确认。", action: .confirmApplied) }
        if let usage = active.usage, !usage.isFresh(at: now) { return Notice(symbol: "clock.badge.exclamationmark", text: "额度数据已过期", detail: "显示的是上次读数，不用于接力判断。", action: .refresh(active.id)) }
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
            guard let credential = try runtime.currentCredential() else { throw AppFailure("作用域里没有可采纳的凭据。") }
            try credential.validate()
            try Keychain.write(credential.data, account: active.id.uuidString)
            try runtime.rebaseline()
            update(active.id) { $0.expiresAt = credential.expiresAt; $0.issue = nil }
            failures[active.id] = nil; backoffs[active.id] = nil
            scopeIssue = nil; status = "已采纳，继续管理作用域"
            // Reading the quota also records whose login this is, so the next renewal can be taken in unasked.
            Task { await refresh(active.id) }
        } catch { message = (error as? AppFailure)?.message ?? "采纳失败，未改动任何凭据。" }
    }
    /// The user says the scope should go back to the account Lilt put there, whatever is in it now.
    func reclaimScope() {
        guard !demo, !busy, let active else { return }
        do { try runtime.rebaseline(); scopeIssue = nil } catch { message = (error as? AppFailure)?.message ?? "无法接管作用域。"; return }
        Task { if await apply(active.id) { status = "已改回“\(active.label)”" } }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Lilt-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Fixed fields only: no nicknames, account IDs, paths, CLI output, or server error bodies.
        let text = "Lilt 0.1.0\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCLI: \(version)\nAccounts: \(accounts.count)\nScope enabled: \(library.preferences.scopeEnabled)\nMode: \(demo ? "demo" : "live")\nNative Liquid Glass: enabled\nHot switch: NOT VALIDATED\nAutomatic live relay: available, hot switch not validated\nCache continuity: UNKNOWN\n"
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "已导出脱敏诊断" } catch { message = "诊断文件保存失败。" }
    }
}
