import Foundation
import LiltCore
import LiltTransfer

/// What an export or import did, in numbers only: no names, ids or secrets.
public struct TransferSummary: Codable, Sendable, Equatable {
    public var exported: Int
    public var added: Int
    public var skipped: Int
    public var conflicts: Int
    public init(exported: Int = 0, added: Int = 0, skipped: Int = 0, conflicts: Int = 0) {
        self.exported = exported; self.added = added; self.skipped = skipped; self.conflicts = conflicts
    }
}

public actor HeadlessEngine {
    public let store: BackendStore
    public let runtime: FileRuntimeScope
    private let usageClient: UsageFetching
    private let identityClient: IdentityFetching
    private let renewer: TokenRenewing
    private let now: () -> Date
    private let requestGap: TimeInterval
    private let spacing = RequestSpacing()
    private let projectStore: ProjectCatalogStore
    private var library: Library
    private var projects: ProjectCatalog
    private var backoffs: [UUID: Backoff] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var renewalTasks: [UUID: Task<Credential, Error>] = [:]
    private var tickTask: Task<Void, Never>?
    private var usageFailures: [UUID: UsageFailure] = [:]
    private var latch = RelayLatch()
    private var departedID: UUID?
    private var departedAt: Date?
    private var paceReadings: [UsageSnapshot] = []
    private var paceAccount: UUID?
    /// One automatic hand-off at a time, from trigger through the reads to the write. A newer reading that arrives
    /// meanwhile asks for another pass (`relayAgain`) instead of starting a second operation. Turning relay off, a
    /// switch by hand or another account taking over bumps `relayGeneration`, which ends the running one.
    private var relayRunning = false
    private var relayAgain = false
    private var relayGeneration = 0
    private var noCandidateFailures = 0
    /// How long the last hand-off took from trigger to written login (see `UsagePace.reactionTime`).
    private var reactionTime = UsagePace.lead
    /// What the last switch was seen to cost (see `UsagePace.switchAllowance`), and the reading it is measured from.
    private var switchAllowance: Thresholds = 0
    private var pendingJump: (account: UUID, confirmed: UsageSnapshot)?
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
    /// A session on the default login has reported quota of the account switched to. One session, not all of them.
    private var sessionConfirmed = false
    private var apiModeDetected = false
    private var switching = false
    /// Status line events went missing; the next pass asks the endpoint whatever the cadence says.
    private var forcePoll: Set<UUID> = []
    private var liveGap = false
    private var projectBusy: Set<UUID> = []
    private static let gapText = "部分状态栏额度事件丢失或无法解析；缺失部分按未知处理，已改为主动查询。"

    public init(store: BackendStore = BackendStore(), usageClient: UsageFetching = UsageClient(), identityClient: IdentityFetching = IdentityClient(), renewer: TokenRenewing = TokenRenewer(), now: @escaping @Sendable () -> Date = { Date.now }, requestGap: TimeInterval = 2) throws {
        self.store = store; runtime = FileRuntimeScope(store: store)
        self.usageClient = usageClient; self.identityClient = identityClient; self.renewer = renewer
        self.now = now; self.requestGap = requestGap
        try store.prepare()
        // An import a crash interrupted is finished or undone before the library is read.
        var recovery: String?
        do { try CredentialImport.recover(secrets: store.secretsDirectory, libraryFile: store.libraryFile) }
        catch { recovery = (error as? ImportFailure)?.message ?? "上次导入的现场无法自动收尾，请检查后再导入。" }
        library = try store.load()
        projectStore = ProjectCatalogStore(store: store)
        projects = try projectStore.load()
        message = recovery
        apiModeDetected = (try? runtime.hasAPIOverride()) == true
        if library.preferences.scopeEnabled, library.preferences.liveUsage != false {
            do { try LiveUsageBridge.install(store: store) } catch { statusLineIssue = backendReason(error) }
        }
    }

    public func snapshot() -> (Library, DaemonStatus) {
        let accounts = library.preferences.autoSort == true ? RelayOrder.sorted(library.accounts, at: now()) : library.accounts
        var copy = library; copy.accounts = accounts
        return (copy, DaemonStatus(message: message, relayPause: relayPause, relayRetryAt: relayRetryAt, scopeIssue: scopeIssue,
            scopeUnreadable: scopeUnreadable, statusLineIssue: statusLineIssue, lastEvent: lastEvent, appliedPending: appliedPending,
            apiModeDetected: apiModeDetected, sessionConfirmed: sessionConfirmed))
    }
    public func account(_ id: UUID) -> Account? { library.accounts.first { $0.id == id } }
    private func save() throws { try store.save(library) }
    private func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&library.accounts[index]); try? save()
    }
    public func setAuto(_ enabled: Bool) throws {
        relayGeneration += 1; noCandidateFailures = 0
        if enabled { latch = RelayLatch() }
        library.preferences.autoRelay = enabled
        library.preferences.autoRelayStopReason = nil
        relayPause = nil; relayRetryAt = nil; message = enabled ? "默认登录自动接力已开启" : "默认登录自动接力已关闭"
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
        // Someone just made an account available; a paused hand-off need not wait out its retry time.
        if enabled { relayRetryAt = nil }
        let bound = projects.projects(using: id).count
        message = !enabled && bound > 0 ? "已停用；绑定它的 \(bound) 个项目在重新启用前无法启动。" : (enabled ? "已启用" : "已停用")
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
        let catalog = try projectStore.load()
        projects = catalog
        let bound = catalog.projects(using: id).count
        guard bound == 0 else { throw BackendFailure("账号仍固定给 \(bound) 个项目，请先 project unbind 或换绑；本地凭据未删除。") }
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
        // A new login for an account fixed to projects goes into their scopes too, or they would keep the old one.
        if id != nil {
            for project in projects.projects(using: accountID) where project.phase != .preparing {
                do { try await syncProject(project, target: account, reauthorized: true) }
                catch { failProject(project, error) }
            }
        }
        message = "已保存“\(label)”"
        return accountID
    }
    public func takeOver(label: String?) async throws -> UUID {
        if library.preferences.scopeEnabled, let active = library.activeID {
            try runtime.rebaseline(); return active
        }
        let current = try runtime.currentCredential()
        if current == nil {
            guard let account = active ?? library.accounts.first(where: { !projects.reservedAccountIDs.contains($0.id) }) else {
                throw BackendFailure("默认登录和账号库都是空的；请先运行 `lilt login`。")
            }
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
        relayGeneration += 1
        library.preferences.scopeEnabled = false; library.preferences.autoRelay = false
        try LiveUsageBridge.uninstall(store: store); try save()
        message = "Lilt 不再管理默认登录；当前登录保持不变"
    }
    public func keepAPI() throws {
        relayGeneration += 1
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
    /// Whether some runtime scope holds this account's login: the default login or any project. Lilt never renews
    /// those itself; the CLI using the scope does, and Lilt reads the result back. Two renewals of one refresh token
    /// would leave one side with a token the server already spent.
    private func inScope(_ id: UUID) -> Bool { id == library.activeID || projects.reservedAccountIDs.contains(id) }
    private func renewed(_ id: UUID) async throws -> Credential {
        if let task = renewalTasks[id] { return try await task.value }
        let stored = try credential(id)
        guard !inScope(id), stored.refreshable, stored.expires(within: RelayPolicy.renewalLead) else { return stored }
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
    /// What `scope` holds relative to `account`'s stored login, taking it in when it is the same login renewed.
    private func readBack(_ account: Account, in scope: FileRuntimeScope? = nil) async -> OAuthDocument.ReadBack? {
        let scope = scope ?? runtime
        do {
            guard !scope.transactionPending, let stored = try store.readSecret(account.id.uuidString), let held = try scope.currentCredential() else { return .unverifiable }
            guard (try? held.validate()) != nil else { return .unverifiable }
            let mine = try store.readSecret(account.id.uuidString + ".identity")
            var verdict = OAuthDocument.readBack(stored: stored, runtime: held.data, storedIdentity: .init(oauthAccount: mine), runtimeIdentity: .init(oauthAccount: scope.readIdentity()))
            if verdict == .unverifiable || verdict == .foreign, mine != nil, held.refreshable {
                guard let asked = await identityClient.fetch(held) else { return nil }
                verdict = OAuthDocument.readBack(stored: stored, runtime: held.data, storedIdentity: .init(oauthAccount: mine), runtimeIdentity: .init(oauthAccount: asked))
            }
            guard verdict == .adopt || verdict == .unchanged else { return verdict }
            if verdict == .adopt {
                try store.writeSecret(account.id.uuidString, data: held.data)
                update(account.id) { $0.expiresAt = held.expiresAt; $0.issue = nil; $0.refreshRejected = nil }
            }
            try scope.rebaseline()
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
                    appliedPending = true; sessionConfirmed = false; lastSwitchAt = now(); lastEvent = "已完成上次中断的切换"; try save()
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
                    relayGeneration += 1
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
    private func isRateLimited(_ id: UUID) -> Bool {
        if case .rateLimited = usageFailures[id] { return true }
        return false
    }
    /// Requests for one account share one answer. Manual refresh may override an ordinary backoff, never a 429.
    public func refresh(_ id: UUID, manually: Bool = false) async {
        if switching { if manually { message = "正在切换账号，完成后即可刷新" }; return }
        if let running = refreshTasks[id] {
            await running.value
            if refreshTasks[id] == running { refreshTasks[id] = nil }
            guard manually, let next = backoffs[id]?.nextAttempt, next > now(), !isRateLimited(id), refreshTasks[id] == nil else { return }
        }
        if let next = backoffs[id]?.nextAttempt, next > now(), !manually || isRateLimited(id) {
            if manually { message = "额度暂未更新，请稍后再试。" }
            return
        }
        let task = Task { await self.performRefresh(id, manually: manually) }
        refreshTasks[id] = task; await task.value
        if refreshTasks[id] == task { refreshTasks[id] = nil }
    }
    private func performRefresh(_ id: UUID, manually: Bool) async {
        guard library.accounts.contains(where: { $0.id == id }) else { return }
        await spacing.reserve(gap: requestGap)
        if let next = backoffs[id]?.nextAttempt, next > now(), isRateLimited(id) {
            if manually { message = "额度暂未更新，请稍后再试。" }
            return
        }
        // A project's CLI may have renewed this account's login; the stored copy could be expired or spent.
        if let project = projects.projects.first(where: { $0.accountID == id && $0.phase == .ready }), !projectBusy.contains(project.id) {
            try? await syncProject(project, target: nil)
        }
        var asked: Credential?
        do {
            let credential = try await renewed(id); asked = credential
            let snapshot = try await usageClient.fetch(credential)
            guard library.accounts.contains(where: { $0.id == id }), current(credential, id: id) else { return }
            update(id) { $0.usage = snapshot; $0.usageCapability = .verified; $0.lastChecked = self.now(); $0.issue = nil }
            if id == library.activeID { notePace(snapshot, id: id) }
            backoffs[id]?.succeed(); usageFailures[id] = nil; message = "额度已更新"
            if credential.refreshable, !(try store.readSecret(id.uuidString + ".identity") != nil),
               let record = await identityClient.fetch(credential), current(credential, id: id) {
                try store.writeSecret(id.uuidString + ".identity", data: record)
            }
        } catch let failure as ScopeUnreadable { message = failure.message }
        catch let failure as BackendFailure { message = failure.message }
        catch {
            if let asked, !current(asked, id: id) { return }
            let failure = error as? UsageFailure ?? .network
            backoffs[id, default: Backoff()].fail(failure, at: now()); usageFailures[id] = failure
            // A failed attempt is not a fresh measurement. Keep the last reading and its original sampling time.
            update(id) { $0.issue = failure.message; if failure == .permission { $0.usageCapability = .unavailable } }
            message = "额度暂未更新，保留上次读数。"
        }
    }
    public func refreshAll() async { for account in library.accounts where account.enabled { await refresh(account.id, manually: true) } }
    private func notePace(_ reading: UsageSnapshot, id: UUID) {
        if paceAccount != id { paceAccount = id; paceReadings = [] }
        paceReadings.removeAll { $0.sampledAt >= reading.sampledAt || reading.sampledAt.timeIntervalSince($0.sampledAt) > UsagePace.span }
        paceReadings.append(reading)
        // The first reading after taking over says what the switch cost; it is kept as margin, not as pace.
        if let jump = pendingJump, jump.account == id, reading.sampledAt > lastSwitchAt {
            switchAllowance = UsagePace.switchAllowance(confirmed: jump.confirmed, first: reading)
            pendingJump = nil
        }
    }
    @discardableResult
    public func apply(_ id: UUID, automatically: Bool = false) async throws -> Bool {
        guard !switching, let target = library.accounts.first(where: { $0.id == id }), target.enabled else { return false }
        if automatically, apiModeDetected || library.preferences.keepAPIMode == true { return false }
        // The default login does not take an account fixed to a project, by hand or by relay. Re-applying the account
        // already in it (after a new login, say) is not a switch and stays allowed.
        if projects.reservedAccountIDs.contains(id), id != library.activeID {
            if automatically { return false }
            throw BackendFailure("“\(target.label)”已固定给项目，默认登录不能使用它；先在项目中解绑或换绑。")
        }
        guard library.preferences.scopeEnabled else { throw BackendFailure("请先接管 Claude Code 默认登录。") }
        if !automatically { relayGeneration += 1 }
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
            let scope = runtime
            try await Task.detached { try scope.apply(credential, identity: identity, replacingExternalState: !automatically) }.value
            library.activeID = id; library.preferences.keepAPIMode = nil; library.preferences.autoRelayStopReason = nil
            apiModeDetected = false; appliedPending = true; sessionConfirmed = false; relayPause = nil; relayRetryAt = nil; scopeIssue = nil
            noCandidateFailures = 0
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
    private func policy(soonerWeekly: Bool = false, requiredMargin: Thresholds = 0) -> RelayPolicy {
        RelayPolicy(threshold: thresholds, allowUnverifiedHotSwitch: true, leftRecently: RelayPolicy.coolingDown(departedID, since: departedAt, at: now()),
                    soonerWeekly: soonerWeekly, requiredMargin: requiredMargin)
    }
    private func lifetime(of snapshot: UsageSnapshot) -> TimeInterval { snapshot.source == UsageParser.statusLineSource ? 300 : 60 }
    /// What an account taking over from `active` must have above its threshold (see `UsagePace.candidateMargin`).
    private func candidateMargin(_ active: Account) -> Thresholds {
        var pace: Thresholds = 0
        if paceAccount == active.id, let usage = active.usage {
            pace = UsagePace.projectedMargin(usage, after: paceReadings, at: now(), lifetime: lifetime(of: usage), reactionTime: reactionTime)
        }
        return UsagePace.candidateMargin(pace: pace, allowance: switchAllowance)
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
        guard !LiveUsageBridge.isInstalled(store: store) else { if !liveGap { statusLineIssue = nil }; return }
        guard now().timeIntervalSince(lastStatusLineRepair) >= 600 else {
            statusLineIssue = "状态栏被其他工具替换，Lilt 稍后再接上；期间按时查询额度。"; return
        }
        do {
            try LiveUsageBridge.install(store: store)
            try LiveUsageBridge.setLabel(store, active?.label)
            lastStatusLineRepair = now(); statusLineIssue = nil
        } catch { statusLineIssue = backendReason(error) }
    }
    /// Takes in what sessions reported, for the default login and every project, and acts on it at once. It waits for
    /// nothing: not a usage request, not a switch, not the scope check, which only gate writing.
    public func observe() async {
        var accepted = false
        if library.preferences.scopeEnabled, library.preferences.liveUsage != false {
            let batch = LiveUsageBridge.drain(store: store)
            if batch.hasGaps, let active { forcePoll.insert(active.id) }
            if batch.hasGaps != liveGap {
                liveGap = batch.hasGaps
                if batch.hasGaps { statusLineIssue = Self.gapText; store.log("live-gap") }
                else if statusLineIssue == Self.gapText { statusLineIssue = nil }
            }
            // Only a login proven foreign keeps readings off the account; one that merely did not read does not.
            if scopeIssue == nil, !apiModeDetected, let active {
                let readings = LiveUsageFold.readings(batch.events, scope: LiveUsageEvent.defaultScope, known: active.usage, since: lastSwitchAt, at: now())
                if let last = readings.last {
                    update(active.id) { $0.usage = last; $0.usageCapability = .verified; $0.issue = nil }
                    for reading in readings { notePace(reading, id: active.id) }
                    // One session reported the account switched to. Whether every other session followed is unknown.
                    if appliedPending { appliedPending = false; sessionConfirmed = true }
                    accepted = true
                }
            }
        }
        var changed = false
        for index in projects.projects.indices where projects.projects[index].phase == .ready {
            let project = projects.projects[index]
            let batch = LiveUsageBridge.drain(store: store, scope: projectStore.runtime(for: project))
            if batch.hasGaps { forcePoll.insert(project.accountID) }
            guard let account = self.account(project.accountID) else { continue }
            let readings = LiveUsageFold.readings(batch.events, scope: project.eventScope, known: account.usage, since: project.updatedAt, at: now())
            guard let last = readings.last else { continue }
            update(account.id) { $0.usage = last; $0.usageCapability = .verified; $0.issue = nil }
            if project.appliedPending { projects.projects[index].appliedPending = false; changed = true }
        }
        if changed { try? projectStore.save(projects) }
        if accepted { await relay(); await prepareHandOff() }
    }
    public func globalRelayCandidates() -> [Account] {
        library.accounts.filter { !projects.reservedAccountIDs.contains($0.id) }
    }
    private func relayCandidates(_ policy: RelayPolicy, besides activeID: UUID) -> [Account] {
        globalRelayCandidates().filter { $0.id != activeID && $0.enabled && $0.usageCapability != .unavailable && $0.refreshRejected != true && $0.id != policy.leftRecently }
    }
    private func readable(_ id: UUID) -> Bool { (backoffs[id]?.nextAttempt ?? .distantPast) <= now() }
    /// Reads ahead the account a hand-off would take, and one fallback, so that one of them is still confirmed when
    /// the hand-off comes (see `RelayPolicy.preparationRead`).
    private func prepareHandOff() async {
        guard library.preferences.autoRelay == true, !switching, !relayRunning, let active, let usage = active.usage,
              (relayRetryAt ?? .distantPast) <= now(), now().timeIntervalSince(preparedAt) >= 15 else { return }
        let seconds = paceAccount == active.id ? UsagePace.secondsToThreshold(usage, after: paceReadings, threshold: thresholds, at: now(), lifetime: lifetime(of: usage)) : nil
        let policy = policy(requiredMargin: candidateMargin(active))
        let due = policy.handOffOrder(relayCandidates(policy, besides: active.id), leaving: active, at: now()).filter { readable($0.id) }
            .prefix(RelayPolicy.preparationReads).filter {
                RelayPolicy.preparationRead(age: now().timeIntervalSince($0.usage?.sampledAt ?? .distantPast), secondsToThreshold: seconds, nearThreshold: nearThreshold)
            }
        guard !due.isEmpty else { return }
        preparedAt = now()
        for candidate in due { await refresh(candidate.id) }
    }
    private func relayValid(_ generation: Int, active id: UUID) -> Bool {
        library.preferences.autoRelay == true && generation == relayGeneration && !switching && library.activeID == id
            && scopeIssue == nil && !apiModeDetected && library.preferences.keepAPIMode != true
    }
    private func relay() async {
        guard !relayRunning else { relayAgain = true; return }
        relayRunning = true
        defer { relayRunning = false }
        repeat { relayAgain = false; await relayOnce() } while relayAgain
    }
    private func relayOnce() async {
        guard library.preferences.autoRelay == true, !switching, let active, let snapshot = active.usage,
              library.preferences.scopeEnabled, scopeIssue == nil, scopeUnreadable == nil, !apiModeDetected, library.preferences.keepAPIMode != true else { return }
        let generation = relayGeneration, started = ContinuousClock.now
        let triggered = snapshot.exhausted(threshold: thresholds, at: now(), lifetime: lifetime(of: snapshot))
        let ahead = !triggered && paceAccount == active.id
            && UsagePace.nearing(snapshot, after: paceReadings, threshold: thresholds, at: now(), lifetime: lifetime(of: snapshot), reactionTime: reactionTime)
        let due = triggered || ahead
        let early = library.preferences.soonerWeekly == true && !due && snapshot.isFresh(at: now())
        guard due || early else {
            if snapshot.available(threshold: thresholds, at: now()) { relayPause = nil; relayRetryAt = nil; noCandidateFailures = 0 }
            return
        }
        if let relayRetryAt, relayRetryAt > now() { return }
        let policy = policy(soonerWeekly: early, requiredMargin: early ? 0 : candidateMargin(active))
        if due {
            var asked = Set<UUID>()
            while asked.count < RelayPolicy.handOffReads, relayValid(generation, active: active.id),
                  let next = policy.nextRead(relayCandidates(policy, besides: active.id), leaving: self.active, asked: asked, readable: { self.readable($0) }, at: now()) {
                asked.insert(next.id); await refresh(next.id)
            }
        } else if let activeReset = snapshot.sevenDay?.resetsAt, activeReset > now() {
            var reads = 0
            for candidate in relayCandidates(policy, besides: active.id) where reads < RelayPolicy.preparationReads {
                guard let reset = candidate.usage?.sevenDay?.resetsAt, reset > now(), reset < activeReset else { continue }
                if policy.obstacle(for: candidate, at: now()) == nil { continue }
                if now().timeIntervalSince(candidate.lastChecked ?? .distantPast) < RelayPolicy.confirmLifetime { continue }
                reads += 1; await refresh(candidate.id)
            }
        }
        guard relayValid(generation, active: active.id) else { return }
        // Decided on the newest reading of the account in use: readings that kept arriving during the reads are
        // taken into account rather than making the hand-off give up and start over.
        guard let current = self.active, let latest = current.usage else { return }
        let aheadNow = !triggered && paceAccount == current.id
            && UsagePace.nearing(latest, after: paceReadings, threshold: thresholds, at: now(), lifetime: lifetime(of: latest), reactionTime: reactionTime)
        switch policy.decide(active: current, candidates: relayCandidates(policy, besides: current.id), at: now(), holdActiveReading: triggered, ahead: aheadNow) {
        case .select(let id):
            guard latch.claim(account: current.id, snapshot: latest) else { return }
            noCandidateFailures = 0
            let confirmed = account(id)?.usage
            let confirming = (ContinuousClock.now - started).seconds, writing = ContinuousClock.now
            do {
                if try await apply(id, automatically: true) {
                    reactionTime = UsagePace.reactionTime(measured: (ContinuousClock.now - started).seconds)
                    store.log("auto-timing", detail: relayTiming(paced: !triggered, readingAge: now().timeIntervalSince(latest.sampledAt),
                                                                 confirm: confirming, write: (ContinuousClock.now - writing).seconds))
                    departedID = current.id; departedAt = now(); lastEvent = "已自动接力"; message = "已自动接力"
                    pendingJump = confirmed.map { (id, $0) }
                } else if !runtime.transactionPending { latch.release(account: current.id, snapshot: latest) }
            } catch { if !runtime.transactionPending { latch.release(account: current.id, snapshot: latest) } }
        case .pause(let reason):
            guard due else { break }
            noCandidateFailures += 1
            let ordinary = min(120, 15 * pow(2, Double(min(noCandidateFailures - 1, 3))))
            let others = globalRelayCandidates().filter { $0.id != current.id }
            let blocked = others.compactMap { policy.obstacle(for: $0, at: now()) }
            let detail = Dictionary(grouping: blocked, by: { $0 }).sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
                .map { "\($0.value.count) 个账号\($0.key)" }.joined(separator: "，")
            relayRetryAt = policy.retryAt(others, at: now(), ordinary: ordinary, backoffUntil: { self.backoffs[$0]?.nextAttempt },
                                          cooldownEnds: departedAt?.addingTimeInterval(RelayPolicy.departureCooldown))
            relayPause = reason + (detail.isEmpty ? "" : "（\(detail)）") + " 保持开启，到时重新确认。"
        case .wait: break
        }
    }
    public func startTick() {
        guard tickTask == nil else { return }
        let task = Task { await self.tick() }
        tickTask = task
        Task {
            await task.value
            self.finishTick(task)
        }
    }
    private func finishTick(_ task: Task<Void, Never>) {
        if tickTask == task { tickTask = nil }
    }
    private func pollUsage() async {
        if let active {
            if forcePoll.remove(active.id) != nil || UsagePolling.due(active, active: true, autoRelay: library.preferences.autoRelay == true, nearThreshold: nearThreshold, watching: false, at: now()) {
                await refresh(active.id)
            }
        }
        let alternates = UsagePolling.refreshOrder(globalRelayCandidates().filter { $0.id != library.activeID })
        var reads = 0
        for account in alternates where reads < UsagePolling.alternatesPerPass {
            if forcePoll.remove(account.id) != nil || UsagePolling.due(account, active: false, autoRelay: library.preferences.autoRelay == true, nearThreshold: false, watching: false, at: now()) {
                reads += 1
                await refresh(account.id)
            }
        }
    }
    public func tick() async {
        guard !switching else { return }
        do { projects = try projectStore.load() }
        catch { message = backendReason(error); return }
        // A scope that did not read, or holds something to look at, only stops writing; quota is still read.
        let writable = await reconcile()
        checkStatusLine()
        await observe()
        await pollUsage()
        await pollProjects()
        if writable { await relay(); await prepareHandOff() }
    }
    /// Project accounts never relay, so they are read only to show where they stand: when sessions have not reported
    /// for a while, at the idle pace, or at once after events went missing.
    private func pollProjects() async {
        var reads = 0
        for project in projects.projects where project.phase == .ready && reads < 2 {
            guard let account = self.account(project.accountID), account.enabled, account.usageCapability != .unavailable else { continue }
            let fresh = account.usage.map { now().timeIntervalSince($0.sampledAt) < 300 } ?? false
            if forcePoll.remove(account.id) != nil || (!fresh && now().timeIntervalSince(account.lastChecked ?? .distantPast) >= 900) {
                reads += 1; await refresh(account.id)
            }
        }
    }
}

// MARK: - Projects

extension HeadlessEngine {
    public func projectCatalog() throws -> ProjectCatalog {
        projects = try projectStore.load()
        return projects
    }

    public func projectStatus(rootPath: String) throws -> ProjectBinding {
        projects = try projectStore.load()
        guard var binding = projects.binding(rootPath: rootPath) else { throw BackendFailure("这个目录还没有绑定项目。") }
        if FileRuntimeScope(store: store, scope: projectStore.runtime(for: binding)).transactionPending {
            binding.phase = .conflict
            binding.issue = "项目有未完成的凭据事务，请 rebind 后再启动。"
        } else if !FileManager.default.fileExists(atPath: binding.rootPath) {
            binding.issue = "项目目录已不存在；目录移动后需要在新位置重新绑定。"
        }
        return binding
    }

    private func saveProjects() throws { try projectStore.save(projects) }

    private func failProject(_ binding: ProjectBinding, _ error: Error) {
        guard let index = projects.projects.firstIndex(where: { $0.id == binding.id }) else { return }
        projects.projects[index].phase = .conflict
        projects.projects[index].issue = backendReason(error)
        projects.projects[index].updatedAt = now()
        try? saveProjects()
    }

    /// The account to check `held` against: the one with the same bytes stored, else the one the scope's own config
    /// names, else `holder`, the account the binding says is there. This only picks the candidate; `readBack` then
    /// decides whether the login provably is that account's (same refresh token, or same account id on both sides).
    private func owner(of held: Credential, in scope: FileRuntimeScope, holder: UUID?) -> Account? {
        if let exact = library.accounts.first(where: { (try? store.readSecret($0.id.uuidString)) == held.data }) { return exact }
        if let named = OAuthDocument.Identity(oauthAccount: scope.readIdentity()).account,
           let match = library.accounts.first(where: { OAuthDocument.Identity(oauthAccount: try? store.readSecret($0.id.uuidString + ".identity")).account == named }) {
            return match
        }
        return holder.flatMap(account)
    }

    /// Brings a project's scope in line with its binding. First what the scope holds is accounted for: a login the
    /// project's CLI renewed is taken in when it provably is the same login, while a login nobody can account for,
    /// a transaction left halfway or an API override stops everything without writing. Then `target`'s login is
    /// written, unless the scope already holds it, in which case nothing is written at all. `reauthorized` means
    /// the user just signed `target` in again: the project's older copy of that same account is replaced rather than
    /// read back over the new one. Only this project's directory is touched.
    private func syncProject(_ binding: ProjectBinding, target: Account?, holder: UUID? = nil, reauthorized: Bool = false) async throws {
        let holder = holder ?? (projects.binding(id: binding.id)?.accountID)
        let scopePaths = projectStore.runtime(for: binding)
        let scope = FileRuntimeScope(store: store, scope: scopePaths)
        if scope.transactionPending {
            guard let held = try scope.currentCredential(), owner(of: held, in: scope, holder: nil).map({ (try? store.readSecret($0.id.uuidString)) == held.data }) == true else {
                throw BackendFailure("项目有未完成的凭据事务，且当前登录不属于已知账号；没有改动。")
            }
            try scope.rebaseline()
        }
        if (try? scope.check()) == nil {
            if let held = try scope.currentCredential() {
                if reauthorized, let target {
                    let theirs = OAuthDocument.Identity(oauthAccount: scope.readIdentity())
                    let mine = OAuthDocument.Identity(oauthAccount: try? store.readSecret(target.id.uuidString + ".identity"))
                    guard theirs.account == nil || mine.account == nil || theirs.account == mine.account else {
                        throw BackendFailure("项目配置里是另一个账号的登录；没有覆盖。")
                    }
                    try scope.rebaseline()
                } else {
                    guard let owner = owner(of: held, in: scope, holder: holder) else { throw BackendFailure("项目配置里已有无法确认归属的登录；Lilt 不会覆盖它。") }
                    switch await readBack(owner, in: scope) {
                    case .adopt, .unchanged: break
                    case nil: throw BackendFailure("暂时读不到项目登录，稍后再试；没有改动。")
                    case .unverifiable, .foreign: throw BackendFailure("项目里的登录无法证明仍属于“\(owner.label)”；没有覆盖。")
                    }
                }
            } else {
                try scope.rebaseline()
            }
        }
        guard let target else { return }
        // A renewal of the target that is under way finishes first, or its old refresh token would go into the scope.
        if let renewal = renewalTasks[target.id] { _ = try? await renewal.value }
        let login = try credential(target.id)
        if try scope.currentCredential()?.data != login.data {
            let identity = try? store.readSecret(target.id.uuidString + ".identity")
            try await Task.detached { try scope.apply(login, identity: identity, replacingExternalState: false) }.value
            store.log("project-applied")
        }
        if library.preferences.liveUsage != false {
            let label = target.label, owner = store
            try await Task.detached {
                try LiveUsageBridge.install(store: owner, scope: scopePaths)
                try LiveUsageBridge.setLabel(owner, label, scope: scopePaths)
            }.value
        }
    }

    private func claimProject(_ id: UUID) throws {
        guard projectBusy.insert(id).inserted else { throw BackendFailure("这个项目正在处理另一个操作，请稍后再试。") }
    }

    public func bindProject(rootPath: String, accountID: UUID, allowShared: Bool) async throws -> ProjectBinding {
        projects = try projectStore.load()
        let root = try ProjectCatalogStore.existingRoot(rootPath)
        if let problem = ProjectRules.repositoryProblem(root: root) { throw BackendFailure(problem) }
        let account = library.accounts.first { $0.id == accountID }
        if let problem = ProjectRules.bindingProblem(root: root, account: account, catalog: projects,
                                                     defaultLoginAccount: library.preferences.scopeEnabled ? library.activeID : nil,
                                                     allowShared: allowShared) { throw BackendFailure(problem) }
        let timestamp = now()
        var binding = ProjectBinding(name: URL(fileURLWithPath: root).lastPathComponent, rootPath: root, accountID: accountID,
                                     createdAt: timestamp, updatedAt: timestamp, phase: .preparing, appliedPending: true)
        try claimProject(binding.id); defer { projectBusy.remove(binding.id) }
        relayGeneration += 1
        projects.projects.append(binding)
        try saveProjects()
        do {
            try await syncProject(binding, target: account)
            guard let index = projects.projects.firstIndex(where: { $0.id == binding.id }) else { throw BackendFailure("项目绑定在准备期间被移除。") }
            binding.phase = .ready; binding.issue = nil; binding.updatedAt = now()
            projects.projects[index] = binding
            try saveProjects()
            message = "项目已绑定固定账号；默认登录没有改动"
            if !(account?.usage?.isFresh(at: now(), lifetime: 300) ?? false) { Task { await self.refresh(accountID) } }
            return binding
        } catch {
            failProject(binding, error)
            throw error
        }
    }

    public func rebindProject(rootPath: String, accountID: UUID, allowShared: Bool) async throws -> ProjectBinding {
        projects = try projectStore.load()
        guard var binding = projects.binding(rootPath: rootPath) else { throw BackendFailure("这个目录还没有绑定项目。") }
        guard FileManager.default.fileExists(atPath: binding.rootPath) else { throw BackendFailure("项目目录已不存在；请解绑后在新位置重新绑定。") }
        if let problem = ProjectRules.repositoryProblem(root: binding.rootPath) { throw BackendFailure(problem) }
        let account = library.accounts.first { $0.id == accountID }
        if let problem = ProjectRules.bindingProblem(root: binding.rootPath, account: account, catalog: projects,
                                                     defaultLoginAccount: library.preferences.scopeEnabled ? library.activeID : nil,
                                                     allowShared: allowShared, replacing: binding.id) { throw BackendFailure(problem) }
        try claimProject(binding.id); defer { projectBusy.remove(binding.id) }
        let previous = binding.accountID
        binding.accountID = accountID; binding.phase = .preparing; binding.appliedPending = true; binding.issue = nil; binding.updatedAt = now()
        guard let index = projects.projects.firstIndex(where: { $0.id == binding.id }) else { throw BackendFailure("项目绑定已变化，请重试。") }
        projects.projects[index] = binding
        try saveProjects()
        do {
            try await syncProject(binding, target: account, holder: previous)
            guard let index = projects.projects.firstIndex(where: { $0.id == binding.id }) else { throw BackendFailure("项目绑定在准备期间被移除。") }
            binding.phase = .ready; binding.issue = nil; binding.updatedAt = now()
            projects.projects[index] = binding
            try saveProjects()
            message = "项目固定账号已更换；同一项目里正在运行的 CLI 会一起换到它，默认登录没有改动"
            if !(account?.usage?.isFresh(at: now(), lifetime: 300) ?? false) { Task { await self.refresh(accountID) } }
            return binding
        } catch {
            failProject(binding, error)
            throw error
        }
    }

    /// Stops managing the project. Its configuration, login and session history stay where they are; binding the
    /// same directory again finds them. The project's status line goes back to what it was.
    public func unbindProject(rootPath: String) throws -> ProjectBinding {
        projects = try projectStore.load()
        guard let binding = projects.binding(rootPath: rootPath) else { throw BackendFailure("这个目录还没有绑定项目。") }
        try claimProject(binding.id); defer { projectBusy.remove(binding.id) }
        projects.projects.removeAll { $0.id == binding.id }
        try saveProjects()
        try? LiveUsageBridge.uninstall(store: store, scope: projectStore.runtime(for: binding))
        message = "项目绑定已移除；项目配置和登录保留，该账号可重新用于默认登录"
        return binding
    }

    /// Checks everything a launch needs and returns how to start the official CLI on the project's configuration. The
    /// scope is written only when it does not hold the bound login yet. Nothing here falls back to the default login.
    public func projectLaunch(rootPath: String) async throws -> ProjectLaunchPlan {
        projects = try projectStore.load()
        guard let binding = projects.binding(rootPath: rootPath) else { throw BackendFailure("这个目录没有项目绑定；不会改用普通 claude。") }
        guard FileManager.default.fileExists(atPath: binding.rootPath) else { throw BackendFailure("项目目录已不存在；目录移动后需要在新位置重新绑定。") }
        let account = self.account(binding.accountID)
        if let problem = ProjectRules.launchProblem(binding, account: account) { throw BackendFailure(problem) }
        if let problem = ProjectRules.repositoryProblem(root: binding.rootPath) { throw BackendFailure(problem) }
        try claimProject(binding.id); defer { projectBusy.remove(binding.id) }
        let scope = FileRuntimeScope(store: store, scope: projectStore.runtime(for: binding))
        do {
            try await syncProject(binding, target: account)
            guard try !scope.hasAPIOverride() else { throw BackendFailure("项目配置含 API 或供应商覆盖；固定订阅账号不会覆盖它。") }
        } catch {
            failProject(binding, error)
            throw error
        }
        return ProjectLaunchPlan(projectID: binding.id, rootPath: binding.rootPath, configDirectory: scope.scope.claudeDirectory.path)
    }
}

// MARK: - Moving accounts to another machine

extension HeadlessEngine {
    /// The whole account library, encrypted with `passphrase`. Every scope is checked first and whatever a CLI renewed
    /// is taken in when it provably is the same login; a scope that cannot be accounted for stops the export, since
    /// the archive would carry a login that may already be spent.
    public func exportArchive(passphrase: String) async throws -> (Data, TransferSummary) {
        guard !switching, projectBusy.isEmpty else { throw BackendFailure("正在切换账号或处理项目，完成后再导出。") }
        if let problem = CredentialTransfer.passphraseProblem(passphrase) { throw BackendFailure(problem) }
        guard !library.accounts.isEmpty else { throw BackendFailure("账号库是空的，没有可导出的账号。") }
        projects = try projectStore.load()
        if library.preferences.scopeEnabled {
            guard await reconcile(), scopeIssue == nil else { throw BackendFailure("默认登录的归属尚未确认（外部修改、未完成的切换或暂时读不到），未导出。") }
        }
        for project in projects.projects {
            guard project.phase == .ready else { throw BackendFailure("项目“\(project.name)”的登录尚未确认，未导出。") }
            do { try await syncProject(project, target: nil) }
            catch { throw BackendFailure("项目“\(project.name)”的登录尚未确认，未导出：\(backendReason(error))") }
        }
        let items = try library.accounts.map { account -> TransferItem in
            guard let login = try store.readSecret(account.id.uuidString) else { throw BackendFailure("账号库有缺失的凭据，未导出。") }
            return TransferItem(localID: account.id, label: account.label, kind: Credential(data: login).refreshable ? .oauth : .setupToken,
                                credential: login, identity: try store.readSecret(account.id.uuidString + ".identity"))
        }
        let archive = try CredentialTransfer.export(items, passphrase: passphrase, at: now())
        store.log("exported")
        return (archive, TransferSummary(exported: items.count))
    }

    /// Adds the accounts of an archive (see `CredentialImport`). The default login, the projects and every running
    /// session stay as they are; automatic relay is turned off when anything was added.
    public func importArchive(_ archive: Data, passphrase: String) async throws -> TransferSummary {
        guard !switching, projectBusy.isEmpty else { throw BackendFailure("正在切换账号或处理项目，完成后再导入。") }
        let items = try CredentialTransfer.importArchive(archive, passphrase: passphrase)
        let vault = store
        let plan = try CredentialImport.plan(items, into: library, stored: { try vault.readSecret($0.uuidString) },
                                             storedIdentity: { try vault.readSecret($0.uuidString + ".identity") }, at: now())
        let result = try CredentialImport.commit(plan, base: library, secrets: store.secretsDirectory, libraryFile: store.libraryFile)
        if result.added > 0 {
            relayGeneration += 1
            library = result.library
            relayPause = nil; relayRetryAt = nil
            store.log("imported")
        }
        message = "导入完成：新增 \(result.added)，跳过 \(result.skipped)，冲突 \(result.conflicts)。"
            + (result.added > 0 ? "新账号默认停用，自动接力已关闭；确认后再启用。" : "")
        return TransferSummary(added: result.added, skipped: result.skipped, conflicts: result.conflicts)
    }
}
