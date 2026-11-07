import Foundation

/// Who a 429 from the usage endpoint holds back. Reports from other users of the endpoint say it counts requests per
/// access token, so one account refused says nothing about the others: pausing every account on the first 429 froze
/// the whole list, manual refresh included, for as long as the server asked (up to 75 minutes). That account waits
/// out its own backoff instead. Refusals of two different accounts close together, with no answer from the endpoint
/// in between, look like a limit on the whole connection; only then does every read wait.
public struct UsageRateLimit: Sendable {
    /// Refusals further apart than this are not taken as one limit.
    public static let window: TimeInterval = 600
    public private(set) var pausedUntil = Date.distantPast
    private var refusals: [UUID: Date] = [:]
    public init() {}

    /// The endpoint refused `account` with a 429 and asked it to wait until `until`. True when every read now waits.
    @discardableResult
    public mutating func refused(_ account: UUID, until: Date, at now: Date) -> Bool {
        refusals = refusals.filter { now.timeIntervalSince($0.value) < Self.window }
        refusals[account] = now
        guard refusals.count >= 2 else { return false }
        pausedUntil = max(pausedUntil, until)
        return true
    }
    /// An account's quota came back, so the connection itself is not being refused.
    public mutating func answered() { refusals.removeAll() }
    public func paused(at now: Date) -> Bool { pausedUntil > now }
}
