import Foundation

public enum AuthKind: String, Codable, CaseIterable, Sendable {
    case oauth, setupToken
    public var title: String { self == .oauth ? "浏览器授权" : "长效 Token" }
}
public enum Capability: String, Codable, Sendable { case unknown, verified, unavailable }
public struct UsageWindow: Codable, Equatable, Sendable {
    public var used: Double
    public var resetsAt: Date?
    public init(used: Double, resetsAt: Date? = nil) { self.used = used; self.resetsAt = resetsAt }
    public var remaining: Double? { used.isFinite && used >= 0 && used <= 100 ? max(0, 100 - used) : nil }
}
/// How much may be left of each window before relay hands off: a window with this much or less left counts as used up.
/// The two are set apart because they run out differently. The 5-hour window refills within hours, and leaving an
/// account early only costs what was left of it until then; the 7-day window refills once a week. An integer or
/// decimal literal sets both, as one threshold did before they were apart.
public struct Thresholds: Equatable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public var fiveHour: Double
    public var sevenDay: Double
    public init(fiveHour: Double, sevenDay: Double) {
        self.fiveHour = min(100, max(0, fiveHour)); self.sevenDay = min(100, max(0, sevenDay))
    }
    public init(_ both: Double) { self.init(fiveHour: both, sevenDay: both) }
    public init(floatLiteral value: Double) { self.init(value) }
    public init(integerLiteral value: Int) { self.init(Double(value)) }
}
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sampledAt: Date
    public var source: String
    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, sampledAt: Date = .now, source: String = "OAuth usage · 实验接口") {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.sampledAt = sampledAt; self.source = source
    }
    public func isFresh(at now: Date, lifetime: TimeInterval = 60) -> Bool {
        let age = now.timeIntervalSince(sampledAt)
        return age >= 0 && age <= lifetime
    }
    public func validRemaining(_ window: UsageWindow?, at now: Date, lifetime: TimeInterval = 60) -> Double? {
        guard isFresh(at: now, lifetime: lifetime), let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return window.remaining
    }
    /// Display only: the last observed value even after the sample went stale. Relay decisions never read this.
    public func lastKnownRemaining(_ window: UsageWindow?, at now: Date) -> Double? {
        guard sampledAt <= now, let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return window.remaining
    }
    /// Each window paired with its own threshold.
    private func windows(_ threshold: Thresholds) -> [(window: UsageWindow?, threshold: Double)] {
        [(fiveHour, threshold.fiveHour), (sevenDay, threshold.sevenDay)]
    }
    public func exhausted(threshold: Thresholds, at now: Date, lifetime: TimeInterval = 60) -> Bool {
        windows(threshold).contains { validRemaining($0.window, at: now, lifetime: lifetime).map { [t = $0.threshold] in $0 <= t + 0.000001 } ?? false }
    }
    /// The reading still puts a window at or under the threshold, after it has already qualified and Lilt has
    /// spent time reading the other accounts. Age no longer matters; a window that has since reset does not count.
    public func remainsExhausted(threshold: Thresholds, at now: Date) -> Bool {
        guard sampledAt <= now else { return false }
        return windows(threshold).contains { lastKnownRemaining($0.window, at: now).map { [t = $0.threshold] in $0 <= t + 0.000001 } ?? false }
    }
    public func available(threshold: Thresholds, at now: Date, lifetime: TimeInterval = 60) -> Bool {
        windows(threshold).allSatisfy { validRemaining($0.window, at: now, lifetime: lifetime).map { [t = $0.threshold] in $0 > t + 0.000001 } ?? false }
    }
}
public struct Account: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: AuthKind
    public var enabled = true
    public var usage: UsageSnapshot?
    public var usageCapability: Capability = .unknown
    public var hotSwitchCapability: Capability = .unknown
    public var expiresAt: Date?
    public var lastChecked: Date?
    public var issue: String?
    /// The refresh token was rejected. Automatic relay skips this account until a new authorization
    /// is stored. A later usage sample does not clear it. A dropped connection or a 429 never sets it.
    /// Optional so account files written before it existed still load.
    public var refreshRejected: Bool?
    public init(id: UUID = UUID(), label: String, kind: AuthKind) { self.id = id; self.label = label; self.kind = kind }
}
/// Where Lilt puts the selected account's login.
public enum ScopeTarget: String, Codable, Sendable {
    /// Claude Code's default login: every terminal that runs `claude` uses it, as with ORCA or CC Switch.
    case system
    /// A directory of Lilt's own; only CLIs started with Lilt's launch command use it. Kept for setups made before.
    case dedicated
}
public struct Preferences: Codable, Sendable {
    /// The 5-hour window's threshold, and the 7-day window's as well until `weeklyThreshold` is set: files from before
    /// the two were apart have only this one.
    public var threshold: Double = 1
    /// The 7-day window's threshold. Nil means the same as `threshold`.
    public var weeklyThreshold: Double?
    public var thresholds: Thresholds { Thresholds(fiveHour: threshold, sevenDay: weeklyThreshold ?? threshold) }
    public var scopeEnabled = false
    public var qualifiedVersion: String?
    public var shortcutKey: UInt32 = 37 // L
    public var shortcutModifiers: UInt32 = 2304 // command + option
    /// Whether the user left automatic relay on. Optional so account files written before it existed still load.
    public var autoRelay: Bool?
    /// A safety stop must remain explainable after relaunch. Never contains credentials or account identifiers.
    public var autoRelayStopReason: String?
    /// User chose to keep an API provider. Manual subscription selection clears this choice.
    public var keepAPIMode: Bool?
    /// Nil in files written before there was a choice; those always meant `dedicated`.
    public var scopeTarget: ScopeTarget?
    /// Read quota from Claude Code's status line. Nil means on.
    public var liveUsage: Bool?
    /// Use an account whose 7-day window resets sooner, even while the active account is still above
    /// the threshold. Nil and false keep the user's order and wait for the threshold. Optional so
    /// preference files written before the choice existed still load.
    public var soonerWeekly: Bool?
    /// Keep the relay order sorted by the 7-day window (see `RelayOrder`). Nil and false keep the order the user
    /// arranged. Optional so preference files written before the choice existed still load.
    public var autoSort: Bool?
    /// Ask GitHub every few hours whether a newer Lilt is out. Nil means on. Optional so preference files written
    /// before the choice existed still load.
    public var autoUpdateCheck: Bool?
    public init() {}
}
public struct Library: Codable, Sendable {
    public var accounts: [Account] = []
    public var preferences = Preferences()
    public var activeID: UUID?
    public init() {}
}
public enum RelayDecision: Equatable, Sendable {
    case wait, select(UUID), pause(String)
}
public struct RelayPolicy: Sendable {
    public var threshold: Thresholds
    /// Live accounts have no way yet to prove that a running CLI picks up swapped credentials. When true,
    /// "not proven" is accepted and only "known not to work" is refused; the demo keeps the strict rule.
    public var allowUnverifiedHotSwitch: Bool
    /// The account automatic relay just left, while `departureCooldown` still applies. Nil once that
    /// window has passed. AppModel only remembers who left and when; `coolingDown` turns that into this value.
    public var leftRecently: UUID?
    /// When true, a healthy active account may hand off to one whose 7-day window resets sooner.
    /// Off by default. Reaching the threshold ignores this and keeps the user's order.
    public var soonerWeekly: Bool
    /// How long before expiry a target account's access token is renewed.
    /// Claude Code refreshes on its own about five minutes ahead. Ten minutes is twice that buffer,
    /// so a token written into the scope is not already inside the CLI's refresh window.
    /// The account currently in the scope is never renewed here.
    public static let renewalLead: TimeInterval = 600
    /// After an automatic hand-off, the account just left cannot be selected again until this many
    /// seconds have passed. Two accounts sitting just above the threshold would otherwise swap on
    /// every sample. This is not a second threshold and not a ten-point lag.
    public static let departureCooldown: TimeInterval = 300
    /// How recent the reading of the account taking over must be. Sessions that have not followed a switch yet, or
    /// another machine, keep spending an account Lilt is not using, so an older reading can promise room that is gone.
    /// Readings up to ten minutes old used to count. The account a hand-off goes to is now read right before, unless it
    /// was read within these two minutes.
    public static let confirmLifetime: TimeInterval = 120
    /// Accounts with 5-hour windows this close count as equally empty at a hand-off, and the relay order (the user's,
    /// or the weekly one of `RelayOrder`) picks among them. Without it the order would only ever break exact ties.
    public static let roomTier: Double = 10
    /// The most accounts one hand-off reads, a couple of seconds apart. One is usually enough: more are read only when
    /// what Lilt knew of an account turns out to be out of date.
    public static let handOffReads = 4
    /// How many points above the threshold the account in use is close enough that the accounts which would take over
    /// are read ahead, so the hand-off finds the next one ready.
    public static let preparationMargin: Double = 15
    public init(threshold: Thresholds = 1, allowUnverifiedHotSwitch: Bool = false, leftRecently: UUID? = nil, soonerWeekly: Bool = false) {
        self.threshold = threshold; self.allowUnverifiedHotSwitch = allowUnverifiedHotSwitch
        self.leftRecently = leftRecently; self.soonerWeekly = soonerWeekly
    }
    /// The id to pass as `leftRecently`, or nil once the cooldown has elapsed or the clock is skewed.
    public static func coolingDown(_ account: UUID?, since leftAt: Date?, at now: Date) -> UUID? {
        guard let account, let leftAt else { return nil }
        let age = now.timeIntervalSince(leftAt)
        guard age >= 0, age < departureCooldown else { return nil }
        return account
    }
    /// What keeps an account from taking over whatever its quota, or nil when nothing does.
    private func barrier(for candidate: Account, at now: Date) -> String? {
        if !candidate.enabled { return "已停用" }
        // A dead refresh token stays out through later plentiful samples. Only a new authorization clears it.
        if candidate.refreshRejected == true { return "需重新授权" }
        if let expiry = candidate.expiresAt, expiry <= now { return "令牌已到期，需续期" }
        if candidate.hotSwitchCapability == .unavailable || (candidate.hotSwitchCapability == .unknown && !allowUnverifiedHotSwitch) { return "热切换未验证" }
        if candidate.usageCapability == .unavailable { return "读不到额度" }
        return nil
    }
    /// Why an account cannot take the baton right now, or nil when it can. Unknown quota is a reason, never a pass,
    /// and so is a reading older than `confirmLifetime`.
    public func obstacle(for candidate: Account, at now: Date) -> String? {
        if let barrier = barrier(for: candidate, at: now) { return barrier }
        guard let usage = candidate.usage else { return "额度未知" }
        // Used up until a reset says so whatever the reading's age: quota only comes back at the reset.
        if usage.remainsExhausted(threshold: threshold, at: now) { return "额度不足或不完整" }
        guard usage.isFresh(at: now, lifetime: Self.confirmLifetime) else { return "额度未确认" }
        if !usage.available(threshold: threshold, at: now, lifetime: Self.confirmLifetime) { return "额度不足或不完整" }
        // Only an account that would otherwise qualify says it just left. Anyone else keeps their own reason.
        if candidate.id == leftRecently { return "刚刚离开" }
        return nil
    }
    /// What the last reading leaves of a window, counting one that has reset since as full again. This only decides
    /// which accounts a hand-off reads first: the one it takes must still be read and found above the threshold, since a
    /// window that reset is not assumed refilled. Nil when the reading does not cover the window or is from the future.
    public static func expected(_ window: UsageWindow?, of usage: UsageSnapshot, at now: Date) -> Double? {
        guard usage.sampledAt <= now, let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return 100 }
        return window.remaining
    }
    /// How many points above its threshold the tighter window of an account taking over from `active` must be: above it
    /// at all, and further than `active` still is. A hand-off started ahead of the threshold must not go to an account
    /// closer to it than the one being left.
    private func floor(leaving active: Account?, at now: Date) -> Double {
        guard let usage = active?.usage else { return 0 }
        let left = [(usage.fiveHour, threshold.fiveHour), (usage.sevenDay, threshold.sevenDay)]
            .compactMap { window, limit in usage.lastKnownRemaining(window, at: now).map { $0 - limit } }.min()
        return max(0, left ?? 0)
    }
    /// The accounts a hand-off from `active` would go to, best first. Hand-offs used to take the first account in relay
    /// order above the threshold. On 2026-10-22 that meant accounts with 10–14% left: each was used up within a minute,
    /// and four hand-offs ran in three minutes while five accounts sat almost unused. The emptiest 5-hour window now
    /// comes first, judged by each account's last reading however old, since an idle account's quota only changes when
    /// a window resets. Within `roomTier` points the relay order decides. Accounts without a usable reading follow, in
    /// relay order. Left out are accounts that cannot take over whatever their quota, the one just left, and those whose
    /// reading leaves a window no further above its threshold than `active` is.
    public func handOffOrder(_ candidates: [Account], leaving active: Account?, at now: Date) -> [Account] {
        let floor = floor(leaving: active, at: now)
        var known: [(tier: Int, position: Int, account: Account)] = [], unknown: [Account] = []
        for (position, candidate) in candidates.enumerated()
        where candidate.id != active?.id && candidate.id != leftRecently && barrier(for: candidate, at: now) == nil {
            guard let usage = candidate.usage, let five = Self.expected(usage.fiveHour, of: usage, at: now),
                  let week = Self.expected(usage.sevenDay, of: usage, at: now) else { unknown.append(candidate); continue }
            guard min(five - threshold.fiveHour, week - threshold.sevenDay) > floor + 0.000001 else { continue }
            known.append((Int((100 - five) / Self.roomTier), position, candidate))
        }
        return known.sorted { ($0.tier, $0.position) < ($1.tier, $1.position) }.map(\.account) + unknown
    }
    /// The account a hand-off reads next, or nil once it should read no more: the best placed account is ready on a
    /// recent reading, or every account placed above it was already asked this time (`asked`) or cannot be asked now.
    /// A reading that shows less room than Lilt knew of moves that account down, and the one now in front is next.
    public func nextRead(_ candidates: [Account], leaving active: Account?, asked: Set<UUID>, readable: (UUID) -> Bool, at now: Date) -> Account? {
        let next = handOffOrder(candidates, leaving: active, at: now)
            .first { obstacle(for: $0, at: now) == nil || (!asked.contains($0.id) && readable($0.id)) }
        guard let next, obstacle(for: next, at: now) != nil else { return nil }
        return next
    }
    /// The first moment one of these accounts may have room again: the reset of whichever of its windows are at or under
    /// the threshold, whichever account gets there first. Nil when none of them is waiting for a known reset.
    public func nextReset(of candidates: [Account], at now: Date) -> Date? {
        candidates.filter { $0.enabled && $0.refreshRejected != true && $0.usageCapability != .unavailable }.compactMap { account -> Date? in
            guard let usage = account.usage else { return nil }
            // An account is out until every window that keeps it out has reset.
            return [(usage.fiveHour, threshold.fiveHour), (usage.sevenDay, threshold.sevenDay)].compactMap { window, limit -> Date? in
                guard let window, let reset = window.resetsAt, reset > now, let left = window.remaining, left <= limit + 0.000001 else { return nil }
                return reset
            }.max()
        }.min()
    }
    /// `ahead` says the account in use will reach the threshold within `UsagePace.lead` at the pace it is being spent;
    /// the hand-off then starts as if it had.
    public func decide(active: Account?, candidates: [Account], at now: Date, holdActiveReading: Bool = false, ahead: Bool = false) -> RelayDecision {
        guard let active, let usage = active.usage else { return .wait }
        let triggered = ahead || (holdActiveReading ? usage.remainsExhausted(threshold: threshold, at: now) : usage.exhausted(threshold: threshold, at: now))
        // Below the threshold nothing moves, unless the user opted into spending a weekly window that resets sooner.
        // At the threshold the user's order stands: this preference must not pull a worse account forward.
        if !triggered {
            guard soonerWeekly else { return .wait }
            return soonerWeeklyDecision(active: active, usage: usage, candidates: candidates, at: now)
        }
        // The best placed account that a recent reading shows ready. One placed above it could not be read just now.
        if let chosen = handOffOrder(candidates, leaving: active, at: now).first(where: { obstacle(for: $0, at: now) == nil }) {
            return .select(chosen.id)
        }
        return .pause("没有已确认可接力的账号；保留当前会话。")
    }
    /// The account whose 7-day window resets first, when that is sooner than the active account and both of its
    /// windows are above the threshold. An unknown reset does not qualify. Wait, rather than pause, when nobody
    /// does: the active account still has room.
    private func soonerWeeklyDecision(active: Account, usage: UsageSnapshot, candidates: [Account], at now: Date) -> RelayDecision {
        guard usage.isFresh(at: now), let activeReset = usage.sevenDay?.resetsAt, activeReset > now else { return .wait }
        var chosen: UUID?
        var earliest: Date?
        for candidate in candidates where candidate.id != active.id {
            guard obstacle(for: candidate, at: now) == nil else { continue }
            guard let reset = candidate.usage?.sevenDay?.resetsAt, reset > now, reset < activeReset else { continue }
            if let earliest, reset >= earliest { continue }
            chosen = candidate.id; earliest = reset
        }
        if let chosen { return .select(chosen) }
        return .wait
    }
}
/// The relay order when automatic sorting is on. Weekly quota that resets sooner is spent first, because whatever is
/// left of it is lost at the reset; accounts that reset later stay in reserve, so a large job has more to draw on.
/// The 5-hour window plays no part in the order. It only steers which ready account a hand-off picks.
public enum RelayOrder {
    /// Days until a 7-day reset, as the day figure on screen: under a day counts as 0, otherwise rounded to the
    /// nearest day. Accounts that both read “2 天后” share a day and are then ranked by what they have left.
    public static func day(until reset: Date, at now: Date) -> Int {
        let seconds = reset.timeIntervalSince(now)
        return seconds < 86400 ? 0 : Int((seconds / 86400).rounded())
    }
    /// Sooner reset day first; within a day more left first, then the earlier reset. A window that has not started
    /// runs the full seven days once it is used, so it sorts as day 7. Accounts without a usable 7-day reading come
    /// after those, including a window that has reset since it was read, which is read again rather than assumed
    /// full. Disabled accounts go last. Ties keep the user's own order, so turning sorting off restores it unchanged.
    public static func sorted(_ accounts: [Account], at now: Date) -> [Account] {
        typealias Key = (group: Int, day: Int, remaining: Double, reset: Date)
        func key(_ account: Account) -> Key {
            guard account.enabled else { return (2, 0, 0, .distantFuture) }
            guard let usage = account.usage, let window = usage.sevenDay, let remaining = usage.lastKnownRemaining(window, at: now) else {
                return (1, 0, 0, .distantFuture)
            }
            guard let reset = window.resetsAt else { return (0, 7, remaining, .distantFuture) }
            return (0, day(until: reset, at: now), remaining, reset)
        }
        let ranked = accounts.enumerated().map { (key: key($0.element), position: $0.offset, account: $0.element) }
        return ranked.sorted { a, b in
            if a.key.group != b.key.group { return a.key.group < b.key.group }
            if a.key.day != b.key.day { return a.key.day < b.key.day }
            if a.key.remaining != b.key.remaining { return a.key.remaining > b.key.remaining }
            if a.key.reset != b.key.reset { return a.key.reset < b.key.reset }
            return a.position < b.position
        }.map(\.account)
    }
}
/// A trigger remains consumed once a hand-off has started, even if it fails. Only a hand-off that never touched the
/// scope gives its trigger back, so the same reading can try again on the next pass.
public struct RelayLatch: Sendable {
    private var consumed: Set<String> = []
    public init() {}
    private static func key(_ account: UUID, _ snapshot: UsageSnapshot) -> String { "\(account):\(snapshot.sampledAt.timeIntervalSince1970)" }
    public mutating func claim(account: UUID, snapshot: UsageSnapshot) -> Bool {
        consumed.insert(Self.key(account, snapshot)).inserted
    }
    public mutating func release(account: UUID, snapshot: UsageSnapshot) {
        consumed.remove(Self.key(account, snapshot))
    }
}
public enum UsageFailure: Error, Equatable, Sendable {
    case authentication, permission, accessExpired, rateLimited(TimeInterval), network, invalidResponse
    public var message: String {
        switch self {
        case .authentication: "授权已失效，请重新授权。"
        case .permission: "此凭据读不到额度"
        case .accessExpired: "访问令牌已到期，等待续期"
        case .rateLimited: "额度接口要求稍后再查"
        case .network: "网络连接失败，稍后重试。"
        case .invalidResponse: "额度接口返回了无法识别的数据。"
        }
    }
}
public struct Backoff: Sendable {
    public private(set) var failures = 0
    public private(set) var nextAttempt = Date.distantPast
    public init() {}
    public mutating func fail(_ error: UsageFailure, at now: Date) {
        failures += 1
        var delay = min(900, 15 * pow(2, Double(min(failures - 1, 6))))
        if case .rateLimited(let server) = error { delay = max(delay, server) }
        if error == .authentication || error == .permission || error == .accessExpired { delay = max(delay, 900) }
        nextAttempt = now.addingTimeInterval(delay)
    }
    public mutating func succeed() { failures = 0; nextAttempt = .distantPast }
}
public enum UsageParser {
    public static func parse(_ data: Data, at now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageFailure.invalidResponse }
        func window(_ key: String) throws -> UsageWindow? {
            guard let object = root[key], !(object is NSNull) else { return nil }
            guard let dict = object as? [String: Any], let value = dict["utilization"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  (0...100).contains(value.doubleValue) else { throw UsageFailure.invalidResponse }
            var reset: Date?
            if let string = dict["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: string)
                if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: string) }
                guard reset != nil else { throw UsageFailure.invalidResponse }
            }
            return UsageWindow(used: value.doubleValue, resetsAt: reset)
        }
        guard root.keys.contains("five_hour") || root.keys.contains("seven_day") else { throw UsageFailure.invalidResponse }
        return try UsageSnapshot(fiveHour: window("five_hour"), sevenDay: window("seven_day"), sampledAt: now)
    }
}
import CoreFoundation
