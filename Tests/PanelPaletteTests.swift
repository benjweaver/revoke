import AppKit
import Testing

/// The panel's text holds 4.5:1 on its glass whatever is behind it. The glass can't be
/// measured from here, so these work out the two ends of the ground the veil allows
/// and check every text color on both, in the light appearance and the dark.
struct PanelPaletteTests {
    typealias RGB = PanelPalette.RGB

    private static let minimum = 4.5

    /// A system color as macOS resolves it in one appearance.
    private func system(_ color: NSColor, isDark: Bool) -> RGB {
        var result = RGB.gray(0)
        NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            result = RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
        return result
    }

    private func primary(_ isDark: Bool) -> RGB { .gray(PanelPalette.primary.value(isDark: isDark)) }

    /// Both ends of the veiled glass, and the solid ground that stands in for the glass
    /// under Reduce Transparency and Increase Contrast.
    private func plainGrounds(_ isDark: Bool) -> [RGB] {
        PanelPalette.grounds(isDark: isDark) + [.gray(PanelPalette.windowBackground.value(isDark: isDark))]
    }

    /// Every ground the panel puts text on: the plain ones, and the Watched row's
    /// shading on each.
    private func grounds(_ isDark: Bool) -> [RGB] {
        let plain = plainGrounds(isDark)
        return plain + plain.map { primary(isDark).over($0, opacity: PanelPalette.shadeOpacity) }
    }

    @Test func theVeilIsDrawnInTheColorTheArithmeticAssumes() {
        for isDark in [false, true] {
            let real = system(.windowBackgroundColor, isDark: isDark)
            let assumed = PanelPalette.windowBackground.value(isDark: isDark)
            #expect(abs(real.red - assumed) < 0.02 && abs(real.green - assumed) < 0.02 && abs(real.blue - assumed) < 0.02,
                    "windowBackgroundColor is \(real) in \(isDark ? "dark" : "light")")
        }
    }

    @Test func textHoldsOnEveryGround() {
        for isDark in [false, true] {
            for ground in grounds(isDark) {
                let colors = [
                    ("primary", primary(isDark)),
                    ("secondary", RGB.gray(PanelPalette.secondary.value(isDark: isDark))),
                ]
                for (name, color) in colors {
                    let ratio = color.contrast(with: ground)
                    #expect(ratio >= Self.minimum, "\(name) is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
                }
            }
            // The line that says something failed is never on the shading.
            for ground in plainGrounds(isDark) {
                let ratio = PanelPalette.error.value(isDark: isDark).contrast(with: ground)
                #expect(ratio >= Self.minimum, "error is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
            }
        }
    }

    /// The strip for access that's on for now, the clock switch in it, and the Full
    /// Disk Access notice all put primary text on a wash of orange or yellow.
    @Test func primaryTextHoldsOnTheTintedBoxes() {
        for isDark in [false, true] {
            let washes = [
                (system(.systemOrange, isDark: isDark), 0.16),
                (system(.systemOrange, isDark: isDark), 0.22),
                (system(.systemYellow, isDark: isDark), 0.15),
            ]
            for ground in grounds(isDark) {
                for (tint, opacity) in washes {
                    let box = tint.over(ground, opacity: opacity)
                    let ratio = primary(isDark).contrast(with: box)
                    #expect(ratio >= Self.minimum, "primary is \(ratio):1 on \(box) in \(isDark ? "dark" : "light")")
                }
            }
        }
    }

    @Test func buttonLabelsHoldOnTheirFills() {
        let white = RGB.gray(1)
        #expect(white.contrast(with: PanelPalette.prominent) >= Self.minimum)
        for isDark in [false, true] {
            let track = RGB.gray(PanelPalette.track.value(isDark: isDark))
            for ground in grounds(isDark) {
                let fill = track.over(ground, opacity: PanelPalette.buttonOpacity)
                let ratio = primary(isDark).contrast(with: fill)
                #expect(ratio >= Self.minimum, "a button's label is \(ratio):1 on \(fill) in \(isDark ? "dark" : "light")")
            }
        }
    }

    /// An off switch isn't text, and its white knob shows where the track doesn't, but
    /// the track shouldn't melt into the ground at either end.
    @Test func anOffSwitchStaysApartFromTheGround() {
        for isDark in [false, true] {
            let track = RGB.gray(PanelPalette.track.value(isDark: isDark))
            for ground in PanelPalette.grounds(isDark: isDark) {
                let ratio = track.contrast(with: ground)
                #expect(ratio >= 1.5, "an off switch is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
            }
        }
    }
}
