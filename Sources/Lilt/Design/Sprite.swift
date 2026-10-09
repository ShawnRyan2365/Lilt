import SwiftUI

// An account's face: a small ink character whose eyes show how the account is doing.
//
// The idea of a spring-driven blob with expressive eyes comes from studying the Grok Bot character
// (github.com/blessonism/grok-icon-study). That character's shapes belong to xAI and the study is
// marked "learning only, do not redistribute", so nothing from it is used here: the silhouettes and
// eyes below are drawn for Lilt from simple formulas.

/// Where the pointer is, in global coordinates, for sprites to look at. The view that contains them feeds it
/// with `trackingPointer(_:)`; sprites outside such a view simply look straight ahead.
@MainActor @Observable
final class PointerTracker {
    var location: CGPoint?
}

extension View {
    /// Lets the sprites inside this view follow the pointer while it is over the view.
    func trackingPointer(_ tracker: PointerTracker) -> some View {
        onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let point): tracker.location = point
            case .ended: tracker.location = nil
            }
        }
        .environment(tracker)
    }
}

/// How an account is doing, as an expression. The same information is always written next to the sprite.
enum Mood: Sendable, Equatable {
    /// Fine: open eyes.
    case idle
    /// Just took the baton: smiling for a moment.
    case happy
    /// Quota is low: eyes half closed.
    case drowsy
    /// At the threshold, or stopped: eyes shut.
    case asleep
    /// Under the pointer: eyes wide.
    case alert
}

/// A soft closed curve. Each variant is a circle nudged by one low-order wave, so accounts differ by
/// silhouette rather than by colour.
private struct BlobShape: Shape {
    let variant: Int

    /// Lobes, depth and rotation per variant.
    private static let variants: [(lobes: Double, depth: Double, turn: Double)] = [
        (2, 0.035, 0), (3, 0.060, .pi / 2), (4, 0.050, .pi / 4), (5, 0.042, -.pi / 2),
        (2, 0.075, .pi / 2), (3, 0.060, -.pi / 2), (6, 0.036, 0), (4, 0.050, 0),
    ]
    static var count: Int { variants.count }

    func path(in rect: CGRect) -> Path {
        let v = Self.variants[((variant % Self.variants.count) + Self.variants.count) % Self.variants.count]
        let radius = min(rect.width, rect.height) / 2 / (1 + v.depth)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 96
        var path = Path()
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let r = radius * (1 + v.depth * cos(v.lobes * angle + v.turn))
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Two eyes as capsules whose height and width animate between expressions.
private struct EyeShape: Shape {
    /// 1 is fully open; 0.14 is a closed line.
    var open: CGFloat
    /// Width multiplier: wider when shut (a line) or startled.
    var wide: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(open, wide) }
        set { open = newValue.first; wide = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let width = size * 0.105 * wide
        let height = max(size * 0.03, size * 0.21 * open)
        var path = Path()
        for side in [-1.0, 1.0] {
            let eye = CGRect(x: rect.midX + side * size * 0.15 - width / 2, y: rect.midY - size * 0.03 - height / 2, width: width, height: height)
            path.addRoundedRect(in: eye, cornerSize: CGSize(width: min(width, height) / 2, height: min(width, height) / 2))
        }
        return path
    }
}

/// Smiling eyes: two arcs, drawn as strokes.
private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        var path = Path()
        for side in [-1.0, 1.0] {
            let center = CGPoint(x: rect.midX + side * size * 0.15, y: rect.midY + size * 0.01)
            // Each eye is its own stroke; without the move the two arcs are joined by a line.
            let radius = size * 0.075
            path.move(to: CGPoint(x: center.x + radius * cos(200 * .pi / 180), y: center.y + radius * sin(200 * .pi / 180)))
            path.addArc(center: center, radius: radius, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
        }
        return path
    }
}

struct Sprite: View {
    /// Silhouette index; see `Sprite.slots(for:)`.
    let slot: Int
    var size: CGFloat = 40
    var mood: Mood = .idle
    /// A stopped account: grey and asleep.
    var muted = false
    /// Flips true when this account takes the baton; the sprite smiles and hops once.
    var celebrating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PointerTracker.self) private var pointer: PointerTracker?
    @State private var hovered = false
    @State private var smiling = false
    @State private var hop = 0
    @State private var blink = 0
    @State private var frame = CGRect.zero

    static var slotCount: Int { BlobShape.count }

    /// A stable starting slot for an id. Derived from the UUID's bytes, so it is the same on every
    /// launch (Swift's `Hasher` is not).
    static func slot(for id: UUID) -> Int {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % slotCount
    }

    /// One slot per id, nudged so that no two share a silhouette while there are silhouettes left.
    /// The order of `ids` does not matter, so reordering accounts never changes their faces.
    static func slots(for ids: [UUID]) -> [UUID: Int] {
        var taken = Set<Int>()
        var result: [UUID: Int] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            var slot = Self.slot(for: id)
            var tries = 0
            // A step of 3 is coprime with the number of silhouettes, so it visits every one before repeating.
            while taken.contains(slot), tries < slotCount { slot = (slot + 3) % slotCount; tries += 1 }
            taken.insert(slot); result[id] = slot
        }
        return result
    }

    private var shown: Mood {
        if muted { return .asleep }
        if smiling { return .happy }
        return hovered && mood == .idle ? .alert : mood
    }
    /// Eyes drift toward the pointer: a few percent of the sprite's size, less when the pointer is close.
    private var gaze: CGSize {
        guard !reduceMotion, !muted, shown != .asleep, let target = pointer?.location, frame != .zero else { return .zero }
        let dx = target.x - frame.midX, dy = target.y - frame.midY
        let distance = max(1, (dx * dx + dy * dy).squareRoot())
        let reach = size * 0.055 * min(1, distance / (size * 1.5))
        return CGSize(width: dx / distance * reach, height: dy / distance * reach)
    }
    private var eyes: (open: CGFloat, wide: CGFloat) {
        switch shown {
        case .idle, .happy: (1, 1)
        case .alert: (1.18, 1.22)
        case .drowsy: (0.42, 1.1)
        case .asleep: (0.14, 1.5)
        }
    }

    var body: some View {
        ZStack {
            BlobShape(variant: slot).fill(muted ? AnyShapeStyle(Tokens.trackOff) : AnyShapeStyle(Tokens.ink))
            Group {
                EyeShape(open: eyes.open, wide: eyes.wide)
                    .fill(muted ? AnyShapeStyle(Tokens.surface) : AnyShapeStyle(Tokens.onInk))
                    // A blink whenever the expression changes: shut for a moment, then back.
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: blink) { view, lid in
                        view.scaleEffect(x: 1, y: lid)
                    } keyframes: { _ in
                        CubicKeyframe(0.12, duration: 0.07)
                        CubicKeyframe(1, duration: 0.11)
                    }
                    .opacity(shown == .happy ? 0 : 1)
                SmileShape()
                    .stroke(Tokens.onInk, style: StrokeStyle(lineWidth: max(1.6, size * 0.06), lineCap: .round))
                    .opacity(shown == .happy ? 1 : 0)
            }
            .offset(gaze)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.72), value: gaze)
        }
        .frame(width: size, height: size)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // One squash-and-stretch hop when the baton arrives (press spring from the Dragging ball block).
        .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: hop) { view, scale in
            view.scaleEffect(x: scale.width, y: scale.height, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack(\.width) {
                CubicKeyframe(1.10, duration: 0.10)
                SpringKeyframe(1, duration: 0.50, spring: Spring(mass: 0.6, stiffness: 520, damping: 14))
            }
            KeyframeTrack(\.height) {
                CubicKeyframe(0.88, duration: 0.10)
                SpringKeyframe(1, duration: 0.50, spring: Spring(mass: 0.6, stiffness: 520, damping: 14))
            }
        }
        .animation(reduceMotion ? nil : Motion.snap, value: shown)
        .onHover { hovered = $0 }
        .onChange(of: mood) { if !reduceMotion, !muted { blink += 1 } }
        .onChange(of: celebrating) { _, now in
            guard now, !muted else { return }
            smiling = true
            if !reduceMotion { hop += 1 }
            Task { try? await Task.sleep(for: .seconds(1.6)); smiling = false }
        }
        .accessibilityHidden(true)
    }
}
