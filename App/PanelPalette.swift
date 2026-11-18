import Foundation

/// The panel's own grays and tints as numbers, shared by PanelView and the tests that
/// check each one against the worst ground the panel can have.
///
/// The panel sits on the popover's Liquid Glass, which has no color of its own: it gets
/// darker over a dark desktop and lighter over a light one, in the light appearance and
/// the dark alike, while the text on it keeps the appearance's colors. So the ground
/// under the text isn't known, and nothing in the SDK reports it or lets an app tint a
/// popover's glass. What the panel can do is put a veil of the window's background color
/// over the glass, which bounds how far the ground can move, and pick text colors that
/// hold 4.5:1 across that whole range. PanelPaletteTests does the arithmetic.
enum PanelPalette {
    /// One value for the light appearance and one for the dark.
    struct Pair<Value: Sendable>: Sendable {
        let light: Value
        let dark: Value

        func value(isDark: Bool) -> Value { isDark ? dark : light }
    }

    struct RGB: Sendable, Equatable {
        let red: Double
        let green: Double
        let blue: Double

        static func gray(_ white: Double) -> RGB { RGB(red: white, green: white, blue: white) }

        /// This color at `opacity` over `ground`, blended the way the screen does it.
        func over(_ ground: RGB, opacity: Double) -> RGB {
            RGB(red: red * opacity + ground.red * (1 - opacity),
                green: green * opacity + ground.green * (1 - opacity),
                blue: blue * opacity + ground.blue * (1 - opacity))
        }

        /// WCAG 2 relative luminance.
        var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG 2 contrast ratio, from 1 to 21.
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    // MARK: - The ground

    /// The darkest and lightest the glass is taken to get under the veil. Nobody has
    /// measured the real limits, so these are black and white: whatever is behind the
    /// panel, the text holds. Measured limits would let the veil be thinner.
    static let glass = Pair(light: 0.0...1.0, dark: 0.0...1.0)

    /// NSColor.windowBackgroundColor in each appearance, which the veil is drawn in.
    static let windowBackground = Pair(light: 1.0, dark: 0.118)

    /// How opaque the veil is. The rest is the glass showing through. The dark veil is
    /// thicker because a light desktop behind dark glass is the harder case: the dark
    /// window background is far from black, so it takes more of it to hold a bright
    /// ground down than it takes white to hold a dark one up.
    static let veilOpacity = Pair(light: 0.7, dark: 0.8)

    /// The Watched row's shading: the text color at this opacity over the ground.
    static let shadeOpacity = 0.05

    /// The two ends of the ground: the veil over the darkest and the lightest glass.
    static func grounds(isDark: Bool) -> [RGB] {
        let veil = RGB.gray(windowBackground.value(isDark: isDark))
        let range = glass.value(isDark: isDark)
        return [range.lowerBound, range.upperBound].map {
            veil.over(.gray($0), opacity: veilOpacity.value(isDark: isDark))
        }
    }

    // MARK: - Text

    /// Names, titles, and button labels. The system's label color is 85% opaque, and
    /// the rest would be the ground showing through, so this is the same color solid.
    static let primary = Pair(light: 0.0, dark: 1.0)

    /// Captions, column titles, and notes. The system's secondary label color is half
    /// see-through and measures under 4:1 even on a plain white window, so no semantic
    /// color can do this job. These are as soft as 4.5:1 allows on the worst ground.
    static let secondary = Pair(light: 0.24, dark: 0.80)

    /// Something failed. The system's red is about 3.5:1 on white, so this is a red dark
    /// enough for the darkest light ground, and one light enough for the lightest dark.
    static let error = Pair(light: RGB(red: 0.56, green: 0, blue: 0),
                            dark: RGB(red: 1, green: 0.68, blue: 0.65))

    // MARK: - Controls

    /// A switch that's off, and at 60% the plain buttons. Not text: it only has to stay
    /// apart from the ground at both ends, which the old lighter and darker grays, made
    /// for a solid window, didn't.
    static let track = Pair(light: 0.55, dark: 0.42)
    static let buttonOpacity = 0.6

    /// The one filled button. White on the system's blue is about 4:1; on this, 5.4:1.
    static let prominent = RGB(red: 0, green: 0.39, blue: 0.85)
}
