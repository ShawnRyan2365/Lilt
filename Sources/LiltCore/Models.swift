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
    public func validRemaining(_ window: UsageWindow?, at now: Date) -> Double? {
        guard isFresh(at: now), let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return window.remaining
    }
    /// Display only: the last observed value even after the sample went stale. Relay decisions never read this.
    public func lastKnownRemaining(_ window: UsageWindow?, at now: Date) -> Double? {
        guard sampledAt <= now, let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return window.remaining
    }
    public func exhausted(threshold: Double, at now: Date) -> Bool {
        [fiveHour, sevenDay].contains { validRemaining($0, at: now).map { $0 <= threshold + 0.000001 } ?? false }
    }
    public func available(threshold: Double, at now: Date) -> Bool {
        [fiveHour, sevenDay].allSatisfy { validRemaining($0, at: now).map { $0 > threshold + 0.000001 } ?? false }
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
    public init(id: UUID = UUID(), label: String, kind: AuthKind) { self.id = id; self.label = label; self.kind = kind }
}
public struct Preferences: Codable, Sendable {
    public var threshold: Double = 1
    public var scopeEnabled = false
    public var qualifiedVersion: String?
    public var shortcutKey: UInt32 = 37 // L
    public var shortcutModifiers: UInt32 = 2304 // command + option
    /// Whether the user left automatic relay on. Optional so account files written before it existed still load.
    public var autoRelay: Bool?
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
    public var threshold: Double
    /// Live accounts have no way yet to prove that a running CLI picks up swapped credentials. When true,
    /// "not proven" is accepted and only "known not to work" is refused; the demo keeps the strict rule.
    public var allowUnverifiedHotSwitch: Bool
    public init(threshold: Double = 1, allowUnverifiedHotSwitch: Bool = false) {
        self.threshold = min(100, max(0, threshold)); self.allowUnverifiedHotSwitch = allowUnverifiedHotSwitch
    }
    /// Why an account cannot take the baton right now, or nil when it can. Unknown quota is a reason, never a pass.
    public func obstacle(for candidate: Account, at now: Date) -> String? {
        if !candidate.enabled { return "已停用" }
        if let expiry = candidate.expiresAt, expiry <= now { return "令牌已到期，需续期" }
        if candidate.hotSwitchCapability == .unavailable || (candidate.hotSwitchCapability == .unknown && !allowUnverifiedHotSwitch) { return "热切换未验证" }
        if candidate.usageCapability == .unavailable { return "读不到额度" }
        guard let usage = candidate.usage else { return "额度未知" }
        guard usage.isFresh(at: now) else { return "额度数据已过期" }
        return usage.available(threshold: threshold, at: now) ? nil : "额度不足或不完整"
    }
    public func decide(active: Account?, candidates: [Account], at now: Date) -> RelayDecision {
        guard let active, let usage = active.usage, usage.exhausted(threshold: threshold, at: now) else { return .wait }
        for candidate in candidates where candidate.id != active.id {
            if obstacle(for: candidate, at: now) == nil { return .select(candidate.id) }
        }
        return .pause("没有已确认可接力的账号；保留当前会话。")
    }
}
/// A trigger remains consumed even if applying fails. Explicit rearming requires a new observation.
public struct RelayLatch: Sendable {
    private var consumed: Set<String> = []
    public init() {}
    public mutating func claim(account: UUID, snapshot: UsageSnapshot) -> Bool {
        let key = "\(account):\(snapshot.sampledAt.timeIntervalSince1970)"
        return consumed.insert(key).inserted
    }
}
public enum UsageFailure: Error, Equatable, Sendable {
    case authentication, permission, accessExpired, rateLimited(TimeInterval), network, invalidResponse
    public var message: String {
        switch self {
        case .authentication: "授权已失效，请重新授权。"
        case .permission: "此凭据读不到额度"
        case .accessExpired: "访问令牌已到期，等待续期"
        case .rateLimited: "额度接口限流，已按服务端要求延后重试。"
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
