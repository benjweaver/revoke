import CoreGraphics

/// The panel's measurements, shared by PanelView and its tests.
enum PanelLayout {
    /// Width of each privacy list's column, shared by the titles and the rows so
    /// they line up even though the rows scroll.
    static let columnWidth: CGFloat = 56
    static let columnSpacing: CGFloat = 4
    static let padding: CGFloat = 16
    /// Each Pane column plus the horizontal All Access column.
    static let columnCount = Pane.allCases.count + 1
    /// Wide enough for every column and a long app name.
    static let preferredWidth: CGFloat = 800
    /// Room for the popover's border and its gap from the screen's edges.
    static let screenMargin: CGFloat = 24
    /// The shortest app name column worth showing; names truncate in the middle.
    static let minimumNameWidth: CGFloat = 120

    /// Columns that behave alike, left to right, with the title and note that go above
    /// each run of them. Running stands alone and has neither.
    static let groups: [(title: String, note: String, tip: String, columns: Int)] = [
        ("", "", "", 1),
        ("macOS privacy", "Turn on in System Settings",
         "Revoke can switch these off. Switching one on opens System Settings, because macOS only lets you grant access there.", 4),
        ("Kept by Revoke", "Switch both ways",
         "Revoke keeps these itself, so they switch on and off right here.", 3),
        ("Take back", "Reset or switch off",
         "These only ever take access away.", 2),
    ]

    /// How wide a run of columns is, with the gaps between them.
    static func width(ofColumns count: Int) -> CGFloat {
        CGFloat(count) * columnWidth + CGFloat(max(count - 1, 0)) * columnSpacing
    }

    /// The tallest the panel gets on a screen this tall, less the menu bar: it hangs
    /// below the menu bar and keeps a gap from the bottom.
    static func maxHeight(forScreenHeight screenHeight: CGFloat) -> CGFloat {
        max(240, screenHeight - screenMargin)
    }

    /// The narrowest the panel gets: every column, the padding, and a short name.
    static var minimumWidth: CGFloat {
        2 * padding + minimumNameWidth + CGFloat(columnCount) * (columnWidth + columnSpacing)
    }

    /// The panel's width on a screen this wide. On a narrow screen, such as a small
    /// display mode or a virtual machine, the panel narrows and app names give way,
    /// rather than macOS clipping the panel's right edge.
    static func width(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        min(preferredWidth, max(minimumWidth, screenWidth - 2 * screenMargin))
    }
}
