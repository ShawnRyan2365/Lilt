import Foundation

/// Usage requests start at least `gap` apart, whichever account they are for. A request reserves its start slot
/// before it waits, so they queue in order, and nothing is held while one is out: a slow answer for one account no
/// longer holds up the next account's request, nor anything else that is going on.
public actor RequestSpacing {
    private var next = ContinuousClock.now
    public init() {}
    public func reserve(gap: TimeInterval) async {
        guard gap > 0 else { return }
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot.advanced(by: .milliseconds(Int64(gap * 1000)))
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}

public extension Duration {
    /// The duration in seconds, for timings that end up in a log line or a reaction budget.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// One line for `switches.log` about an automatic hand-off: why it started, how old the reading was, how long the
/// candidate reads and the write took. Numbers only; no names, ids or secrets.
public func relayTiming(paced: Bool, readingAge: TimeInterval, confirm: TimeInterval, write: TimeInterval) -> String {
    "trigger=\(paced ? "pace" : "threshold") age=\(String(format: "%.0f", max(0, readingAge)))s "
        + "confirm=\(String(format: "%.1f", confirm))s write=\(String(format: "%.1f", write))s"
}
