import SwiftUI

// Design tokens for Lilt.
//
// The visual language follows bencho.dev: white tactile objects on a light grey canvas, near-black
// ink as the primary colour, colour reserved for data and warning states, very little text.
// The semantic roles (surface levels, soft backgrounds, muted text) keep HeroUI v3's naming.

/// A color role that resolves against the environment: light or dark, and Increase Contrast.
struct Paint: ShapeStyle, Sendable {
    struct RGBA: Sendable {
        var r: Double, g: Double, b: Double, a: Double
        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    }
    var light: RGBA
    var dark: RGBA
    var lightHigh: RGBA?
    var darkHigh: RGBA?

    init(light: RGBA, dark: RGBA, lightHigh: RGBA? = nil, darkHigh: RGBA? = nil) {
        self.light = light; self.dark = dark; self.lightHigh = lightHigh; self.darkHigh = darkHigh
    }

    func color(scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        let high = contrast == .increased
        let value = scheme == .dark ? (high ? darkHigh ?? dark : dark) : (high ? lightHigh ?? light : light)
        return Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: value.a)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        color(scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
    }
}

enum Tokens {
    // MARK: Layers
    /// The page: a quiet grey that lets white objects stand out without borders.
    static let canvas = Paint(light: .init(0.945, 0.945, 0.949), dark: .init(0.094, 0.094, 0.102))
    /// Objects: the white things you look at and touch.
    static let surface = Paint(light: .init(1, 1, 1), dark: .init(0.165, 0.165, 0.176),
                               darkHigh: .init(0.20, 0.20, 0.21))
    /// Wells inside an object: command text, nested rows.
    static let surfaceSecondary = Paint(light: .init(0.955, 0.955, 0.960), dark: .init(0.215, 0.215, 0.228))
    /// Neutral fill for pills, tracks and secondary buttons.
    static let fill = Paint(light: .init(0, 0, 0, 0.055), dark: .init(1, 1, 1, 0.10),
                            lightHigh: .init(0, 0, 0, 0.12), darkHigh: .init(1, 1, 1, 0.20))
    static let fillHover = Paint(light: .init(0, 0, 0, 0.09), dark: .init(1, 1, 1, 0.16),
                                 lightHigh: .init(0, 0, 0, 0.18), darkHigh: .init(1, 1, 1, 0.26))
    /// Empty ticks and switched-off tracks.
    static let trackOff = Paint(light: .init(0.85, 0.855, 0.865), dark: .init(0.30, 0.30, 0.325),
                                lightHigh: .init(0.62, 0.62, 0.64), darkHigh: .init(0.48, 0.48, 0.52))
    /// Hairline. Invisible on light objects (the canvas already separates them), present in dark and high contrast.
    static let border = Paint(light: .init(0, 0, 0, 0), dark: .init(1, 1, 1, 0.07),
                              lightHigh: .init(0, 0, 0, 0.45), darkHigh: .init(1, 1, 1, 0.50))
    static let separator = Paint(light: .init(0, 0, 0, 0.07), dark: .init(1, 1, 1, 0.08),
                                 lightHigh: .init(0, 0, 0, 0.35), darkHigh: .init(1, 1, 1, 0.40))

    // MARK: Ink
    /// Primary colour for numbers, primary buttons and filled ticks: near-black in light, near-white in dark.
    static let ink = Paint(light: .init(0.09, 0.094, 0.102), dark: .init(0.96, 0.96, 0.97))
    /// Content placed on ink.
    static let onInk = Paint(light: .init(1, 1, 1), dark: .init(0.09, 0.094, 0.102))
    /// Secondary text. At least 4.5:1 on canvas, surface and surfaceSecondary in both schemes.
    static let muted = Paint(light: .init(0.40, 0.40, 0.44), dark: .init(0.68, 0.68, 0.72),
                             lightHigh: .init(0.24, 0.24, 0.27), darkHigh: .init(0.84, 0.84, 0.87))
    /// Decorative glyphs only (unit signs, separators). Never for information.
    static let faint = Paint(light: .init(0.62, 0.62, 0.65), dark: .init(0.46, 0.46, 0.50),
                             lightHigh: .init(0.40, 0.40, 0.44), darkHigh: .init(0.68, 0.68, 0.72))

    // MARK: Quota windows
    /// One data colour per quota window, used everywhere that window is drawn (ruler, ring, clock hand,
    /// legend dot), so the two can be told apart without reading. Blue and aqua from the dataviz
    /// reference palette, checked for colour-blind separation on both surfaces; both are cool, so the
    /// warm warning and danger tones still stand out against them.
    static let fiveHour = Paint(light: .init(0.165, 0.471, 0.839), dark: .init(0.224, 0.529, 0.898),
                                lightHigh: .init(0.110, 0.361, 0.671), darkHigh: .init(0.427, 0.655, 0.925))
    static let sevenDay = Paint(light: .init(0.086, 0.627, 0.439), dark: .init(0.098, 0.620, 0.439),
                                lightHigh: .init(0.039, 0.455, 0.314), darkHigh: .init(0.235, 0.776, 0.565))

    // MARK: Accent
    /// Lilt green: the brand mark, and `.tint()` for the few system controls left (settings, focus rings).
    static let accent = Paint(light: .init(0.12, 0.47, 0.41), dark: .init(0.379, 0.777, 0.697))
    static let accentTint = Paint(light: .init(0.12, 0.47, 0.41), dark: .init(0.16, 0.56, 0.49))
}

/// Semantic intent. Communicates purpose and state; never the only signal (pair it with text or an icon).
enum Tone: Sendable, CaseIterable {
    case neutral, accent, success, warning, danger

    /// Solid fill: meter fills, emphasised marks.
    var solid: AnyShapeStyle {
        switch self {
        case .neutral: AnyShapeStyle(Tokens.ink)
        case .accent: AnyShapeStyle(Tokens.accent)
        case .success: AnyShapeStyle(Paint(light: .init(0.07, 0.62, 0.31), dark: .init(0.188, 0.82, 0.42)))
        case .warning: AnyShapeStyle(Paint(light: .init(0.86, 0.52, 0.04), dark: .init(0.969, 0.718, 0.314)))
        case .danger: AnyShapeStyle(Paint(light: .init(0.88, 0.20, 0.22), dark: .init(0.96, 0.36, 0.36)))
        }
    }
    /// Text and icons placed on `solid`.
    var onSolid: AnyShapeStyle {
        switch self {
        case .neutral: AnyShapeStyle(Tokens.onInk)
        case .accent: AnyShapeStyle(Paint(light: .init(1, 1, 1), dark: .init(0.094, 0.094, 0.106)))
        case .warning: AnyShapeStyle(Color(.sRGB, red: 0.094, green: 0.094, blue: 0.106, opacity: 1))
        case .success, .danger: AnyShapeStyle(Color.white)
        }
    }
    /// Tinted background.
    var soft: AnyShapeStyle {
        switch self {
        case .neutral: AnyShapeStyle(Tokens.fill)
        case .accent: AnyShapeStyle(Paint(light: .init(0.12, 0.47, 0.41, 0.12), dark: .init(0.379, 0.777, 0.697, 0.16)))
        case .success: AnyShapeStyle(Paint(light: .init(0.09, 0.788, 0.392, 0.15), dark: .init(0.09, 0.788, 0.392, 0.16)))
        case .warning: AnyShapeStyle(Paint(light: .init(0.961, 0.647, 0.141, 0.17), dark: .init(0.969, 0.718, 0.314, 0.16)))
        case .danger: AnyShapeStyle(Paint(light: .init(1.0, 0.22, 0.235, 0.12), dark: .init(0.859, 0.231, 0.243, 0.20)))
        }
    }
    /// Foreground that stays at or above 4.5:1 on `soft`, on surfaces and on the canvas.
    var text: AnyShapeStyle {
        switch self {
        case .neutral: AnyShapeStyle(Tokens.ink)
        case .accent: AnyShapeStyle(Paint(light: .init(0.06, 0.40, 0.345), dark: .init(0.44, 0.82, 0.74)))
        case .success: AnyShapeStyle(Paint(light: .init(0.0, 0.443, 0.203), dark: .init(0.327, 0.836, 0.488)))
        case .warning: AnyShapeStyle(Paint(light: .init(0.592, 0.343, 0.0), dark: .init(0.956, 0.722, 0.355)))
        case .danger: AnyShapeStyle(Paint(light: .init(0.717, 0.096, 0.130), dark: .init(1.0, 0.531, 0.504)))
        }
    }
    /// The same warning and danger hues, tuned to sit on ink (the island).
    var onInkAccent: AnyShapeStyle {
        switch self {
        case .warning: AnyShapeStyle(Paint(light: .init(1.0, 0.70, 0.26), dark: .init(0.72, 0.42, 0.0)))
        case .danger: AnyShapeStyle(Paint(light: .init(1.0, 0.50, 0.47), dark: .init(0.76, 0.12, 0.15)))
        case .success, .accent: AnyShapeStyle(Paint(light: .init(0.45, 0.86, 0.66), dark: .init(0.05, 0.42, 0.30)))
        case .neutral: AnyShapeStyle(Tokens.onInk)
        }
    }
}

/// Corner radii: one value per role.
enum Radius {
    /// Objects on the canvas.
    static let object: CGFloat = 24
    /// Rows and wells nested inside an object.
    static let tile: CGFloat = 14
    /// Text fields.
    static let field: CGFloat = 10
}

/// Type roles. System font throughout; 11pt is the floor for anything that carries information.
enum Typo {
    static let title = Font.system(size: 17, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)
    /// Large figures: medium weight, set tight, the way the reference sets its numbers.
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
}
