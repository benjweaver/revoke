import AppKit
import Foundation
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

    @Test func theGroupsCoverEveryColumnInOrder() {
        #expect(PanelLayout.groups.map(\.columns).reduce(0, +) == PanelLayout.columnCount)
        // Running alone, then what only macOS grants, then Revoke's own, then Other and Revoke.
        let panes = Pane.allCases
        #expect(panes.first == .running)
        #expect(Array(panes[1..<5]).allSatisfy { $0.tccService != nil })
        #expect(Array(panes[5..<8]) == [.localNetwork, .internet, .links])
        #expect(panes[8] == .other)
        #expect(PanelLayout.width(ofColumns: 1) == PanelLayout.columnWidth)
        #expect(PanelLayout.width(ofColumns: 3) == 3 * PanelLayout.columnWidth + 2 * PanelLayout.columnSpacing)
    }

    @Test func eachGroupsNoteFitsBesideItsTitle() {
        // The title and note share a line above their columns, so both have to fit it.
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        for group in PanelLayout.groups where !group.title.isEmpty {
            let line = width(group.title, .systemFont(ofSize: size, weight: .semibold)) + PanelLayout.groupNoteSpacing
                + width(group.note, .systemFont(ofSize: size, weight: .medium))
            #expect(line <= PanelLayout.width(ofColumns: group.columns), "\(group.title)")
        }
    }

    @Test func theLongestLineUnderANameFits() {
        // At 800 points this line wrapped, and its row with it.
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
        let longest = ("ChatGPT's computer use agent" as NSString).size(withAttributes: [.font: font]).width
        #expect(longest <= PanelLayout.nameWidth(forPanelWidth: PanelLayout.preferredWidth))
        #expect(PanelLayout.nameWidth(forPanelWidth: PanelLayout.minimumWidth) == PanelLayout.minimumNameWidth - PanelLayout.iconSize - PanelLayout.rowSpacing)
    }

    @Test func timeLeftReadsShortInASwitchAndInFullWhenSpoken() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Allowances.minutesLeft(until: now.addingTimeInterval(38 * 60), now: now) == 38)
        #expect(Allowances.minutesLeft(until: now.addingTimeInterval(20), now: now) == 1)
        #expect(Allowances.minutesLeft(until: now.addingTimeInterval(61), now: now) == 2)
        #expect(Allowances.minutesLeft(until: now.addingTimeInterval(-5), now: now) == 1)
        #expect(Allowances.compact(minutes: 38) == "38m")
        #expect(Allowances.compact(minutes: 99) == "99m")
        #expect(Allowances.compact(minutes: 100) == "2h")
        #expect(Allowances.compact(minutes: 240) == "4h")
        #expect(Allowances.spoken(minutes: 1) == "1 minute")
        #expect(Allowances.spoken(minutes: 38) == "38 minutes")
        #expect(Allowances.spoken(minutes: 60) == "1 hour")
        #expect(Allowances.spoken(minutes: 125) == "2 hours 5 minutes")
    }

    @Test func allowancesDropWhatHasEnded() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let all = Allowances(localNetwork: ["com.example.a": now.addingTimeInterval(-1)],
                             internet: ["com.example.a": now.addingTimeInterval(600), "com.example.b": now.addingTimeInterval(60)])
        let left = all.inForce(at: now)
        #expect(left.localNetwork.isEmpty && left.internet.count == 2 && !left.isEmpty)
        #expect(left.nextEnd == now.addingTimeInterval(60))
        #expect(Allowances().isEmpty && Allowances().nextEnd == nil)
    }

    @Test func allowancesStandWhenTheFilterDoesNotAnswer() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let known = Allowances(localNetwork: ["com.example.a": now.addingTimeInterval(600)],
                               internet: ["com.example.b": now.addingTimeInterval(-1)])
        // No answer: what was known stays, less what has ended since.
        #expect(known.replaced(by: nil, at: now) == Allowances(localNetwork: ["com.example.a": now.addingTimeInterval(600)]))
        // An answer replaces it whole, an empty one included.
        #expect(known.replaced(by: Allowances(), at: now).isEmpty)
        let answer = Allowances(internet: ["com.example.c": now.addingTimeInterval(60)])
        #expect(known.replaced(by: answer, at: now) == answer)
    }

    @Test func theGrantHelperFindsSystemSettingsByProcessNotName() {
        func window(_ pid: Int, _ name: String, layer: Int = 0, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowOwnerName as String: name, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height]]
        }
        let windows = [
            window(7, "Finder", 0, 0, 1400, 900),
            // A sheet, a menu on another layer, then the window itself, named in German.
            window(42, "Systemeinstellungen", 200, 200, 400, 180),
            window(42, "Systemeinstellungen", layer: 101, 0, 0, 900, 700),
            window(42, "Systemeinstellungen", 100, 50, 720, 500),
        ]
        // The list counts down from the top of the first screen; AppKit counts up.
        #expect(PanelLayout.mainWindowFrame(in: windows, ownedBy: [42], primaryScreenHeight: 900)
                == CGRect(x: 100, y: 350, width: 720, height: 500))
        #expect(PanelLayout.mainWindowFrame(in: windows, ownedBy: [], primaryScreenHeight: 900) == nil)
    }

    @Test func staysOnAShortScreen() {
        // A virtual machine's 500-point screen leaves 476 under the menu bar.
        #expect(PanelLayout.maxHeight(forScreenHeight: 476) < 476)
        #expect(PanelLayout.maxHeight(forScreenHeight: 900) == 900 - PanelLayout.screenMargin)
        #expect(PanelLayout.maxHeight(forScreenHeight: 100) == 240)
    }

    @Test func theGrantHelperKeepsOffSystemSettingsWhenItCan() {
        let size = CGSize(width: 440, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 870)
        // Room below: centered under the window.
        var window = CGRect(x: 300, y: 300, width: 720, height: 500)
        var origin = PanelLayout.helperOrigin(for: size, by: window, on: screen)
        #expect(origin == CGPoint(x: 440, y: 92))
        // None below, room to the right.
        window = CGRect(x: 100, y: 60, width: 720, height: 760)
        origin = PanelLayout.helperOrigin(for: size, by: window, on: screen)
        #expect(origin.x == window.maxX + 8 && !CGRect(origin: origin, size: size).intersects(window))
        // Only to the left.
        window = CGRect(x: 700, y: 60, width: 720, height: 760)
        origin = PanelLayout.helperOrigin(for: size, by: window, on: screen)
        #expect(origin.x == window.minX - 8 - size.width && !CGRect(origin: origin, size: size).intersects(window))
        // Nowhere, as on a small screen: over the window's bottom edge, on screen.
        let small = CGRect(x: 0, y: 0, width: 920, height: 550)
        window = CGRect(x: 93, y: 10, width: 740, height: 520)
        origin = PanelLayout.helperOrigin(for: size, by: window, on: small)
        #expect(small.contains(CGRect(origin: origin, size: size)))
    }

    @Test func neverNarrowerThanItsColumns() {
        #expect(PanelLayout.width(forScreenWidth: 320) == PanelLayout.minimumWidth)
        let columns = CGFloat(PanelLayout.columnCount) * (PanelLayout.columnWidth + PanelLayout.columnSpacing)
        #expect(PanelLayout.minimumWidth > columns + 2 * PanelLayout.padding)
    }
}
