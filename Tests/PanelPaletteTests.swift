import AppKit
import Testing

/// The panel's text holds 4.5:1 on its glass whatever is behind it. The glass can't be
/// measured from here, so these take its limits from screenshots (Scripts/contrast.py),
/// work out the two ends of the ground the veil allows, and check every text color on
/// both, in the light appearance and the dark.
struct PanelPaletteTests {
    typealias RGB = PanelPalette.RGB

    private static let minimum = 4.5
    /// What the panel's own grays and reds are held to, for some room over the minimum.
    private static let comfortable = 5.0

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

    /// The range the glass is taken to cover has to contain the glass the screenshots
    /// showed: the measured ground with the veil it was drawn under taken back out.
    @Test func theGlassRangeCoversWhatWasMeasured() {
        for isDark in [false, true] {
            let measured = PanelPalette.measured.value(isDark: isDark)
            let veil = PanelPalette.windowBackground.value(isDark: isDark)
            let range = PanelPalette.glass.value(isDark: isDark)
            for ground in [measured.overBlack, measured.overWhite] {
                let glass = (ground - veil * measured.veilOpacity) / (1 - measured.veilOpacity)
                #expect(range.contains(glass), "glass measured at \(glass) in \(isDark ? "dark" : "light")")
            }
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
                    #expect(ratio >= Self.comfortable, "\(name) is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
                }
            }
            // The line that says something failed is never on the shading.
            for ground in plainGrounds(isDark) {
                let ratio = PanelPalette.error.value(isDark: isDark).contrast(with: ground)
                #expect(ratio >= Self.comfortable, "error is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
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

    /// The plain buttons sit on the plain ground, the Watched row's shading, and the
    /// orange strip (End Now).
    @Test func buttonLabelsHoldOnTheirFills() {
        let white = RGB.gray(1)
        #expect(white.contrast(with: PanelPalette.prominent) >= Self.minimum)
        for isDark in [false, true] {
            let button = RGB.gray(PanelPalette.button.value(isDark: isDark))
            let strip = plainGrounds(isDark).map { system(.systemOrange, isDark: isDark).over($0, opacity: 0.16) }
            for ground in grounds(isDark) + strip {
                let fill = button.over(ground, opacity: PanelPalette.buttonOpacity)
                let ratio = primary(isDark).contrast(with: fill)
                #expect(ratio >= Self.minimum, "a button's label is \(ratio):1 on \(fill) in \(isDark ? "dark" : "light")")
            }
        }
    }

    /// An off switch isn't text, but its shape should be about 3:1 against the ground.
    /// In the light appearance the track does that alone, on every ground. In the dark
    /// the white knob does it, the track stays 3:1 from the knob so the knob's place
    /// can be read, and the track may come as near the lightest ground as 2:1.
    @Test func anOffSwitchStaysApartFromTheGround() {
        for isDark in [false, true] {
            let track = RGB.gray(PanelPalette.track.value(isDark: isDark))
            #expect(PanelPalette.knob.contrast(with: track) >= 3, "the knob on its track in \(isDark ? "dark" : "light")")
            for ground in grounds(isDark) {
                let ratio = track.contrast(with: ground)
                #expect(ratio >= (isDark ? 2 : 3), "an off switch is \(ratio):1 on \(ground) in \(isDark ? "dark" : "light")")
                if isDark {
                    #expect(PanelPalette.knob.contrast(with: ground) >= 3, "the knob on \(ground)")
                }
            }
        }
    }
}
