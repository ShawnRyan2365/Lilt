import SwiftUI

// Motion for Lilt.
//
// Two sources, kept as authored so they can be traced back:
// - HeroUI v3 (MIT, heroui.com): its easing curves and per-component durations (press, hover, toast).
// - Interaction Blocks (Bencho, MIT, Copyright (c) 2026 Lorenzo Cabra): the spring constants from the
//   readable block reconstructions, in framer-motion's stiffness / damping / mass form, which
//   `interpolatingSpring` takes directly. Only parameters are reused; the SwiftUI code is written for Lilt.
//
// Rules: animate in response to a change, never on a loop; every helper below collapses to no
// movement when Reduce Motion is on.
enum Motion {
    // MARK: HeroUI curves
    /// `--ease-out-fluid`: fast start, soft stop. Sliding indicators, toasts, thumbs.
    static func fluid(_ duration: Double = 0.25) -> Animation { .timingCurve(0.32, 0.72, 0, 1, duration: duration) }
    /// `--ease-out`: hover and color changes.
    static func out(_ duration: Double = 0.10) -> Animation { .timingCurve(0, 0, 0.2, 1, duration: duration) }
    /// `--ease-smooth` (CSS `ease`).
    static func smooth(_ duration: Double = 0.25) -> Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: duration) }
    /// Expo-out used by the Image accordion block for size changes.
    static func expoOut(_ duration: Double = 0.42) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }

    // MARK: HeroUI component timings
    static let hover = out(0.10)
    static let toastIn = fluid(0.35)
    static let toastOut = fluid(0.25)
    static let fade = smooth(0.15)
    /// Button press scale by control size (`.button` 0.97, `--sm` 0.98, `--lg` 0.96).
    static let pressScale: CGFloat = 0.97
    static let pressScaleSmall: CGFloat = 0.98
    static let pressScaleLarge: CGFloat = 0.96

    // MARK: Interaction Blocks springs
    /// Press and hover response (Dragging ball, Liquid toggle): stiffness 520, damping 24, mass 0.6.
    static let snap = Animation.interpolatingSpring(mass: 0.6, stiffness: 520, damping: 24)
    /// Layout moves and hand-offs (Carousel): stiffness 260, damping 25.
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 25)
    /// Staggered reveal (Radial menu): stiffness 340, damping 22.
    static let pop = Animation.interpolatingSpring(mass: 1, stiffness: 340, damping: 22)
    /// Thumb travel (Liquid toggle at speed 50): stiffness 170, damping 21.5, mass 0.9.
    static let glide = Animation.interpolatingSpring(mass: 0.9, stiffness: 170, damping: 21.5)
    /// Delay between neighbours in a staggered reveal (Radial menu: 25 ms).
    static let stagger: Double = 0.025

    /// Selection spring from Magnetic select. Stiffness falls off with distance from the selected item,
    /// and the damping ratio comes from the block's `bounce` control (55 by default; Lilt uses a calmer 25).
    static func magnetic(distance: Double = 0, bounce: Double = 25) -> Animation {
        let stiffness = 300 + 280 * (1 - min(distance, 3) / 4)
        let mass = 0.9
        let ratio = 0.9 - 0.48 * min(max(bounce, 0), 100) / 100
        return .interpolatingSpring(mass: mass, stiffness: stiffness, damping: 2 * (stiffness * mass).squareRoot() * ratio)
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct StaggeredAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let offset: CGFloat
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(Motion.pop.delay(Double(index) * Motion.stagger)) { shown = true }
            }
    }
}

extension View {
    /// Animates changes of `value`, unless Reduce Motion is on.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// One-time staggered entrance: fades and rises into place, each index 25 ms after the previous one.
    func staggeredAppear(index: Int, offset: CGFloat = 8) -> some View {
        modifier(StaggeredAppear(index: index, offset: offset))
    }
}

extension AnyTransition {
    /// Toast and inline confirmation entrance (Notify block: rises 25pt from 90% scale; HeroUI toast timing).
    static func liltPop(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .offset(y: 10)).combined(with: .opacity).animation(Motion.toastIn),
            removal: .opacity.animation(Motion.toastOut))
    }

    /// Relay hand-off: the outgoing account leaves toward the leading edge while the next one arrives from the trailing edge.
    static func liltHandoff(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 18).combined(with: .opacity),
            removal: .offset(x: -18).combined(with: .opacity))
    }

    /// Content that expands in place, such as a status line appearing under a header.
    static func liltReveal(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -6).combined(with: .opacity),
            removal: .opacity)
    }
}
