import Foundation
import CoreFoundation

public extension UsageParser {
    static let statusLineSource = "Claude Code 状态栏"

    /// Parse both the current per-event spool record and the legacy single-slot record. Values outside 0...100 stay
    /// untouched: `UsageWindow.remaining` treats them as unknown rather than turning them into empty or full quota.
    private static func statusLineParts(_ data: Data) -> (id: String?, scope: String?, snapshot: UsageSnapshot)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let atNumber = root["at"] as? NSNumber, CFGetTypeID(atNumber) != CFBooleanGetTypeID(),
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let at = atNumber.doubleValue
        guard at.isFinite, at > 0 else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let object = limits[key] as? [String: Any], let used = object["used_percentage"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else { return nil }
            let resetNumber = object["resets_at"] as? NSNumber
            let reset = resetNumber.flatMap { number in
                CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
                    ? Date(timeIntervalSince1970: number.doubleValue) : nil
            }
            return UsageWindow(used: used.doubleValue, resetsAt: reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        let snapshot = UsageSnapshot(fiveHour: five, sevenDay: seven,
                                     sampledAt: Date(timeIntervalSince1970: at), source: statusLineSource)
        return (root["id"] as? String, root["scope"] as? String, snapshot)
    }

    static func parseStatusLineEvent(_ data: Data) -> LiveUsageEvent? {
        guard let parts = statusLineParts(data), let id = parts.id, !id.isEmpty,
              let scope = parts.scope, !scope.isEmpty else { return nil }
        return LiveUsageEvent(id: id, scope: scope, snapshot: parts.snapshot)
    }

    /// Compatibility for records written before every status-line event had its own identity and scope.
    static func parseStatusLine(_ data: Data) -> UsageSnapshot? {
        statusLineParts(data)?.snapshot
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
    /// A figure outside 0–100 is no evidence either way: it never replaces a valid one, and a valid earlier figure
    /// stands in for it, so one malformed report cannot make a window unknown or empty.
    func keepingHigher(than earlier: UsageSnapshot, tolerance: TimeInterval = 600) -> UsageSnapshot {
        func merged(_ mine: UsageWindow?, _ theirs: UsageWindow?) -> UsageWindow? {
            guard var mine, let theirs, let a = mine.resetsAt, let b = theirs.resetsAt,
                  abs(a.timeIntervalSince(b)) <= tolerance, theirs.remaining != nil else { return mine }
            if mine.remaining == nil || theirs.used > mine.used { mine.used = theirs.used }
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
///
/// Until 0.2.5 a hand-off started at most ten points early, and only on readings at least 30 seconds apart; the first
/// 30 seconds of a burst had no pace at all. A second, short channel now sees a burst within seconds. From 0.2.5 to
/// 0.3.9 the margin was one minute's spend at the measured pace with no cap, which handed off with 20–30% left; how
/// many points early a pace hands off is now the user's tiers (`EarlyHandOff`).
public enum UsagePace {
    /// The span a pace is expressed over: points a minute.
    public static let lead: TimeInterval = 60
    /// The long channel needs two readings at least this far apart, so one figure rounded up is not a burst.
    public static let minimumSpan: TimeInterval = 30
    /// Readings older than this say little about the pace now.
    public static let span: TimeInterval = 600
    /// The short channel: readings 5–10 seconds back, at least three of them, with at least two actual drops.
    public static let burstMinimumSpan: TimeInterval = 5
    public static let burstMaximumSpan: TimeInterval = 10
    public static let burstSampleCount = 3
    /// What an account taking over must have above its threshold when nothing measured says more. Without it an
    /// account with 1.5% left could take the baton at a 1% threshold and be left again a request later.
    public static let initialCandidateMargin: Double = 2
    /// One reading right after a switch is counted at most this much as the cost of switching, so one odd figure
    /// cannot rule out every account.
    public static let maximumSwitchAllowance: Double = 10

    /// What an account taking over must have above its threshold: the points the account in use hands off early at
    /// its pace (`earlyPoints`), plus what the last switch was seen to cost, and never less than `initialCandidateMargin`.
    /// Less than the early margin and the same sessions would set off another hand-off at once.
    public static func candidateMargin(pace: Thresholds, allowance: Thresholds) -> Thresholds {
        Thresholds(fiveHour: max(initialCandidateMargin, pace.fiveHour + allowance.fiveHour),
                   sevenDay: max(initialCandidateMargin, pace.sevenDay + allowance.sevenDay))
    }

    /// How much less an account had at its first reading after taking over than at the reading it was chosen on.
    /// Sessions that had not followed the switch, or another machine, spent it meanwhile. It is kept as a margin for
    /// the next hand-off and never enters the pace: as a rate, one jump would look like a burst and set off another
    /// switch straight away.
    public static func switchAllowance(confirmed: UsageSnapshot, first: UsageSnapshot) -> Thresholds {
        func jump(_ before: UsageWindow?, _ after: UsageWindow?) -> Double {
            guard let before, let after, sameWindow(before, after), let had = before.remaining, let has = after.remaining else { return 0 }
            return min(maximumSwitchAllowance, max(0, had - has))
        }
        return Thresholds(fiveHour: jump(confirmed.fiveHour, first.fiveHour), sevenDay: jump(confirmed.sevenDay, first.sevenDay))
    }

    /// Seconds until the tighter window reaches its threshold at the measured pace, counted from `now`. Nil when no
    /// pace is measured: an idle account is not about to run out.
    public static func secondsToThreshold(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], threshold: Thresholds,
                                          at now: Date, lifetime: TimeInterval) -> TimeInterval? {
        let perSecond = projectedMargin(latest, after: earlier, at: now, lifetime: lifetime, reactionTime: 1)
        var soonest: TimeInterval?
        for (window, limit, rate) in [(latest.fiveHour, threshold.fiveHour, perSecond.fiveHour), (latest.sevenDay, threshold.sevenDay, perSecond.sevenDay)] {
            guard rate > 0, let remaining = latest.validRemaining(window, at: now, lifetime: lifetime) else { continue }
            let seconds = max(0, (remaining - limit) / rate - now.timeIntervalSince(latest.sampledAt))
            soonest = min(soonest ?? seconds, seconds)
        }
        return soonest
    }

    /// The points each window may spend during `reactionTime` at the faster of the two channels.
    public static func projectedMargin(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], at now: Date,
                                       lifetime: TimeInterval, reactionTime: TimeInterval = lead) -> Thresholds {
        Thresholds(fiveHour: margin(latest, after: earlier, window: latest.fiveHour, pick: \.fiveHour,
                                    at: now, lifetime: lifetime, reactionTime: reactionTime),
                   sevenDay: margin(latest, after: earlier, window: latest.sevenDay, pick: \.sevenDay,
                                    at: now, lifetime: lifetime, reactionTime: reactionTime))
    }

    /// Points each window is being spent a minute, at the faster of the two channels; zero where no pace is measured.
    public static func perMinute(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], at now: Date,
                                 lifetime: TimeInterval) -> Thresholds {
        projectedMargin(latest, after: earlier, at: now, lifetime: lifetime, reactionTime: lead)
    }

    /// How many points above its threshold each window hands off: its pace a minute put through `rules`.
    public static func earlyPoints(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], at now: Date,
                                   lifetime: TimeInterval, rules: EarlyHandOff) -> Thresholds {
        rules.points(byWindow: perMinute(latest, after: earlier, at: now, lifetime: lifetime))
    }

    /// True when a window of `latest` is within its early margin of its threshold (`earlyPoints`). Only readings of
    /// the same window count: one from before a reset says nothing about now.
    public static func nearing(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], threshold: Thresholds,
                               at now: Date, lifetime: TimeInterval, rules: EarlyHandOff = .standard) -> Bool {
        trigger(latest, after: earlier, threshold: threshold, at: now, lifetime: lifetime, rules: rules)?.due == true
    }

    /// The window closest to its early trigger, for `switches.log`: what it had left, its pace a minute and the points
    /// it hands off early. Nil when no window has a measured pace.
    public static func trigger(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], threshold: Thresholds,
                               at now: Date, lifetime: TimeInterval, rules: EarlyHandOff)
        -> (left: Double, perMinute: Double, early: Double, due: Bool)? {
        let rate = perMinute(latest, after: earlier, at: now, lifetime: lifetime)
        var closest: (left: Double, perMinute: Double, early: Double, distance: Double)?
        var due = false
        for (window, limit, pace) in [(latest.fiveHour, threshold.fiveHour, rate.fiveHour),
                                      (latest.sevenDay, threshold.sevenDay, rate.sevenDay)] {
            guard pace > 0, let remaining = latest.validRemaining(window, at: now, lifetime: lifetime) else { continue }
            let early = rules.points(perMinute: pace)
            let distance = remaining - early - limit
            if early > 0 && distance <= 0.000001 { due = true }
            if let current = closest, current.distance <= distance { continue }
            closest = (remaining, pace, early, distance)
        }
        return closest.map { (left: $0.left, perMinute: $0.perMinute, early: $0.early, due: due) }
    }

    private static func margin(_ latest: UsageSnapshot, after earlier: [UsageSnapshot], window: UsageWindow?,
                               pick: KeyPath<UsageSnapshot, UsageWindow?>, at now: Date, lifetime: TimeInterval,
                               reactionTime: TimeInterval) -> Double {
        guard let remaining = latest.validRemaining(window, at: now, lifetime: lifetime) else { return 0 }
        let matching = earlier.filter { sample in
            sample.sampledAt < latest.sampledAt && sameWindow(sample[keyPath: pick], window)
        }.sorted { $0.sampledAt < $1.sampledAt }
        let longBases = matching.filter {
            let gap = latest.sampledAt.timeIntervalSince($0.sampledAt)
            return gap >= minimumSpan && gap <= span
        }
        var rates = [longBases.first, longBases.last].compactMap { base -> Double? in
            guard let base, let before = base[keyPath: pick]?.remaining else { return nil }
            return (before - remaining) / latest.sampledAt.timeIntervalSince(base.sampledAt)
        }
        for (index, base) in matching.enumerated() {
            let gap = latest.sampledAt.timeIntervalSince(base.sampledAt)
            guard gap >= burstMinimumSpan, gap <= burstMaximumSpan else { continue }
            var seen = Set<TimeInterval>()
            let samples = ([base] + matching.suffix(from: index + 1) + [latest]).filter {
                seen.insert($0.sampledAt.timeIntervalSince1970).inserted
            }
            guard samples.count >= burstSampleCount else { continue }
            let values = samples.compactMap { $0[keyPath: pick]?.remaining }
            guard values.count == samples.count, let first = values.first else { continue }
            let drops = zip(values, values.dropFirst()).map(-)
            guard drops.filter({ $0 > 0.000001 }).count >= 2 else { continue }
            rates.append((first - remaining) / gap)
        }
        let seconds = reactionTime.isFinite ? max(0, reactionTime) : lead
        return max(0, rates.max() ?? 0) * seconds
    }

    /// An earlier reading with no reset time was taken before the window started, so it is the same window's start.
    private static func sameWindow(_ earlier: UsageWindow?, _ latest: UsageWindow?) -> Bool {
        guard let earlier, let latest else { return false }
        guard let a = earlier.resetsAt else { return true }
        guard let b = latest.resetsAt else { return false }
        return abs(a.timeIntervalSince(b)) <= 600
    }
}
