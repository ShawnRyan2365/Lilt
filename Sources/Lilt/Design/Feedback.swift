import SwiftUI

// MARK: Inline note

/// A short tinted note inside a sheet or form: one icon, one sentence. For page-level state use `Island`.
struct InlineNote: View {
    var tone: Tone = .warning
    var symbol = "exclamationmark.circle"
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.text).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(tone.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Transient confirmation

/// Drives a short-lived confirmation such as "copied". Call `flash()`; `shown` resets itself.
@MainActor @Observable
final class Transient {
    private(set) var shown = false
    private var task: Task<Void, Never>?

    func flash(for seconds: Double = 1.8) {
        task?.cancel()
        shown = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.shown = false
        }
    }
}

/// Floating confirmation (Notify block entrance, HeroUI toast timing): a few words acknowledging an
/// action the user just took. Not for state that has to stay visible.
struct ToastPill: View {
    let text: String
    /// A check for "done" acknowledgements; `nil` for plain status.
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)).accessibilityHidden(true) }
            Text(text).font(Typo.captionStrong)
        }
        .foregroundStyle(Tokens.ink)
        .padding(.horizontal, 14).padding(.vertical, 8)
        // A floating layer, so it is Liquid Glass (opaque under Reduce Transparency).
        .floatingGlass(radius: 100)
        .accessibilityElement(children: .combine)
    }
}

private struct ToastOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let text: String
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if shown {
                ToastPill(text: text)
                    .padding(10)
                    .transition(.liltPop(reduceMotion: reduceMotion))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.toastIn, value: shown)
    }
}

extension View {
    /// Shows a confirmation over this view while `shown` is true.
    func toast(_ text: String, shown: Bool, alignment: Alignment = .bottom) -> some View {
        modifier(ToastOverlay(shown: shown, text: text, alignment: alignment))
    }
}
