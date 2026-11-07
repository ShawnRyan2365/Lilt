import Foundation

public enum UsagePolling {
    public static let activeInterval: TimeInterval = 300
    public static let idleActiveInterval: TimeInterval = 900
    public static let alternateInterval: TimeInterval = 1800
    public static let idleAlternateInterval: TimeInterval = 3600
    public static let relayActiveInterval: TimeInterval = 180
    public static let relayUrgentInterval: TimeInterval = 60
    public static let resetSlack: TimeInterval = 5
    public static let alternatesPerPass = 2

    public static func paceLifetime(of usage: UsageSnapshot) -> TimeInterval {
        usage.source == UsageParser.statusLineSource ? 300 : relayActiveInterval
    }

    public static func interval(active: Bool, autoRelay: Bool, urgent: Bool, watching: Bool) -> TimeInterval {
        if autoRelay, active { return urgent ? relayUrgentInterval : relayActiveInterval }
        if active { return watching ? activeInterval : idleActiveInterval }
        return watching ? alternateInterval : idleAlternateInterval
    }

    public static func resetNeedsRefresh(_ usage: UsageSnapshot?, lastChecked: Date?, at now: Date) -> Bool {
        guard let usage, let checked = lastChecked else { return false }
        return [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].compactMap { $0 }.contains {
            $0.addingTimeInterval(resetSlack) <= now && checked < $0.addingTimeInterval(resetSlack)
        }
    }

    /// A known exhausted account cannot qualify before every exhausted window with a known reset has rolled over.
    public static func waitingForExhaustionReset(_ account: Account, threshold: Thresholds, at now: Date) -> Bool {
        guard let usage = account.usage, usage.remainsExhausted(threshold: threshold, at: now) else { return false }
        return RelayPolicy(threshold: threshold).nextReset(of: [account], at: now) != nil
    }

    /// An automatic read of this account would be held back: it is known exhausted until a reset still ahead, and its
    /// login is not due for renewal (a renewal goes ahead and reads quota with it). Such an account sends nothing, so it
    /// must not take a polling slot either.
    public static func holdsForExhaustion(_ account: Account, active: Bool, threshold: Thresholds, at now: Date) -> Bool {
        !renewalDue(account, active: active, at: now) && waitingForExhaustionReset(account, threshold: threshold, at: now)
    }

    public static func renewalDue(_ account: Account, active: Bool, at now: Date) -> Bool {
        guard !active, account.enabled, account.kind == .oauth, account.refreshRejected != true,
              let expiresAt = account.expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(RelayPolicy.renewalLead)
    }

    public static func due(_ account: Account, active: Bool, autoRelay: Bool, urgent: Bool, watching: Bool, at now: Date) -> Bool {
        guard account.enabled, account.usageCapability != .unavailable else { return false }
        if renewalDue(account, active: active, at: now) { return true }
        if resetNeedsRefresh(account.usage, lastChecked: account.lastChecked, at: now) { return true }
        if active, let usage = account.usage, usage.source == UsageParser.statusLineSource {
            let liveWindow: TimeInterval = autoRelay ? 60 : 300
            if now.timeIntervalSince(usage.sampledAt) < liveWindow { return false }
        }
        let age = now.timeIntervalSince(account.lastChecked ?? .distantPast)
        return age < 0 || age >= interval(active: active, autoRelay: autoRelay, urgent: urgent, watching: watching)
    }

    public static func refreshOrder(_ accounts: [Account], at now: Date) -> [Account] {
        accounts.sorted {
            let leftRenewal = renewalDue($0, active: false, at: now)
            let rightRenewal = renewalDue($1, active: false, at: now)
            if leftRenewal != rightRenewal { return leftRenewal }
            if leftRenewal, let leftExpiry = $0.expiresAt, let rightExpiry = $1.expiresAt, leftExpiry != rightExpiry {
                return leftExpiry < rightExpiry
            }
            return ($0.lastChecked ?? $0.usage?.sampledAt ?? .distantPast, $0.label) < ($1.lastChecked ?? $1.usage?.sampledAt ?? .distantPast, $1.label)
        }
    }
}
