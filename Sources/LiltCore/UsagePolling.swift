import Foundation

public enum UsagePolling {
    public static let activeInterval: TimeInterval = 300
    public static let idleActiveInterval: TimeInterval = 900
    public static let alternateInterval: TimeInterval = 300
    public static let idleAlternateInterval: TimeInterval = 600
    public static let resetSlack: TimeInterval = 5
    public static let alternatesPerPass = 2

    public static func interval(active: Bool, autoRelay: Bool, nearThreshold: Bool, watching: Bool) -> TimeInterval {
        if autoRelay, active { return nearThreshold ? 15 : 30 }
        if active { return watching ? activeInterval : idleActiveInterval }
        return watching ? alternateInterval : idleAlternateInterval
    }

    public static func resetNeedsRefresh(_ usage: UsageSnapshot?, lastChecked: Date?, at now: Date) -> Bool {
        guard let usage, let checked = lastChecked else { return false }
        return [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].compactMap { $0 }.contains {
            $0.addingTimeInterval(resetSlack) <= now && checked < $0.addingTimeInterval(resetSlack)
        }
    }

    public static func due(_ account: Account, active: Bool, autoRelay: Bool, nearThreshold: Bool, watching: Bool, at now: Date) -> Bool {
        guard account.enabled, account.usageCapability != .unavailable else { return false }
        if resetNeedsRefresh(account.usage, lastChecked: account.lastChecked, at: now) { return true }
        if active, let usage = account.usage, usage.source == UsageParser.statusLineSource {
            let liveWindow: TimeInterval = autoRelay ? 60 : 300
            if now.timeIntervalSince(usage.sampledAt) < liveWindow { return false }
        }
        let age = now.timeIntervalSince(account.lastChecked ?? .distantPast)
        return age < 0 || age >= interval(active: active, autoRelay: autoRelay, nearThreshold: nearThreshold, watching: watching)
    }

    public static func refreshOrder(_ accounts: [Account]) -> [Account] {
        accounts.sorted {
            ($0.lastChecked ?? $0.usage?.sampledAt ?? .distantPast, $0.label) < ($1.lastChecked ?? $1.usage?.sampledAt ?? .distantPast, $1.label)
        }
    }
}
