import SwiftUI

// MARK: Surfaces

private struct ObjectSurface: ViewModifier {
    let radius: CGFloat
    let secondary: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(secondary ? Tokens.surfaceSecondary : Tokens.surface, in: shape)
            .overlay(shape.strokeBorder(Tokens.border, lineWidth: 1))
    }
}

private struct FloatingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Tokens.surface, in: shape).overlay(shape.strokeBorder(Tokens.border, lineWidth: 1))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// A white object on the canvas. No shadow and, in light mode, no border: the canvas separates it.
    func object(radius: CGFloat = Radius.object) -> some View {
        modifier(ObjectSurface(radius: radius, secondary: false))
    }

    /// A well inside an object.
    func well(radius: CGFloat = Radius.tile) -> some View {
        modifier(ObjectSurface(radius: radius, secondary: true))
    }

    /// Liquid Glass for floating layers only. Falls back to an opaque surface under Reduce Transparency.
    func floatingGlass(radius: CGFloat = Radius.object) -> some View {
        modifier(FloatingGlass(radius: radius))
    }
}

// MARK: Buttons

/// Pill buttons. One `primary` (ink) per context; `secondary` sits on a white object, `surface` on the
/// grey canvas; `ghost` is text only; `danger` is for destructive actions.
struct LiltButtonStyle: ButtonStyle {
    enum Kind: Sendable { case primary, secondary, surface, ghost, danger }
    enum Size: Sendable { case small, medium, large }
    var kind: Kind = .secondary
    var size: Size = .medium
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        LiltButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == LiltButtonStyle {
    static func lilt(_ kind: LiltButtonStyle.Kind = .secondary, size: LiltButtonStyle.Size = .medium, fullWidth: Bool = false) -> LiltButtonStyle {
        LiltButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct LiltButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LiltButtonStyle.Kind
    let size: LiltButtonStyle.Size
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var height: CGFloat { switch size { case .small: 26; case .medium: 32; case .large: 40 } }
    private var horizontalPadding: CGFloat { switch size { case .small: 11; case .medium: 15; case .large: 20 } }
    private var pressScale: CGFloat {
        switch size { case .small: Motion.pressScaleSmall; case .medium: Motion.pressScale; case .large: Motion.pressScaleLarge }
    }

    private var foreground: AnyShapeStyle {
        // Disabled keeps a readable label on a neutral fill; it must never fade into the page.
        guard isEnabled else { return AnyShapeStyle(Tokens.muted.opacity(0.75)) }
        switch kind {
        case .primary: return AnyShapeStyle(Tokens.onInk)
        case .danger: return Tone.danger.text
        case .secondary, .surface, .ghost: return AnyShapeStyle(Tokens.ink)
        }
    }

    private func fill(active: Bool) -> AnyShapeStyle {
        guard isEnabled else { return kind == .ghost ? AnyShapeStyle(Tokens.fill.opacity(0)) : AnyShapeStyle(Tokens.fill) }
        switch kind {
        case .primary: return AnyShapeStyle(Tokens.ink)
        case .danger: return Tone.danger.soft
        case .secondary: return AnyShapeStyle(active ? Tokens.fillHover : Tokens.fill)
        case .surface: return AnyShapeStyle(Tokens.surface)
        case .ghost: return AnyShapeStyle(Tokens.fill.opacity(active ? 1 : 0))
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        let active = (hovered || pressed) && isEnabled
        let veiled = active && (kind == .primary || kind == .danger || kind == .surface)
        configuration.label
            .font(.system(size: size == .small ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(fill(active: active), in: Capsule())
            .overlay(Capsule().fill(kind == .primary ? AnyShapeStyle(Tokens.onInk.opacity(veiled ? 0.14 : 0)) : AnyShapeStyle(Tokens.fill.opacity(veiled ? 1 : 0))).allowsHitTesting(false))
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .scaleEffect(pressed && isEnabled && !reduceMotion ? pressScale : 1)
            .animation(reduceMotion ? nil : Motion.snap, value: pressed)
            .animation(Motion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

/// Round icon button with a full-size hit target. Always pair with `.accessibilityLabel` and `.help`.
struct LiltIconButtonStyle: ButtonStyle {
    enum Kind: Sendable { case ghost, filled, surface, ink }
    var kind: Kind = .ghost
    var diameter: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        LiltIconButtonBody(configuration: configuration, kind: kind, diameter: diameter)
    }
}

extension ButtonStyle where Self == LiltIconButtonStyle {
    static func liltIcon(_ kind: LiltIconButtonStyle.Kind = .ghost, diameter: CGFloat = 30) -> LiltIconButtonStyle {
        LiltIconButtonStyle(kind: kind, diameter: diameter)
    }
}

private struct LiltIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LiltIconButtonStyle.Kind
    let diameter: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private func background(active: Bool) -> AnyShapeStyle {
        switch kind {
        case .ghost: AnyShapeStyle(Tokens.fill.opacity(active ? 1 : 0))
        case .filled: AnyShapeStyle(active ? Tokens.fillHover : Tokens.fill)
        case .surface: AnyShapeStyle(Tokens.surface)
        case .ink: AnyShapeStyle(isEnabled ? Tokens.ink : Tokens.trackOff)
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        let active = (hovered || pressed) && isEnabled
        configuration.label
            .font(.system(size: diameter * 0.43, weight: .medium))
            .frame(width: diameter, height: diameter)
            .foregroundStyle(kind == .ink ? AnyShapeStyle(Tokens.onInk) : isEnabled ? AnyShapeStyle(Tokens.ink) : AnyShapeStyle(Tokens.muted.opacity(0.6)))
            .background(background(active: active), in: Circle())
            .overlay(Circle().fill(Tokens.fill.opacity(active && kind == .surface ? 1 : 0)).allowsHitTesting(false))
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
            .scaleEffect(pressed && isEnabled && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : Motion.snap, value: pressed)
            .animation(Motion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: Pill

/// A one-to-three word tag. `ink` is the loud one (demo mode); `soft` tints by tone; `plain` is quiet.
struct Pill: View {
    enum Style: Sendable { case plain, soft(Tone), ink }
    let text: String
    var symbol: String?
    var style: Style = .plain

    private var foreground: AnyShapeStyle {
        switch style { case .plain: AnyShapeStyle(Tokens.muted); case .soft(let tone): tone.text; case .ink: AnyShapeStyle(Tokens.onInk) }
    }
    private var background: AnyShapeStyle {
        switch style { case .plain: AnyShapeStyle(Tokens.fill); case .soft(let tone): tone.soft; case .ink: AnyShapeStyle(Tokens.ink) }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true) }
            Text(text)
        }
        .font(Typo.captionStrong)
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
