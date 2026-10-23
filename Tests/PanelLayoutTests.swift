import CoreGraphics
import Testing

/// The panel keeps its full width on ordinary screens and narrows to fit small ones.
struct PanelLayoutTests {
    @Test func fullWidthOnOrdinaryScreens() {
        for screen: CGFloat in [1024, 1280, 1512, 2560] {
            #expect(PanelLayout.width(forScreenWidth: screen) == PanelLayout.preferredWidth, "\(screen)")
        }
    }

    @Test func narrowsToFitASmallScreen() {
        // An 800-point screen, like a virtual machine's: the panel used to be cut off.
        let width = PanelLayout.width(forScreenWidth: 800)
        #expect(width < 800)
        #expect(width + 2 * PanelLayout.screenMargin <= 800)
        #expect(width >= PanelLayout.minimumWidth)
    }

    @Test func neverNarrowerThanItsColumns() {
        #expect(PanelLayout.width(forScreenWidth: 320) == PanelLayout.minimumWidth)
        let columns = CGFloat(PanelLayout.columnCount) * (PanelLayout.columnWidth + PanelLayout.columnSpacing)
        #expect(PanelLayout.minimumWidth > columns + 2 * PanelLayout.padding)
    }
}
