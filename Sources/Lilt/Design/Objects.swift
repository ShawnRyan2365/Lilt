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
    /// The tighter quota window, already worded ("72%", "未知").
    var note: String
    /// Colours the note when it needs attention; the note's words still carry the meaning.
    var noteTone: Tone = .neutral
    /// A stopped account: shown, greyed, not selectable.
    var stopped = false
    /// The account's state as an expression.
    var mood: Mood = .idle
}

/// The relay queue as a row of sprites, adapted from Magnetic select: the account in use grows and wears a
/// ring, its neighbours lean away, and the ring travels when the baton passes. Left to right is relay order.
struct RunnerTrack<MenuContent: View>: View {
    let runners: [Runner]
    let activeID: UUID?
    var orbSize: CGFloat = 44
    var disabled = false
    let onSelect: (UUID) -> Void
    var onAdd: (() -> Void)?
    @ViewBuilder var menu: (Runner) -> MenuContent
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeIndex: Int? { runners.firstIndex { $0.id == activeID } }

    var body: some View {
        HStack(alignment: .top, spacing: orbSize * 0.14) {
            ForEach(Array(runners.enumerated()), id: \.element.id) { index, runner in
                if index > 0 {
                    // Order without words: each account hands on to the one after it.
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.faint)
                        .frame(width: 8, height: orbSize * 1.18 + 10).accessibilityHidden(true)
                }
                let active = runner.id == activeID
                // Distance from the selected item drives both how far a neighbour leans and how late it moves.
                let far = Double(abs(index - (activeIndex ?? index)))
                let fall = active || activeIndex == nil ? 0 : exp(-(far - 1) / 2.8)
                let direction: CGFloat = index < (activeIndex ?? index) ? -1 : 1
                Button { onSelect(runner.id) } label: {
                    VStack(spacing: 8) {
                        Sprite(slot: runner.slot, size: orbSize, mood: runner.mood, muted: runner.stopped, celebrating: active)
                            .scaleEffect(active ? 1.18 : 1 - 0.06 * fall)
                            .padding(5)
                            .background {
                                if active {
                                    Circle().strokeBorder(Tokens.ink, lineWidth: 2)
                                        .frame(width: orbSize * 1.18 + 10, height: orbSize * 1.18 + 10)
                                        .matchedGeometryEffect(id: "ring", in: ring)
                                }
                            }
                            .frame(width: orbSize * 1.18 + 10, height: orbSize * 1.18 + 10)
                            .offset(x: reduceMotion ? 0 : direction * 3 * fall)
                        VStack(spacing: 2) {
                            Text(runner.name).font(.system(size: 11, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.muted))
                            Text(runner.note).font(Typo.caption).monospacedDigit()
                                .foregroundStyle(runner.noteTone == .neutral ? AnyShapeStyle(Tokens.muted) : runner.noteTone.text)
                        }
                        .lineLimit(1).minimumScaleFactor(0.9)
                    }
                    .frame(width: orbSize * 1.18 + 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(OrbButtonStyle())
                .disabled(disabled || active || runner.stopped)
                .contextMenu { menu(runner) }
                .help(active ? "\(runner.name)（使用中）" : runner.stopped ? "\(runner.name)（已停用）" : "切换到 \(runner.name)")
                .accessibilityLabel("\(runner.name)，\(runner.note)\(active ? "，使用中" : runner.stopped ? "，已停用" : "")")
                .accessibilityHint(active || runner.stopped ? "" : "切换到此账号")
                .accessibilityAddTraits(active ? .isSelected : [])
                .animation(reduceMotion ? nil : Motion.magnetic(distance: far).delay(far * 0.022), value: activeID)
            }
            if let onAdd {
                Button(action: onAdd) {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: orbSize * 0.34, weight: .medium)).foregroundStyle(Tokens.muted)
                            .frame(width: orbSize, height: orbSize)
                            .background(Tokens.fill, in: Circle())
                            .frame(width: orbSize * 1.18 + 10, height: orbSize * 1.18 + 10)
                        Text("添加").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.muted)
                    }
                    .frame(width: orbSize * 1.18 + 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(OrbButtonStyle())
                .disabled(disabled)
                .help("添加账号").accessibilityLabel("添加账号")
            }
        }
    }
}

extension RunnerTrack where MenuContent == EmptyView {
    init(runners: [Runner], activeID: UUID?, orbSize: CGFloat = 44, disabled: Bool = false, onSelect: @escaping (UUID) -> Void, onAdd: (() -> Void)? = nil) {
        self.init(runners: runners, activeID: activeID, orbSize: orbSize, disabled: disabled, onSelect: onSelect, onAdd: onAdd) { _ in EmptyView() }
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
            .foregroundStyle(Tokens.onInk.opacity(isEnabled ? 1 : 0.5))
            .background(Tokens.onInk.opacity(hovered || configuration.isPressed ? 0.26 : 0.16), in: Capsule())
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
