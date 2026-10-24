import Foundation
import CoreFoundation

public extension UsageParser {
    static let statusLineSource = "Claude Code 状态栏"

    /// The record Lilt's status line script keeps: `{"at": <epoch seconds>, "rate_limits": {...}}`, where each window is
    /// `{"used_percentage": 0...100, "resets_at": <epoch seconds>}` as Claude Code hands it to its status line.
    /// Nil when the record carries no window Lilt can use.
    static func parseStatusLine(_ data: Data) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let at = (root["at"] as? NSNumber)?.doubleValue, at.isFinite, at > 0,
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let object = limits[key] as? [String: Any], let used = object["used_percentage"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else { return nil }
            let reset = (object["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(used: min(100, max(0, used.doubleValue)), resetsAt: reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return UsageSnapshot(fiveHour: five, sevenDay: seven, sampledAt: Date(timeIntervalSince1970: at), source: statusLineSource)
    }
}

public extension UsageSnapshot {
    /// Whether this reading and `other` are the same account's: every window both know of that has not reset yet by
    /// `other`'s reckoning resets at the same moment, and there is at least one such window. A status line reading
    /// carries no account name, so this is how one from a session still on the previous account is told apart: two
    /// accounts' windows almost never reset within minutes of each other.
    func sharesWindows(with other: UsageSnapshot, at now: Date, tolerance: TimeInterval = 600) -> Bool {
        var compared = false
        for (mine, theirs) in [(fiveHour, other.fiveHour), (sevenDay, other.sevenDay)] {
            guard let a = mine?.resetsAt, let b = theirs?.resetsAt, b > now else { continue }
            if abs(a.timeIntervalSince(b)) > tolerance { return false }
            compared = true
        }
        return compared
    }
    /// This reading, with any window that `earlier` already saw further used kept at the earlier figure. Quota spent in
    /// a window does not come back before the window resets, so a lower figure for the same window is a session telling
    /// what it saw at its own last request. Idle sessions hand their status line over whenever they redraw, and with
    /// several sessions open such figures arrive between fresh ones all the time (on 2026-10-23: 73, then 57, then 74).
    /// Taken as they came, they made the account look emptier than it was and broke the pace that starts a hand-off early.
    func keepingHigher(than earlier: UsageSnapshot, tolerance: TimeInterval = 600) -> UsageSnapshot {
        func merged(_ mine: UsageWindow?, _ theirs: UsageWindow?) -> UsageWindow? {
            guard var mine, let theirs, let a = mine.resetsAt, let b = theirs.resetsAt,
                  abs(a.timeIntervalSince(b)) <= tolerance, theirs.used > mine.used else { return mine }
            mine.used = theirs.used
            return mine
        }
        var result = self
        result.fiveHour = merged(fiveHour, earlier.fiveHour)
        result.sevenDay = merged(sevenDay, earlier.sevenDay)
        return result
    }
}

/// How fast the account in use is being spent, so a hand-off can start before the threshold instead of after it.
/// Readings arrive some seconds apart and a hand-off takes a few more; a busy account, several sessions at once, can
/// spend several points in that time and run into its limit, which stops the session mid-task.
public enum UsagePace {
    /// How far ahead the pace is projected: the time readings take to arrive plus the time a hand-off takes.
    public static let lead: TimeInterval = 60
    /// The pace is measured over at least this long, so one reading rounded up a point does not count as a burst.
    public static let minimumSpan: TimeInterval = 30
    /// Readings older than this say little about the pace now.
    public static let span: TimeInterval = 600
    /// However fast the pace, a hand-off never starts more than this many points above the threshold.
    public static let maxMargin: Double = 10

    /// True when a window of `latest` would reach `threshold` within `lead`, at the faster of two paces: the one since
    /// the oldest of `earlier` within `span`, and the one since the most recent reading at least `minimumSpan` older.
    /// The long one alone lags a burst: several sessions starting at once on an account that sat idle for minutes.
    /// Only readings of the same window count: one from before a reset says nothing about now.
    public static func nearing(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], threshold: Thresholds, at now: Date, lifetime: TimeInterval) -> Bool {
        for (window, pick, limit) in [(latest.fiveHour, \UsageSnapshot.fiveHour, threshold.fiveHour), (latest.sevenDay, \UsageSnapshot.sevenDay, threshold.sevenDay)] {
            guard let remaining = latest.validRemaining(window, at: now, lifetime: lifetime) else { continue }
            let bases = earlier.filter {
                let gap = latest.sampledAt.timeIntervalSince($0.sampledAt)
                return gap >= minimumSpan && gap <= span && sameWindow($0[keyPath: pick], window)
            }
            let rate = [bases.min { $0.sampledAt < $1.sampledAt }, bases.max { $0.sampledAt < $1.sampledAt }].compactMap { base -> Double? in
                guard let base, let before = base[keyPath: pick]?.remaining else { return nil }
                return (before - remaining) / latest.sampledAt.timeIntervalSince(base.sampledAt)
            }.max()
            guard let rate, rate > 0 else { continue }
            if remaining - min(maxMargin, rate * lead) <= limit + 0.000001 { return true }
        }
        return false
    }
    /// An earlier reading with no reset time was taken before the window started, so it is the same window's start.
    private static func sameWindow(_ earlier: UsageWindow?, _ latest: UsageWindow?) -> Bool {
        guard let earlier, let latest else { return false }
        guard let a = earlier.resetsAt else { return true }
        guard let b = latest.resetsAt else { return false }
        return abs(a.timeIntervalSince(b)) <= 600
    }
}
