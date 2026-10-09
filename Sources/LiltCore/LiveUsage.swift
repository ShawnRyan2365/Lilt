import Foundation

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
}
