import Foundation
import LiltCore

public actor HeadlessEngine {
    public let store: BackendStore
    public let runtime: FileRuntimeScope
    private let usageClient: UsageFetching
    private let identityClient: IdentityFetching
    private let renewer: TokenRenewing
    private let now: () -> Date
    private let requestGap: TimeInterval
    private var library: Library
    private var backoffs: [UUID: Backoff] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var renewalTasks: [UUID: Task<Credential, Error>] = [:]
    private var usagePausedUntil: Date?
    private var lastUsageRequest = Date.distantPast
    private var latch = RelayLatch()
    private var departedID: UUID?
    private var departedAt: Date?
    private var paceReadings: [UsageSnapshot] = []
    private var paceAccount: UUID?
    private var liveStamp: Date?
    private var lastSwitchAt = Date.distantPast
    private var lastStatusLineCheck = Date.distantPast
    private var lastStatusLineRepair = Date.distantPast
    private var preparedAt = Date.distantPast
    private var relayRetryAt: Date?
    private var relayPause: String?
    private var scopeIssue: String?
    private var scopeUnreadable: String?
    private var scopeUnreadableSince: Date?
    private var scopeRetryAt = Date.distantPast
    private var scopeReadFailures = 0
    private var statusLineIssue: String?
    private var lastEvent: String?
    private var message: String?
    private var appliedPending = false
    private var apiModeDetected = false
    private var switching = false

    public init(store: BackendStore = BackendStore(), usageClient: UsageFetching = UsageClient(), identityClient: IdentityFetching = IdentityClient(), renewer: TokenRenewing = TokenRenewer(), now: @escaping @Sendable () -> Date = { Date.now }, requestGap: TimeInterval = 2) throws {
        self.store = store; runtime = FileRuntimeScope(store: store)
        self.usageClient = usageClient; self.identityClient = identityClient; self.renewer = renewer
        self.now = now; self.requestGap = requestGap
        library = try store.load()
        apiModeDetected = (try? runtime.hasAPIOverride()) == true
        if library.preferences.scopeEnabled, library.preferences.liveUsage != false {
            do { try LiveUsageBridge.install(store: store) } catch { statusLineIssue = backendReason(error) }
        }
    }

    public func snapshot() -> (Library, DaemonStatus) {
        let accounts = library.preferences.autoSort == true ? RelayOrder.sorted(library.accounts, at: now()) : library.accounts
        var copy = library; copy.accounts = accounts
        return (copy, DaemonStatus(message: message, relayPause: relayPause, relayRetryAt: relayRetryAt, scopeIssue: scopeIssue,
            scopeUnreadable: scopeUnreadable, statusLineIssue: statusLineIssue, lastEvent: lastEvent, appliedPending: appliedPending, apiModeDetected: apiModeDetected))
    }
    public func account(_ id: UUID) -> Account? { library.accounts.first { $0.id == id } }
    private func save() throws { try store.save(library) }
    private func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&library.accounts[index]); try? save()
    }
    public func setAuto(_ enabled: Bool) throws {
        library.preferences.autoRelay = enabled
        library.preferences.autoRelayStopReason = nil
        relayPause = nil; relayRetryAt = nil; message = enabled ? "自动接力已开启" : "自动接力已关闭"
        try save()
    }
    public func setThreshold(_ amount: Double, weekly: Bool) throws {
        guard (0...20).contains(amount) else { throw BackendFailure("阈值必须在 0–20% 之间。") }
        if weekly { library.preferences.weeklyThreshold = amount } else { library.preferences.threshold = amount }
        try save()
    }
    public func setStrategy(autoSort: Bool?, soonerWeekly: Bool?) throws {
        if autoSort == true { library.preferences.autoSort = true; library.preferences.soonerWeekly = false }
        else if soonerWeekly == true { library.preferences.soonerWeekly = true; library.preferences.autoSort = false }
        else {
            if let autoSort { library.preferences.autoSort = autoSort }
            if let soonerWeekly { library.preferences.soonerWeekly = soonerWeekly }
        }
        try save()
    }
    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard library.accounts.contains(where: { $0.id == id }) else { throw BackendFailure("找不到这个账号。") }
        update(id) { $0.enabled = enabled }
    }
    public func rename(_ label: String, id: UUID) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 100 else { throw BackendFailure("备注需为 1–100 个字符。") }
        update(id) { $0.label = label }
    }
    public func move(_ id: UUID, amount: Int) throws {
        guard library.preferences.autoSort != true, let from = library.accounts.firstIndex(where: { $0.id == id }) else { throw BackendFailure("自动排序开启时不能手动调整顺序。") }
        let to = max(0, min(library.accounts.count - 1, from + amount))
        guard from != to else { return }
        let account = library.accounts.remove(at: from); library.accounts.insert(account, at: to); try save()
    }
    public func remove(_ id: UUID) throws {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        if library.activeID == id { throw BackendFailure("当前账号仍在使用，请先切换到其他账号或停止接管。") }
        library.accounts.remove(at: index)
        try store.deleteSecret(id.uuidString); try store.deleteSecret(id.uuidString + ".identity")
        try save()
    }
    private func twin(_ identity: Data?, besides id: UUID? = nil) -> Account? {
        let wanted = OAuthDocument.Identity(oauthAccount: identity)
        guard !wanted.isEmpty else { return nil }
        for account in library.accounts where account.id != id {
            let other = OAuthDocument.Identity(oauthAccount: try? store.readSecret(account.id.uuidString + ".identity"))
            if let a = wanted.account, let b = other.account, a == b { return account }
            if let e = wanted.email, e == other.email, wanted.organization == other.organization { return account }
        }
        return nil
    }
    @discardableResult
    public func add(_ credential: Credential, identity: Data?, label: String, kind: AuthKind, replacing id: UUID? = nil) async throws -> UUID {
        try credential.validate()
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 100 else { throw BackendFailure("备注需为 1–100 个字符。") }
        if let duplicate = twin(identity, besides: id) { throw BackendFailure("这个 Claude 账号已经添加为“\(duplicate.label)”。") }
        let accountID = id ?? UUID()
        var account = id.flatMap({ old in library.accounts.first { $0.id == old } }) ?? Account(id: accountID, label: label, kind: kind)
        account.label = label; account.kind = kind; account.enabled = true; account.expiresAt = credential.expiresAt
        account.issue = nil; account.refreshRejected = nil; account.hotSwitchCapability = .unknown
        if kind == .setupToken { account.usageCapability = .unavailable; account.usage = nil }
        let wasCurrent = library.activeID == accountID
        try store.writeSecret(accountID.uuidString, data: credential.data)
        if let identity { try store.writeSecret(accountID.uuidString + ".identity", data: identity) }
        else { try? store.deleteSecret(accountID.uuidString + ".identity") }
        if let index = library.accounts.firstIndex(where: { $0.id == accountID }) { library.accounts[index] = account }
        else { library.accounts.append(account) }
        if library.activeID == nil, library.preferences.scopeEnabled { library.activeID = accountID }
        try save()
        if wasCurrent { _ = try await apply(accountID, automatically: false) }
        message = "已保存“\(label)”"
        return accountID
    }
    public func takeOver(label: String?) async throws -> UUID {
        if library.preferences.scopeEnabled, let active = library.activeID {
            try runtime.rebaseline(); return active
        }
        let current = try runtime.currentCredential()
        if current == nil {
            guard let account = active ?? library.accounts.first else { throw BackendFailure("默认登录和账号库都是空的；请先运行 `lilt login`。") }
            let previousActive = library.activeID
            library.activeID = account.id; library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
            do {
                try save(); try runtime.rebaseline(); _ = try await apply(account.id)
            } catch {
                library.activeID = previousActive; library.preferences.scopeEnabled = false; try? save()
                throw error
            }
        } else {
            let credential = current!; try credential.validate()
            let identity = runtime.readIdentity()
            let id: UUID
            if let existing = twin(identity) { id = existing.id }
            else { id = try await add(credential, identity: identity, label: label?.isEmpty == false ? label! : "当前账号", kind: credential.refreshable ? .oauth : .setupToken) }
            library.activeID = id; library.preferences.scopeEnabled = true; library.preferences.scopeTarget = .system
            try save(); try runtime.rebaseline()
        }
        if library.preferences.liveUsage != false {
            try LiveUsageBridge.install(store: store)
            try LiveUsageBridge.setLabel(store, active?.label)
        }
        message = "已接管 Claude Code 默认登录"
        return library.activeID!
    }
    public func release() throws {
        library.preferences.scopeEnabled = false; library.preferences.autoRelay = false
        try LiveUsageBridge.uninstall(store: store); try save()
        message = "Lilt 不再管理默认登录；当前登录保持不变"
    }
    public func keepAPI() throws {
        library.preferences.keepAPIMode = true; library.preferences.autoRelay = false
        try save(); apiModeDetected = false
    }
    public func installStatusLine(_ enabled: Bool) throws {
        library.preferences.liveUsage = enabled
        if enabled { try LiveUsageBridge.install(store: store) } else { try LiveUsageBridge.uninstall(store: store) }
        statusLineIssue = nil; try save()
    }
    private func credential(_ id: UUID) throws -> Credential {
        let data: Data?
        do { data = try store.readSecret(id.uuidString) }
        catch { throw ScopeUnreadable(BackendFailure("本地凭据暂时读不出来，稍后自动重试。")) }
        guard let data else { throw BackendFailure("没有找到这个账号的本地凭据，请重新授权。") }
        let credential = Credential(data: data); try credential.validate(); return credential
    }
    private func current(_ credential: Credential, id: UUID) -> Bool {
        (try? store.readSecret(id.uuidString)) == credential.data
    }
    private func renewed(_ id: UUID) async throws -> Credential {
        if let task = renewalTasks[id] { return try await task.value }
        let stored = try credential(id)
        guard id != library.activeID, stored.refreshable, stored.expires(within: RelayPolicy.renewalLead) else { return stored }
        let task = Task { try await renewer.renew(stored) }
        renewalTasks[id] = task
        defer { renewalTasks[id] = nil }
        do {
            let fresh = try await task.value
            do { try store.writeSecret(id.uuidString, data: fresh.data) }
            catch { throw ScopeUnreadable(BackendFailure("续期后的凭据暂时无法保存，稍后自动重试。")) }
            update(id) { $0.expiresAt = fresh.expiresAt; $0.refreshRejected = nil }
            return fresh
        } catch RenewalFailure.rejected {
            update(id) { $0.refreshRejected = true }
            throw UsageFailure.authentication
        } catch let failure as ScopeUnreadable { throw failure }
        catch { throw UsageFailure.network }
    }
    private func noteUnreadable(_ error: Error) {
        let text = (error as? ScopeUnreadable)?.message ?? backendReason(error)
        if scopeUnreadableSince == nil { scopeUnreadableSince = now() }
        scopeUnreadable = text; message = text
        if let since = scopeUnreadableSince, now().timeIntervalSince(since) >= 120 { store.log("scope-unreadable", detail: text) }
    }
    private func readBack(_ account: Account) async -> OAuthDocument.ReadBack? {
        do {
            guard !runtime.transactionPending, let stored = try store.readSecret(account.id.uuidString), let held = try runtime.currentCredential() else { return .unverifiable }
            guard (try? held.validate()) != nil else { return .unverifiable }
            let mine = try store.readSecret(account.id.uuidString + ".identity")
            var verdict = OAuthDocument.readBack(stored: stored, runtime: held.data, storedIdentity: .init(oauthAccount: mine), runtimeIdentity: .init(oauthAccount: runtime.readIdentity()))
            if verdict == .unverifiable || verdict == .foreign, mine != nil, held.refreshable {
                guard let asked = await identityClient.fetch(held) else { return nil }
                verdict = OAuthDocument.readBack(stored: stored, runtime: held.data, storedIdentity: .init(oauthAccount: mine), runtimeIdentity: .init(oauthAccount: asked))
            }
            guard verdict == .adopt || verdict == .unchanged else { return verdict }
            if verdict == .adopt {
                try store.writeSecret(account.id.uuidString, data: held.data)
                update(account.id) { $0.expiresAt = held.expiresAt; $0.issue = nil; $0.refreshRejected = nil }
            }
            try runtime.rebaseline()
            return verdict
        } catch let failure as ScopeUnreadable { noteUnreadable(failure); return nil }
        catch {
            noteUnreadable(ScopeUnreadable(BackendFailure("本地登录资料暂时无法读取或保存，稍后自动重试。")))
            return nil
        }
    }
    private func settleInterrupted() async -> Bool? {
        do {
            guard runtime.transactionPending else { return false }
            guard let held = try runtime.currentCredential() else { return false }
            for account in library.accounts where try store.readSecret(account.id.uuidString) == held.data {
                let identity = try store.readSecret(account.id.uuidString + ".identity")
                try runtime.settle(identity: identity)
                if account.id != library.activeID {
                    departedID = library.activeID; departedAt = now(); library.activeID = account.id
                    appliedPending = true; lastSwitchAt = now(); lastEvent = "已完成上次中断的切换"; try save()
                }
                store.log("settled"); latch = RelayLatch(); return true
            }
            return false
        } catch let failure as ScopeUnreadable { noteUnreadable(failure); return nil }
        catch {
            noteUnreadable(ScopeUnreadable(BackendFailure("上次切换暂时无法收尾，稍后自动重试。")))
            return nil
        }
    }
    @discardableResult
    private func reconcile() async -> Bool {
        if scopeRetryAt > now() { return false }
        let settled = await reconcileHeld()
        if settled {
            scopeReadFailures = 0; scopeRetryAt = .distantPast
        } else if scopeUnreadable != nil {
            scopeReadFailures += 1
            let delay = scopeReadFailures < 2 ? 0 : min(60, 15 * pow(2, Double(min(scopeReadFailures - 2, 2))))
            scopeRetryAt = now().addingTimeInterval(delay)
        }
        return settled
    }
    private func reconcileHeld() async -> Bool {
        guard library.preferences.scopeEnabled, let active = library.accounts.first(where: { $0.id == library.activeID }) else { return true }
        do { apiModeDetected = try runtime.hasAPIOverride() }
        catch let failure as ScopeUnreadable { noteUnreadable(failure); return false }
        catch { message = backendReason(error); return false }
        if apiModeDetected || library.preferences.keepAPIMode == true { return false }
        do { try runtime.check() }
        catch let failure as ScopeUnreadable { noteUnreadable(failure); return false }
        catch {
            guard let settled = await settleInterrupted() else { return false }
            if !settled {
                switch await readBack(active) {
                case .adopt, .unchanged: break
                case nil: return false
                case .unverifiable, .foreign:
                    let reason = "无法确认当前登录仍属于所选账号，请检查后决定采纳还是改回。"
                    library.preferences.autoRelayStopReason = reason; library.preferences.autoRelay = false; try? save()
                    scopeIssue = backendReason(error); message = reason; return false
                }
            }
        }
        scopeIssue = nil; scopeUnreadable = nil; scopeUnreadableSince = nil
        return true
    }
    public func adoptScope() async throws {
        guard let active = library.accounts.first(where: { $0.id == library.activeID }) else { throw BackendFailure("没有当前账号。") }
        let result = await readBack(active)
        guard result == .adopt || result == .unchanged else { throw BackendFailure("无法证明当前登录属于所选账号，未采纳。") }
        scopeIssue = nil; library.preferences.autoRelayStopReason = nil; try save()
    }
    public func reclaimScope() async throws {
        guard let active = library.activeID else { throw BackendFailure("没有当前账号。") }
        _ = try await apply(active, automatically: false); scopeIssue = nil
    }
    public func refresh(_ id: UUID, manually: Bool = false) async {
        if switching { if manually { message = "正在切换账号，完成后即可刷新" }; return }
        if let task = refreshTasks[id] {
            if manually { message = "正在读取额度，请稍候" }
            await task.value; return
        }
        let task = Task { await self.performRefresh(id, manually: manually) }
        refreshTasks[id] = task; await task.value; refreshTasks[id] = nil
    }
    private func performRefresh(_ id: UUID, manually: Bool) async {
        guard library.accounts.contains(where: { $0.id == id }) else { return }
        if let until = usagePausedUntil, until > now() { if manually { message = "额度接口要求稍后再查，请稍后再试。" }; return }
        if !manually, let next = backoffs[id]?.nextAttempt, next > now() { return }
        let gap = now().timeIntervalSince(lastUsageRequest)
        if gap < requestGap { try? await Task.sleep(for: .seconds(requestGap - gap)) }
        lastUsageRequest = now()
        var asked: Credential?
        do {
            let credential = try await renewed(id); asked = credential
            let snapshot = try await usageClient.fetch(credential)
            guard library.accounts.contains(where: { $0.id == id }), current(credential, id: id) else { return }
            update(id) { $0.usage = snapshot; $0.usageCapability = .verified; $0.lastChecked = self.now(); $0.issue = nil }
            if id == library.activeID { notePace(snapshot, id: id) }
            backoffs[id]?.succeed(); message = "额度已更新"
            if credential.refreshable, !(try store.readSecret(id.uuidString + ".identity") != nil),
               let record = await identityClient.fetch(credential), current(credential, id: id) {
                try store.writeSecret(id.uuidString + ".identity", data: record)
            }
        } catch let failure as ScopeUnreadable { message = failure.message }
        catch let failure as BackendFailure { message = failure.message }
        catch {
            if let asked, !current(asked, id: id) { return }
            let failure = error as? UsageFailure ?? .network
            backoffs[id, default: Backoff()].fail(failure, at: now())
            if case .rateLimited(let seconds) = failure { usagePausedUntil = now().addingTimeInterval(max(60, seconds)) }
            let passing = failure == .network || { if case .rateLimited = failure { true } else { false } }()
            let hasReading = library.accounts.first { $0.id == id }?.usage != nil
            update(id) { if !(passing && hasReading) { $0.issue = failure.message }; $0.lastChecked = self.now(); if failure == .permission { $0.usageCapability = .unavailable } }
        }
    }
    public func refreshAll() async { for account in library.accounts where account.enabled { await refresh(account.id, manually: true) } }
    private func notePace(_ reading: UsageSnapshot, id: UUID) {
        if paceAccount != id { paceAccount = id; paceReadings = [] }
        paceReadings.removeAll { $0.sampledAt >= reading.sampledAt || reading.sampledAt.timeIntervalSince($0.sampledAt) > UsagePace.span }
        paceReadings.append(reading)
    }
    @discardableResult
    public func apply(_ id: UUID, automatically: Bool = false) async throws -> Bool {
        guard !switching, let target = library.accounts.first(where: { $0.id == id }), target.enabled else { return false }
        if automatically, apiModeDetected || library.preferences.keepAPIMode == true { return false }
        guard library.preferences.scopeEnabled else { throw BackendFailure("请先接管 Claude Code 默认登录。") }
        switching = true; defer { switching = false }
        do {
            let credential: Credential
            do { credential = try await renewed(id) } catch UsageFailure.network { credential = try self.credential(id) }
            if automatically {
                guard await reconcile() else { return false }
            } else if let leaving = library.accounts.first(where: { $0.id == library.activeID }), leaving.id != id,
                      (try? runtime.hasAPIOverride()) == false, (try? runtime.check()) == nil {
                _ = await readBack(leaving)
            }
            let identity = try? store.readSecret(id.uuidString + ".identity")
            try runtime.apply(credential, identity: identity, replacingExternalState: !automatically)
            library.activeID = id; library.preferences.keepAPIMode = nil; library.preferences.autoRelayStopReason = nil
            apiModeDetected = false; appliedPending = true; relayPause = nil; relayRetryAt = nil; scopeIssue = nil
            lastSwitchAt = now(); try save(); store.log(automatically ? "auto" : "manual")
            if library.preferences.liveUsage != false { try? LiveUsageBridge.setLabel(store, target.label) }
            message = "已切换到“\(target.label)”"
            if !(target.usage?.isFresh(at: now()) ?? false) { Task { await self.refresh(id) } }
            return true
        } catch {
            let reason = backendReason(error); store.log(automatically ? "auto-failed" : "manual-failed", detail: reason)
            if automatically { relayPause = "切换未完成，15 秒后重试：\(reason)"; relayRetryAt = now().addingTimeInterval(15) }
            else { message = reason }
            throw error
        }
    }
    private var thresholds: Thresholds { library.preferences.thresholds }
    private var active: Account? { library.accounts.first { $0.id == library.activeID } }
    private func policy(soonerWeekly: Bool = false) -> RelayPolicy {
        RelayPolicy(threshold: thresholds, allowUnverifiedHotSwitch: true, leftRecently: RelayPolicy.coolingDown(departedID, since: departedAt, at: now()), soonerWeekly: soonerWeekly)
    }
    private var nearThreshold: Bool {
        guard let usage = active?.usage else { return false }
        return [(usage.fiveHour, thresholds.fiveHour), (usage.sevenDay, thresholds.sevenDay)].contains { window, limit in
            usage.lastKnownRemaining(window, at: now()).map { $0 <= limit + RelayPolicy.preparationMargin } ?? false
        }
    }
    public var monitorInterval: TimeInterval { nearThreshold ? 3 : 15 }
    private func checkStatusLine() {
        guard library.preferences.scopeEnabled, library.preferences.liveUsage != false, now().timeIntervalSince(lastStatusLineCheck) >= 300 else { return }
        lastStatusLineCheck = now()
        guard !LiveUsageBridge.isInstalled(store: store) else { statusLineIssue = nil; return }
        guard now().timeIntervalSince(lastStatusLineRepair) >= 600 else {
            statusLineIssue = "状态栏被其他工具替换，Lilt 稍后再接上；期间按时查询额度。"; return
        }
        do {
            try LiveUsageBridge.install(store: store)
            try LiveUsageBridge.setLabel(store, active?.label)
            lastStatusLineRepair = now(); statusLineIssue = nil
        } catch { statusLineIssue = backendReason(error) }
    }
    private func ingestLiveUsage() {
        guard library.preferences.scopeEnabled, library.preferences.liveUsage != false, let live = LiveUsageBridge.latest(store: store), live.sampledAt != liveStamp else { return }
        liveStamp = live.sampledAt
        guard let active, live.sampledAt > lastSwitchAt, now().timeIntervalSince(live.sampledAt) < 600,
              let known = active.usage, live.sampledAt > known.sampledAt, live.sharesWindows(with: known, at: now()) else { return }
        let reading = live.keepingHigher(than: known)
        update(active.id) { $0.usage = reading; $0.usageCapability = .verified; $0.issue = nil }
        notePace(reading, id: active.id); appliedPending = false
    }
    private func prepareHandOff() async {
        guard library.preferences.autoRelay == true, !switching, nearThreshold, (usagePausedUntil ?? .distantPast) <= now(),
              (relayRetryAt ?? .distantPast) <= now(), now().timeIntervalSince(preparedAt) >= 15 else { return }
        let policy = policy()
        let candidates = library.accounts.filter { $0.id != active?.id && $0.enabled && $0.usageCapability != .unavailable && $0.refreshRejected != true && $0.id != policy.leftRecently }
        guard let next = policy.handOffOrder(candidates, leaving: active, at: now()).first(where: { (backoffs[$0.id]?.nextAttempt ?? .distantPast) <= now() }),
              now().timeIntervalSince(next.usage?.sampledAt ?? .distantPast) >= 300 else { return }
        preparedAt = now(); await refresh(next.id)
    }
    private func relay() async {
        guard library.preferences.autoRelay == true, !switching, let active, let snapshot = active.usage,
              library.preferences.scopeEnabled, scopeIssue == nil, !apiModeDetected, library.preferences.keepAPIMode != true else { return }
        let lifetime: TimeInterval = snapshot.source == UsageParser.statusLineSource ? 300 : 60
        let triggered = snapshot.exhausted(threshold: thresholds, at: now(), lifetime: lifetime)
        let ahead = !triggered && paceAccount == active.id && UsagePace.nearing(snapshot, after: paceReadings, threshold: thresholds, at: now(), lifetime: lifetime)
        let due = triggered || ahead
        let early = library.preferences.soonerWeekly == true && !due && snapshot.isFresh(at: now())
        guard due || early else { if snapshot.available(threshold: thresholds, at: now()) { relayPause = nil; relayRetryAt = nil }; return }
        if let until = usagePausedUntil, until > now() { relayPause = "额度接口限流，恢复后自动重试。"; relayRetryAt = until; return }
        if let relayRetryAt, relayRetryAt > now() { return }
        let policy = policy(soonerWeekly: early)
        let candidates = library.accounts.filter { $0.id != active.id && $0.enabled && $0.usageCapability != .unavailable && $0.refreshRejected != true && $0.id != policy.leftRecently }
        if due {
            var asked = Set<UUID>()
            while asked.count < RelayPolicy.handOffReads,
                  let next = policy.nextRead(candidates, leaving: self.active, asked: asked, readable: { (backoffs[$0]?.nextAttempt ?? .distantPast) <= now() }, at: now()) {
                asked.insert(next.id); await refresh(next.id)
                if let until = usagePausedUntil, until > now() { break }
            }
        } else if let activeReset = snapshot.sevenDay?.resetsAt, activeReset > now() {
            for candidate in candidates {
                guard let reset = candidate.usage?.sevenDay?.resetsAt, reset > now(), reset < activeReset else { continue }
                if policy.obstacle(for: candidate, at: now()) == nil { continue }
                if now().timeIntervalSince(candidate.lastChecked ?? .distantPast) < 300 { continue }
                await refresh(candidate.id)
            }
        }
        guard library.preferences.autoRelay == true, self.active?.id == active.id, self.active?.usage?.sampledAt == snapshot.sampledAt else { return }
        if let until = usagePausedUntil, until > now() { relayPause = "额度接口限流，恢复后自动重试。"; relayRetryAt = until; return }
        switch policy.decide(active: self.active, candidates: library.accounts, at: now(), holdActiveReading: triggered, ahead: ahead) {
        case .select(let id):
            guard latch.claim(account: active.id, snapshot: snapshot) else { return }
            do {
                if try await apply(id, automatically: true) {
                    departedID = active.id; departedAt = now(); lastEvent = "已自动接力"; message = "已自动接力"
                } else if !runtime.transactionPending { latch.release(account: active.id, snapshot: snapshot) }
            } catch { if !runtime.transactionPending { latch.release(account: active.id, snapshot: snapshot) } }
        case .pause(let reason):
            guard triggered else { break }
            let reset = policy.nextReset(of: library.accounts.filter { $0.id != active.id }, at: now())
            let wait = reset.map { min(120, max(5, $0.timeIntervalSince(now()) + 5)) } ?? 120
            relayPause = reason + " 保持开启，稍后自动重查。"; relayRetryAt = now().addingTimeInterval(wait)
        case .wait: break
        }
    }
    public func tick() async {
        guard !switching else { return }
        guard await reconcile() else { return }
        checkStatusLine()
        ingestLiveUsage()
        guard let active else { return }
        if let usage = active.usage, usage.source == UsageParser.statusLineSource, now().timeIntervalSince(usage.sampledAt) < 300 {
            await relay(); await prepareHandOff(); return
        }
        let interval: TimeInterval = library.preferences.autoRelay == true ? (nearThreshold ? 120 : 300) : 900
        if now().timeIntervalSince(active.lastChecked ?? .distantPast) >= interval { await refresh(active.id) }
        await relay(); await prepareHandOff()
    }
}
