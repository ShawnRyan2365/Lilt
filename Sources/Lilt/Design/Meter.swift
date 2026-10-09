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
}

/// The quota ruler, adapted from the Progress ticks block: a row of thin ticks, ink for what is left,
/// pale for what is used. Tick heights follow a slow wave (Lilt's mark is a waveform), and a change
/// sweeps across the ticks instead of all of them moving at once.
struct TickRuler: View {
    var fraction: Double?
    var tone: Tone = .neutral
    var count = 36
    var height: CGFloat = 44
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Ticks start empty and fill once when the ruler comes on screen.
    @State private var appeared = false

    private var filled: Int {
        guard appeared || reduceMotion, let fraction, fraction > 0 else { return 0 }
        return min(count, max(1, Int((min(1, fraction) * Double(count)).rounded())))
    }

    /// 0.72...1.0 of the full height.
    private func wave(_ index: Int) -> CGFloat {
        let t = Double(index) / Double(max(1, count - 1))
        return 0.86 + 0.14 * CGFloat(sin(t * .pi * 2.4 + 0.6))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                let on = index < filled
                Capsule()
                    .fill(on ? tone.solid : AnyShapeStyle(Tokens.trackOff))
                    .frame(maxWidth: 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: height * wave(index) * (on ? 1 : 0.78))
                    .animation(reduceMotion ? nil : Motion.snap.delay(Double(index) * 0.010), value: filled)
            }
        }
        .frame(height: height, alignment: .bottom)
        .opacity(dimmed ? 0.4 : 1)
        .motion(Motion.fade, value: dimmed)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
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
    var compact = false

    private var level: QuotaLevel { QuotaLevel(remaining: remaining, threshold: threshold) }
    private var flag: (text: String, tone: Tone)? {
        if let staleNote, remaining != nil { return (staleNote, .neutral) }
        return level.label.map { ($0, level.tone) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 6) {
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
            TickRuler(fraction: remaining.map { $0 / 100 }, tone: level.tone, count: compact ? 22 : 36, height: compact ? 22 : 44, dimmed: stale)
            if let footnote { Text(footnote).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1) }
        }
        .motion(Motion.fade, value: stale)
        .motion(Motion.pop, value: flag?.text)
    }
}
