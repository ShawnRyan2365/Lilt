import SwiftUI

// Quota indicators. The ruler is purely visual: the number and its meaning are always written
// next to them, so they are hidden from accessibility.

/// How a remaining-quota reading should be presented. `unknown` is its own state: neither healthy nor empty.
enum QuotaLevel: Sendable, Equatable {
    case unknown, healthy, low, reached

    /// `remaining` is a percentage (0...100). At or below `threshold` the relay rule applies; at or below 10% it is low.
    init(remaining: Double?, threshold: Double) {
        guard let remaining else { self = .unknown; return }
        self = remaining <= threshold + 0.000001 ? .reached : remaining <= 10 ? .low : .healthy
    }

    /// Healthy readings are plain ink; colour appears only when something needs attention.
    var tone: Tone {
        switch self { case .unknown, .healthy: .neutral; case .low: .warning; case .reached: .danger }
    }
    /// Words for the state, so colour is never the only signal. `nil` when there is nothing to flag.
    var label: String? {
        switch self { case .unknown, .healthy: nil; case .low: "偏低"; case .reached: "已到阈值" }
    }
    /// Lit marks for a window: its own colour while healthy, the state's colour once it needs attention.
    func fill(_ series: Paint?) -> AnyShapeStyle {
        tone == .neutral ? series.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Tokens.ink) : tone.solid
    }
}

/// A quota window's colour as a small dot beside its name: the key that ties rings, hands and rulers to "5 小时" or "7 天".
struct SeriesDot: View {
    let series: Paint
    var size: CGFloat = 7
    var body: some View { Circle().fill(series).frame(width: size, height: size).accessibilityHidden(true) }
}

/// The quota ruler, adapted from the Progress ticks block: a row of thin ticks, ink for what is left,
/// pale for what is used. Tick heights follow a slow wave (Lilt's mark is a waveform), and a change
/// sweeps across the ticks instead of all of them moving at once.
struct TickRuler: View {
    var fraction: Double?
    var tone: Tone = .neutral
    /// The window's colour for lit ticks while `tone` is neutral; ink when nil.
    var series: Paint?
    var count = 36
    var height: CGFloat = 44
    /// The widest a tick gets. Small rulers use hairline ticks, like the Time scrubber's.
    var tickWidth: CGFloat = 5
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Ticks start empty and fill once when the ruler comes on screen.
    @State private var appeared = false

    private var filled: Int {
        guard appeared || reduceMotion, let fraction, fraction > 0 else { return 0 }
        return min(count, max(1, Int((min(1, fraction) * Double(count)).rounded())))
    }

    // Two shapes, lit and unlit ticks, rather than a view per tick: every account row has two rulers, and with twenty-odd
    // accounts a view per tick meant well over a thousand views laid out again on every redraw of the window.
    var body: some View {
        ZStack {
            if fraction == nil {
                // Unknown is a row of dots (Particles), so it never reads as an empty ruler.
                RulerTicks(count: count, tickWidth: tickWidth, filled: 0, lit: false, dots: true).fill(Tokens.trackOff)
            } else {
                RulerTicks(count: count, tickWidth: tickWidth, filled: Double(filled), lit: false)
                    .fill(Tokens.trackOff)
                    .animation(reduceMotion ? nil : Motion.snap, value: filled)
                RulerTicks(count: count, tickWidth: tickWidth, filled: Double(filled), lit: true)
                    .fill(tone == .neutral ? series.map { AnyShapeStyle($0) } ?? tone.solid : tone.solid)
                    .animation(reduceMotion ? nil : Motion.snap, value: filled)
            }
        }
        .frame(height: height, alignment: .bottom)
        .opacity(dimmed ? 0.4 : 1)
        .motion(Motion.fade, value: dimmed)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }
}

/// The ticks of a `TickRuler` as one shape: the lit ones, or the unlit ones. Ticks share the width evenly, 3 points
/// apart, bottom-aligned, with heights on a slow wave; an unlit tick is 0.78 of its lit height. `filled` animates, so a
/// change still sweeps across the ruler one tick after another, each growing as the sweep passes it.
private struct RulerTicks: Shape {
    var count: Int
    var tickWidth: CGFloat
    var filled: Double
    var lit: Bool
    /// The unknown state: a dot in the middle of each tick's place.
    var dots = false
    var animatableData: Double {
        get { filled }
        set { filled = newValue }
    }
    /// 0.72...1.0 of the full height.
    private func wave(_ index: Int) -> CGFloat {
        let t = Double(index) / Double(max(1, count - 1))
        return 0.86 + 0.14 * CGFloat(sin(t * .pi * 2.4 + 0.6))
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0 else { return path }
        let spacing: CGFloat = 3
        let slot = max(0, (rect.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        for index in 0..<count {
            let left = rect.minX + CGFloat(index) * (slot + spacing)
            if dots {
                let size = min(3, slot)
                path.addEllipse(in: CGRect(x: left + (slot - size) / 2, y: rect.midY - size / 2, width: size, height: size))
                continue
            }
            let on = CGFloat(min(1, max(0, filled - Double(index))))
            guard (on > 0.5) == lit else { continue }
            let width = min(tickWidth, slot)
            let height = rect.height * wave(index) * (0.78 + 0.22 * on)
            path.addRoundedRect(in: CGRect(x: left + (slot - width) / 2, y: rect.maxY - height, width: width, height: height),
                                cornerSize: CGSize(width: width / 2, height: min(width, height) / 2))
        }
        return path
    }
}

/// A large figure that rolls between values instead of snapping. An unknown value reads as a quiet
/// word, never as a number-sized dash.
struct BigNumeral: View {
    let value: Double?
    var size: CGFloat = 48
    var placeholder = "未知"
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if let value {
                Text(value.formatted(.number.precision(.fractionLength(0...1))))
                    .font(Typo.numeral(size)).monospacedDigit().tracking(-size * 0.04)
                    .foregroundStyle(Tokens.ink)
                    .contentTransition(.numericText(value: value))
                // The unit is part of the figure. Faint at 0.42 of the number read as a separate mark.
                Text("%").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(Tokens.muted)
            } else {
                Text(placeholder).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Tokens.muted)
            }
        }
        .frame(height: size * 1.02, alignment: .bottomLeading)
        .motion(Motion.settle, value: value)
    }
}

/// One quota window. Reading order: what it is, how much is left, the ruler, when it resets.
/// `compact` is for the menu bar panel.
struct QuotaReadout: View {
    /// "5 小时" or "7 天".
    let title: String
    /// Remaining percentage to show, or `nil` when there is nothing to show.
    let remaining: Double?
    var threshold: Double = 1
    /// The age of an old reading ("3 小时前的读数"). When set, the value stays visible but recedes, and it is not
    /// flagged as low or at threshold.
    var staleNote: String?
    private var stale: Bool { staleNote != nil }
    /// Shown in place of the number when `remaining` is nil.
    var placeholder = "未知"
    /// Reset time, or what to do when there is none.
    var footnote: String?
    /// The window's colour, shown as a dot by the title and on the lit ticks.
    var series: Paint?
    var compact = false

    private var level: QuotaLevel { QuotaLevel(remaining: remaining, threshold: threshold) }
    private var flag: (text: String, tone: Tone)? {
        if let staleNote, remaining != nil { return (staleNote, .neutral) }
        return level.label.map { ($0, level.tone) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 6) {
                if let series { SeriesDot(series: series) }
                Text(remaining == nil ? title : "\(title)剩余").font(Typo.caption).foregroundStyle(Tokens.muted)
                if let flag {
                    Pill(text: flag.text, style: flag.tone == .neutral ? .plain : .soft(flag.tone))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 18)
            BigNumeral(value: remaining, size: compact ? 30 : 48, placeholder: placeholder)
                .opacity(stale ? 0.55 : 1)
            TickRuler(fraction: remaining.map { $0 / 100 }, tone: stale ? .neutral : level.tone, series: series, count: compact ? 22 : 36, height: compact ? 22 : 44, dimmed: stale)
            if let footnote { Text(footnote).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1) }
        }
        .motion(Motion.fade, value: stale)
        .motion(Motion.pop, value: flag?.text)
    }
}

/// One quota window as the relay track draws it.
struct RingReading: Equatable, Sendable {
    /// Remaining percentage, or nil when it is not known.
    var remaining: Double?
    var level: QuotaLevel = .unknown
    /// How far the window has run, 0...1, from its start to its reset; nil when the reset time is not known.
    var elapsed: Double?
}

/// An account's two windows as concentric rings of ticks around its sprite, adapted from the Wheel and
/// Range dial blocks and laid out like a clock face: the outer ring is the 5-hour window (fine minute
/// ticks, where a minute hand reaches), the inner ring the 7-day window (heavier hour ticks). Each ring
/// lights from 12 o'clock clockwise for what is left; the quarter ticks are longer, as on a dial.
/// Unknown is a ring of dots, so it never reads as empty. A change sweeps round instead of jumping.
struct WindowRings: View {
    var outer: RingReading
    var inner: RingReading
    var diameter: CGFloat
    var dimmed = false
    /// A stopped account: both rings as dots.
    var muted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rings start empty and sweep in once when they come on screen.
    @State private var appeared = false

    var body: some View {
        let width = max(1.2, diameter * 0.02)
        let heavy = max(1.8, diameter * 0.034)
        let outerEdge = diameter / 2 - heavy / 2
        let outerLength = diameter * 0.075
        let innerEdge = outerEdge - outerLength - diameter * 0.04
        ZStack {
            ring(outer, series: Tokens.fiveHour, count: 40, edge: outerEdge, length: outerLength, width: width)
            ring(inner, series: Tokens.sevenDay, count: 28, edge: innerEdge, length: diameter * 0.05, width: heavy)
        }
        .frame(width: diameter, height: diameter)
        .opacity(dimmed || muted ? 0.4 : 1)
        .motion(Motion.fade, value: dimmed)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func ring(_ reading: RingReading, series: Paint, count: Int, edge: CGFloat, length: CGFloat, width: CGFloat) -> some View {
        let quarter = count / 4
        if muted || reading.remaining == nil {
            RingTicks(count: count, lit: Double(count), edge: edge, length: length, width: width, dots: true).fill(Tokens.trackOff)
        } else {
            let fraction = min(1, max(0, (reading.remaining ?? 0) / 100))
            let lit = appeared || reduceMotion ? (fraction > 0 ? max(1, (fraction * Double(count)).rounded()) : 0) : 0
            RingTicks(count: count, lit: Double(count), edge: edge, length: length, width: width, major: quarter)
                .stroke(Tokens.trackOff, style: StrokeStyle(lineWidth: width, lineCap: .round))
            RingTicks(count: count, lit: lit, edge: edge, length: length, width: width, major: quarter)
                // An old reading keeps its window's colour, so the rings stay matched to the legend; it only recedes.
                .stroke(reading.level.fill(series), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .animation(reduceMotion ? nil : Motion.settle, value: lit)
        }
    }
}

/// `lit` ticks of a ring, from 12 o'clock clockwise, as radial strokes (or dots) ending at `edge`.
/// `lit` is animatable: the tick at the moving edge grows in, so the band sweeps.
private struct RingTicks: Shape {
    var count: Int
    var lit: Double
    var edge: CGFloat
    var length: CGFloat
    var width: CGFloat
    /// Every `major`-th tick, starting at 12, reaches further in, like a dial's quarter marks.
    var major = 0
    var dots = false

    var animatableData: Double {
        get { lit }
        set { lit = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let shown = min(Double(count), lit)
        for index in 0..<Int(shown.rounded(.up)) {
            let grow = min(1, shown - Double(index))
            // Screen angles run clockwise from +x; 12 o'clock is -90°.
            let angle = (-90 + 360 * Double(index) / Double(count)) * .pi / 180
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            if dots {
                let r = edge - length / 2
                let p = CGPoint(x: center.x + direction.x * r, y: center.y + direction.y * r)
                let d = max(1.6, width * 1.1)
                path.addEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            } else {
                let reach = (major > 0 && index % major == 0 ? length * 1.35 : length) * grow
                path.move(to: CGPoint(x: center.x + direction.x * edge, y: center.y + direction.y * edge))
                path.addLine(to: CGPoint(x: center.x + direction.x * (edge - reach), y: center.y + direction.y * (edge - reach)))
            }
        }
        return path
    }
}

/// When an account's windows refresh, as a small clock. The long minute hand is the 5-hour window and
/// the short hour hand the 7-day window, in the same colours as their rings. Each hand goes once round
/// clockwise over its window and the window refreshes when the hand is back at 12, which is marked.
/// A hand turns to the warning or danger colour when its window is low or used up, so the hand to
/// wait for is the coloured one. A hand whose reset time is unknown is left out.
struct ResetClock: View {
    var fiveHour: RingReading
    var sevenDay: RingReading
    var size: CGFloat = 22
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The hands start at 12 and swing to the time once, like a watch being set.
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle().fill(Tokens.fill)
            // Quarter marks, as on a dial; the one at 12 is the reset point and stands out.
            ForEach(0..<4, id: \.self) { quarter in
                Capsule().fill(quarter == 0 ? AnyShapeStyle(Tokens.muted) : AnyShapeStyle(Tokens.trackOff))
                    .frame(width: quarter == 0 ? 2 : 1.5, height: size * (quarter == 0 ? 0.16 : 0.1))
                    .offset(y: -size * (quarter == 0 ? 0.36 : 0.39))
                    .rotationEffect(.degrees(Double(quarter) * 90))
            }
            if let elapsed = sevenDay.elapsed {
                hand(elapsed, length: size * 0.25, width: max(2.6, size * 0.1), style: sevenDay.level.fill(Tokens.sevenDay), delay: 0.04)
            }
            if let elapsed = fiveHour.elapsed {
                hand(elapsed, length: size * 0.38, width: max(1.8, size * 0.065), style: fiveHour.level.fill(Tokens.fiveHour), delay: 0)
            }
            Circle().fill(Tokens.ink).frame(width: size * 0.15, height: size * 0.15)
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.5 : 1)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }

    private func hand(_ elapsed: Double, length: CGFloat, width: CGFloat, style: AnyShapeStyle, delay: Double) -> some View {
        let degrees = appeared || reduceMotion ? 360 * min(1, max(0, elapsed)) : 0
        return Capsule().fill(style)
            .frame(width: width, height: length + width / 2)
            .offset(y: -(length - width / 2) / 2)
            .rotationEffect(.degrees(degrees))
            .animation(reduceMotion ? nil : Motion.settle.delay(delay), value: degrees)
    }
}

/// One quota window in a list row, adapted from the Time scrubber: the figure and when the window
/// refreshes share one line, a short ruler runs underneath. Rows stack these in fixed columns so the
/// rulers line up and can be compared down the list.
struct QuotaCell: View {
    /// Remaining percentage, or nil when it is not known.
    let remaining: Double?
    /// Shown in place of the figure when `remaining` is nil.
    var placeholder = "未知"
    /// When the window refreshes ("3 小时后"), or what to do about it.
    var caption: String?
    var threshold: Double = 1
    /// The window's colour for the lit ticks.
    var series: Paint?
    var dimmed = false

    private var level: QuotaLevel { QuotaLevel(remaining: remaining, threshold: threshold) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let remaining {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(remaining.formatted(.number.precision(.fractionLength(0...1))))
                            .font(.system(size: 15, weight: .medium)).monospacedDigit()
                            .foregroundStyle(dimmed || level.tone == .neutral ? AnyShapeStyle(Tokens.ink) : level.tone.text)
                            .contentTransition(.numericText(value: remaining))
                        Text("%").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.muted)
                    }
                } else {
                    Text(placeholder).font(Typo.captionStrong).foregroundStyle(Tokens.muted)
                }
                Spacer(minLength: 4)
                if let caption {
                    Text(caption).font(Typo.caption).monospacedDigit().foregroundStyle(Tokens.muted)
                        .contentTransition(.opacity)
                }
            }
            .lineLimit(1)
            .frame(height: 18)
            TickRuler(fraction: remaining.map { $0 / 100 }, tone: dimmed ? .neutral : level.tone, series: dimmed ? nil : series, count: 28, height: 12, tickWidth: 2)
        }
        .opacity(dimmed ? 0.6 : 1)
        .motion(Motion.settle, value: remaining)
    }
}
