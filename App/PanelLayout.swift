import CoreGraphics

/// The panel's measurements, shared by PanelView and its tests.
enum PanelLayout {
    /// Width of each privacy list's column, shared by the titles and the rows so
    /// they line up even though the rows scroll.
    static let columnWidth: CGFloat = 56
    static let columnSpacing: CGFloat = 4
    static let padding: CGFloat = 16
    /// Wide enough for every column and a long app name.
    static let preferredWidth: CGFloat = 800
    /// Room for the popover's border and its gap from the screen's edges.
    static let screenMargin: CGFloat = 24
    /// The shortest app name column worth showing; names truncate in the middle.
    static let minimumNameWidth: CGFloat = 120

    /// The narrowest the panel gets: every column, the padding, and a short name.
    static var minimumWidth: CGFloat {
        2 * padding + minimumNameWidth + CGFloat(Pane.allCases.count) * (columnWidth + columnSpacing)
    }

    /// The panel's width on a screen this wide. On a narrow screen, such as a small
    /// display mode or a virtual machine, the panel narrows and app names give way,
    /// rather than macOS clipping the panel's right edge.
    static func width(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        min(preferredWidth, max(minimumWidth, screenWidth - 2 * screenMargin))
    }
}
