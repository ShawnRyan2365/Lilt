import SwiftUI

// The tactile objects that make up Lilt's screens. Each one is adapted from an Interaction Blocks
// component (see Motion.swift for the source and licence) and takes plain values, not app state.

// MARK: Runner track

/// One account on the track.
struct Runner: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Sprite silhouette slot.
    var slot: Int
    var name: String
    /// The outer ring and the clock's long hand.
    var fiveHour = RingReading()
    /// The inner ring and the clock's short hand.
    var sevenDay = RingReading()
    /// Said in place of the clock when there is nothing to draw ("已停用", "未获取", "读不到").
    var note: String?
    /// The age of an old reading ("6 小时前的读数"). The rings recede and the sprite wears a small clock badge.
    var stale: String?
    /// Both windows in words, for the tooltip and VoiceOver.
    var detail: String = ""
    /// A stopped account: shown, greyed, not selectable.
    var stopped = false
    /// The account's state as an expression.
    var mood: Mood = .idle
}

/// The relay queue as a row of sprites, left to right in relay order. Each sprite wears its two quota
/// windows as concentric rings (outer 5 hours, inner 7 days) and has a small clock under its name for
/// when they refresh, so the row reads at a glance without figures under every account.
/// The account in use sits on a soft pill that stretches across to the next one when the baton passes
/// (Icon bar), and its neighbours lean away from it (Magnetic select).
struct RunnerTrack<MenuContent: View>: View {
    let runners: [Runner]
    let activeID: UUID?
    var orbSize: CGFloat = 36
    var disabled = false
    let onSelect: (UUID) -> Void
    var onAdd: (() -> Void)?
    @ViewBuilder var menu: (Runner) -> MenuContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each column's frame in the track, for placing the pill.
    @State private var frames: [UUID: CGRect] = [:]
    /// The pill's edges, animated separately so it can stretch.
    @State private var left: CGFloat = 0
    @State private var right: CGFloat = 0
    /// The account the pill was last placed under. A frame change for any other account is a hand-off,
    /// which `moveSelection` animates; only a change under this one is followed quietly.
    @State private var placed: UUID?

    private var activeIndex: Int? { runners.firstIndex { $0.id == activeID } }
    private var ring: CGFloat { orbSize + 38 }
    private var column: CGFloat { max(72, ring + 8) }
    private var clock: CGFloat { orbSize >= 36 ? 30 : 26 }
    private let space = "runner-track"

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(runners.enumerated()), id: \.element.id) { index, runner in
                if index > 0 {
                    // Order without words: each account hands on to the one after it.
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.faint)
                        .frame(width: 14, height: ring).padding(.top, 8).accessibilityHidden(true)
                }
                runnerButton(runner, index: index)
            }
            if let onAdd {
                Button(action: onAdd) {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: orbSize * 0.34, weight: .medium)).foregroundStyle(Tokens.muted)
                            .frame(width: orbSize, height: orbSize)
                            .background(Tokens.fill, in: Circle())
                            .frame(width: ring, height: ring)
                        Text("添加").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.muted)
                    }
                    .padding(.vertical, 8)
                    .frame(width: column)
                    .contentShape(Rectangle())
                }
                .buttonStyle(OrbButtonStyle())
                .disabled(disabled)
                .help("添加账号").accessibilityLabel("添加账号")
            }
        }
        .background(alignment: .topLeading) {
            if let activeID, let frame = frames[activeID] {
                SpanLeft(left: left, right: right, top: frame.minY, height: frame.height)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named(space))
        .onChange(of: activeID) { old, new in moveSelection(from: old, to: new) }
        .onChange(of: activeID.flatMap { frames[$0] }) { _, frame in
            // Layout changed under the pill (a reorder, a new account, the first layout): follow it without a show.
            guard let frame, placed == activeID || placed == nil else { return }
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { left = frame.minX; right = frame.maxX; placed = activeID }
        }
    }

    private func runnerButton(_ runner: Runner, index: Int) -> some View {
        let active = runner.id == activeID
        // Distance from the selected item drives both how far a neighbour leans and how late it moves.
        let far = Double(abs(index - (activeIndex ?? index)))
        let fall = active || activeIndex == nil ? 0 : exp(-(far - 1) / 2.8)
        let direction: CGFloat = index < (activeIndex ?? index) ? -1 : 1
        return Button { onSelect(runner.id) } label: {
            VStack(spacing: 6) {
                ZStack {
                    WindowRings(outer: runner.fiveHour, inner: runner.sevenDay, diameter: ring, dimmed: runner.stale != nil, muted: runner.stopped)
                    Sprite(slot: runner.slot, size: orbSize, mood: runner.mood, muted: runner.stopped, celebrating: active)
                        .scaleEffect(active ? 1.06 : 1 - 0.05 * fall)
                    if runner.stale != nil {
                        // A status dot on the avatar, as in Reorder list: the reading is old.
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.muted)
                            .frame(width: 15, height: 15).background(Tokens.surface, in: Circle())
                            .overlay(Circle().strokeBorder(Tokens.fill, lineWidth: 1))
                            .offset(x: orbSize * 0.42, y: orbSize * 0.38)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: ring, height: ring)
                .offset(x: reduceMotion ? 0 : direction * 3 * fall)
                VStack(spacing: 4) {
                    Text(runner.name).font(.system(size: 11, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.muted))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Group {
                        if let note = runner.note {
                            Text(note).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1).minimumScaleFactor(0.8)
                        } else {
                            ResetClock(fiveHour: runner.fiveHour, sevenDay: runner.sevenDay, size: clock)
                        }
                    }
                    // Every column has the same height, so the pill fits them all.
                    .frame(height: clock)
                }
            }
            .padding(.vertical, 8)
            .frame(width: column)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[runner.id] = $0 }
        }
        .buttonStyle(OrbButtonStyle())
        .disabled(disabled || active || runner.stopped)
        .contextMenu { menu(runner) }
        .help([runner.name, runner.detail, active ? "使用中" : runner.stopped ? "已停用" : "点击切换"].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel([runner.name, runner.detail, active ? "使用中" : runner.stopped ? "已停用" : ""].filter { !$0.isEmpty }.joined(separator: "，"))
        .accessibilityHint(active || runner.stopped ? "" : "切换到此账号")
        .accessibilityAddTraits(active ? .isSelected : [])
        .animation(reduceMotion ? nil : Motion.magnetic(distance: far).delay(far * 0.022), value: activeID)
    }

    /// The leading edge (in the direction of travel) springs ahead and the trailing one follows on a softer spring.
    private func moveSelection(from old: UUID?, to new: UUID?) {
        guard let new, let target = frames[new] else { placed = nil; return }
        defer { placed = new }
        guard !reduceMotion, old != nil, right > left else {
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { left = target.minX; right = target.maxX }
            return
        }
        let forward = target.minX > left
        withAnimation(forward ? Motion.stretchLead : Motion.stretchLag) { right = target.maxX }
        withAnimation(forward ? Motion.stretchLag : Motion.stretchLead) { left = target.minX }
    }
}

extension RunnerTrack where MenuContent == EmptyView {
    init(runners: [Runner], activeID: UUID?, orbSize: CGFloat = 44, disabled: Bool = false, onSelect: @escaping (UUID) -> Void, onAdd: (() -> Void)? = nil) {
        self.init(runners: runners, activeID: activeID, orbSize: orbSize, disabled: disabled, onSelect: onSelect, onAdd: onAdd) { _ in EmptyView() }
    }
}

/// The selection pill under the account in use. Its edges live in two nested animatable views, so each
/// edge follows its own spring: one view interpolates `left`, the one inside it interpolates `right`.
private struct SpanLeft: View, Animatable {
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var height: CGFloat
    nonisolated var animatableData: CGFloat {
        get { left }
        set { left = newValue }
    }
    var body: some View { SpanRight(left: left, right: right, top: top, height: height) }
}

private struct SpanRight: View, Animatable {
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var height: CGFloat
    nonisolated var animatableData: CGFloat {
        get { right }
        set { right = newValue }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Tokens.fill)
            .frame(width: max(0, right - left), height: height)
            .offset(x: left, y: top)
    }
}

/// Sprites lift slightly under the pointer (Canvas toolbar: 3pt, 180 ms) and squash when pressed.
private struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { OrbButtonBody(configuration: configuration) }
}

private struct OrbButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        configuration.label
            .offset(y: hovered && isEnabled && !reduceMotion ? -3 : 0)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : Motion.snap, value: configuration.isPressed)
            .animation(reduceMotion ? nil : Motion.out(0.18), value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: Liquid toggle

/// The auto-relay switch, adapted from Liquid toggle: the thumb travels on the block's spring and
/// stretches while it moves. VoiceOver and the keyboard see an ordinary switch.
struct LiquidToggle: View {
    let label: String
    @Binding var isOn: Bool
    var width: CGFloat = 52
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = 0

    private var height: CGFloat { width * 0.6 }
    private var thumb: CGFloat { height - 6 }

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.trackOff))
                .frame(width: width, height: height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? AnyShapeStyle(Tokens.onInk) : AnyShapeStyle(Color.white))
                        .frame(width: thumb, height: thumb)
                        .keyframeAnimator(initialValue: CGFloat(1), trigger: travelling) { view, stretch in
                            view.scaleEffect(x: stretch, y: 1 / stretch)
                        } keyframes: { _ in
                            // Stretch on the way, settle on arrival (the block caps stretch at 1 + 0.4 x 36%).
                            CubicKeyframe(1.16, duration: 0.10)
                            SpringKeyframe(1, duration: 0.42, spring: Spring(mass: 0.6, stiffness: 320, damping: 16))
                        }
                        .padding(3)
                }
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : Motion.glide, value: isOn)
        .onChange(of: isOn) { if !reduceMotion { travelling += 1 } }
        .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
    }
}

// MARK: Island

/// The one thing that needs attention right now, as a single dark pill (Dynamic island). It shows a few
/// words; pointing at it or focusing it grows it to show the explanation. The same text is always
/// available to VoiceOver.
struct Island<Action: View>: View {
    var symbol: String
    var tone: Tone = .neutral
    var text: String
    var detail: String?
    @ViewBuilder var action: () -> Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.onInkAccent).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(Typo.label).foregroundStyle(Tokens.onInk).lineLimit(expanded ? 3 : 1)
                if expanded, let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Tokens.onInk.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            if detail != nil, !expanded {
                Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.onInk.opacity(0.5)).accessibilityHidden(true)
            }
            action().padding(.leading, 4)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .frame(minHeight: 40)
        // A pill that hugs its words; it only grows as wide as its container allows when it opens.
        .fixedSize(horizontal: false, vertical: true)
        .background(Tokens.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { expanded = $0 }
        // Dynamic island at bounce 40.
        .animation(reduceMotion ? Motion.fade : .spring(response: 0.34, dampingFraction: 0.72), value: expanded)
        .help(detail ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel([text, detail].compactMap { $0 }.joined(separator: "。"))
    }
}

extension Island where Action == EmptyView {
    init(symbol: String, tone: Tone = .neutral, text: String, detail: String? = nil) {
        self.init(symbol: symbol, tone: tone, text: text, detail: detail) { EmptyView() }
    }
}

/// The small button that lives inside an island.
struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IslandButtonBody(configuration: configuration) }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 11).frame(minHeight: 28)
            // A translucent grey pill read as switched off even when it worked; a solid one is clearly there to press,
            // and the grey is left for when it really has to wait.
            .foregroundStyle(isEnabled ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.onInk.opacity(0.45)))
            .background(isEnabled ? AnyShapeStyle(Tokens.onInk.opacity(hovered || configuration.isPressed ? 0.84 : 1))
                                  : AnyShapeStyle(Tokens.onInk.opacity(0.12)), in: Capsule())
            .contentShape(Capsule()).contentShape(.focusEffect, Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScaleSmall : 1)
            .animation(reduceMotion ? nil : Motion.snap, value: configuration.isPressed)
            .animation(Motion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: Step dots

/// Progress through a short sequence (Step player): done steps are dots of ink, the current one is a
/// longer bar, the rest are pale.
struct StepDots: View {
    let count: Int
    /// Zero-based index of the current step; `count` or more means all done.
    let current: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.trackOff))
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .motion(Motion.settle, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(min(current + 1, count)) 步，共 \(count) 步")
    }
}
