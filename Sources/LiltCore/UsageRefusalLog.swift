import Foundation

/// A server 429's wait outlives a relaunch. `Account.usageRetryAt` keeps it, and launch turns it back into the
/// account's backoff: without it, every restart asked each waiting account again at once and earned another refusal.
public enum UsageHold {
    /// The waits still running, keyed by account. Waits that have passed are cleared from the accounts; one further
    /// off than the server may ask for (a clock that moved) is cut to that limit.
    public static func restore(_ accounts: inout [Account], at now: Date) -> [UUID: Date] {
        var holds: [UUID: Date] = [:]
        for index in accounts.indices {
            guard let until = accounts[index].usageRetryAt else { continue }
            if until > now { holds[accounts[index].id] = min(until, now.addingTimeInterval(Backoff.longestServerWait)) }
            else { accounts[index].usageRetryAt = nil }
        }
        return holds
    }
}

/// Lilt's own usage requests in the last hour, per account and in all. Held in memory, so the counts start again at
/// launch. A 429 line carries them, which sets a refusal beside how often Lilt itself had been asking.
public struct UsageRequestTally: Sendable {
    public static let span: TimeInterval = 3600
    private var times: [UUID: [Date]] = [:]
    public init() {}
    public mutating func note(_ account: UUID, at now: Date) {
        times = times.compactMapValues { list in
            let kept = list.filter { now.timeIntervalSince($0) < Self.span }
            return kept.isEmpty ? nil : kept
        }
        times[account, default: []].append(now)
    }
    public func count(_ account: UUID, at now: Date) -> Int {
        times[account]?.filter { now.timeIntervalSince($0) < Self.span }.count ?? 0
    }
    public func total(at now: Date) -> Int {
        times.values.reduce(0) { sum, list in sum + list.filter { now.timeIntervalSince($0) < Self.span }.count }
    }
}

/// One line for `switches.log` when the usage endpoint refuses an account. It says what the server asked for and how
/// long the account now waits (Lilt's own backoff can be longer; a server value beyond 75 minutes is cut), whether it
/// was the active account, and whether every read now waits. Two counts follow: Lilt's own requests in the last hour
/// for this account and for all of them. A spare account also says how long ago it was last the active one ("unknown"
/// when not since launch): other programs share the active account's token, so a refusal soon after it left points at
/// them, and a high count of Lilt's own points at Lilt. Numbers only; no names, ids or secrets.
public func usageRefusal(retryAfter: TimeInterval?, wait: TimeInterval, active: Bool, pausedAll: Bool,
                         left: TimeInterval? = nil, requests: Int, allRequests: Int) -> String {
    let whole = { (value: TimeInterval) in String(format: "%.0f", max(0, value)) }
    var line = "retry-after=\(retryAfter.map { whole($0) + "s" } ?? "none") wait=\(whole(wait))s account=\(active ? "active" : "spare")"
    if !active { line += " left=" + (left.map { whole($0 / 60) + "m" } ?? "unknown") }
    line += " lilt-1h=\(requests) lilt-1h-all=\(allRequests)"
    return line + (pausedAll ? " all-paused" : "")
}

/// How the renewal that followed a refused token went (`UsagePolling.renewsAfterRefusal`).
public enum RefusalRenewal: String, Sendable {
    /// A fresh token was saved and quota was read again with it.
    case renewed
    /// The token endpoint refused the refresh token too.
    case rejected
    /// No answer: the network, the token endpoint, or local storage failed.
    case failed
}

/// One `usage-401` line for `switches.log`: the usage endpoint refused a spare login's token, Lilt renewed it at once,
/// and this is what came of it. `expires-in` is how long the refused token still had (Lilt never sends one it knows
/// has expired, so any value here means it was revoked early). `renewal=rejected` means the refresh token is dead too:
/// the login was renewed somewhere else or signed out, and only a new authorization helps. `renewal=renewed read=ok`
/// means only the access token had been revoked, and the account is back. `read=refused` means even a fresh token was
/// refused, which points at the account rather than the token. Words and numbers only; no names, ids or secrets.
public func tokenRefusal(renewal: RefusalRenewal, read: UsageFailure?, expiresIn: TimeInterval?) -> String {
    var line = "expires-in=" + (expiresIn.map { String(format: "%.0f", max(0, $0 / 60)) + "m" } ?? "unknown") + " renewal=\(renewal.rawValue)"
    guard renewal == .renewed else { return line }
    switch read {
    case nil: line += " read=ok"
    case .authentication?: line += " read=refused"
    case .permission?: line += " read=no-scope"
    case .rateLimited?: line += " read=429"
    default: line += " read=failed"
    }
    return line
}
