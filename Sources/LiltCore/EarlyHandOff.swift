import Foundation

/// One rule of the early hand-off: while the account in use spends at least `perMinute` points a minute in a window,
/// relay hands off once that window is within `points` points of its threshold.
public struct EarlyHandOffTier: Codable, Equatable, Hashable, Sendable {
    public var perMinute: Double
    public var points: Double
    public init(perMinute: Double, points: Double) {
        self.perMinute = EarlyHandOff.perMinuteRange.clamp(perMinute)
        self.points = EarlyHandOff.pointsRange.clamp(points)
    }
    /// A hand-edited or older file cannot carry a speed of zero (which would hand off early with no pace at all) or a
    /// margin out of range: values are clamped on the way in, as the initializer does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(perMinute: try container.decode(Double.self, forKey: .perMinute),
                  points: try container.decode(Double.self, forKey: .points))
    }
}

/// How much earlier than the threshold relay hands off while the account in use is being spent fast, as tiers the user
/// sets in Settings: "spending at least X points a minute → hand off Y points early".
///
/// Until 0.3.9 the early margin was one minute's spend at the fastest measured pace, with no cap. Sessions that finish a
/// turn together report within seconds of each other, and the burst channel turned a four-point drop over eight seconds
/// into thirty points a minute, so relay left accounts with 20–30% unspent at a 1% threshold. In `switches.log` of
/// 2026-11-12/13 nearly every automatic switch said `trigger=pace`, while the switch itself took one to four seconds.
/// Tiers keep the margin bounded and in the user's hands; the pace measurement itself is unchanged.
public struct EarlyHandOff: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var tiers: [EarlyHandOffTier]
    public init(enabled: Bool = true, tiers: [EarlyHandOffTier]) { self.enabled = enabled; self.tiers = tiers }
    /// The defaults: at most ten points early, and nothing early below five points a minute.
    public static let standard = EarlyHandOff(tiers: [EarlyHandOffTier(perMinute: 5, points: 2),
                                                      EarlyHandOffTier(perMinute: 10, points: 5),
                                                      EarlyHandOffTier(perMinute: 20, points: 10)])
    /// A speed below one point a minute is no burst, and a speed of zero would fire without any pace.
    public static let perMinuteRange: ClosedRange<Double> = 1...100
    public static let pointsRange: ClosedRange<Double> = 0...30

    /// The points a window hands off early at `rate` points a minute: the largest margin among the tiers the rate
    /// reaches, so a faster pace never hands off later than a slower one whatever order the tiers are in. Zero when
    /// switched off, when no pace is measured, or below every tier.
    public func points(perMinute rate: Double) -> Double {
        guard enabled, rate.isFinite, rate > 0 else { return 0 }
        return tiers.filter { rate + 0.000001 >= $0.perMinute }.map(\.points).max() ?? 0
    }
    public func points(byWindow rates: Thresholds) -> Thresholds {
        Thresholds(fiveHour: points(perMinute: rates.fiveHour), sevenDay: points(perMinute: rates.sevenDay))
    }
    /// The largest margin any tier allows, for the settings caption.
    public var maximum: Double { enabled ? tiers.map(\.points).max() ?? 0 : 0 }
}

extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { value.isFinite ? Swift.min(upperBound, Swift.max(lowerBound, value)) : lowerBound }
}
