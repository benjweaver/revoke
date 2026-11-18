import AppKit
import SwiftUI

/// A small window that sits by System Settings while the person gives an app access
/// back, with the steps for adding it to the list there.
///
/// Revoking takes an app off a privacy list altogether, so there's no switch left to
/// flip: the app has to be added again, with the list's + button and a file browser.
/// Finding an agent's app in that browser is the slow part, and some live deep in a
/// Library folder, so this hands over the app's location to paste into the browser's
/// Go to Folder. macOS still does the granting, and asks for the person's password or
/// Touch ID as it always does.
///
/// An earlier version had the app's icon to drag onto the list. macOS 27.3 stops
/// taking apps dropped there, so the steps go by the keyboard, which works on every
/// version and for people who don't drag.
@MainActor
final class GrantHelper {
    private var panel: NSPanel?
    private var timer: Timer?
    /// When System Settings' window was last on screen, to tell "not open yet" from "closed".
    private var settingsSeen: Date?
    private var shown = Date()
    /// Where the helper last put itself. Once the person has moved it somewhere else,
    /// it stays where they put it: the sheets macOS shows next may need the room.
    private var placedAt: NSPoint?
    private var movedByPerson = false

    /// The panes with a list an app can be added to.
    static func applies(to pane: Pane) -> Bool {
        [.deviceControl, .screenRecording, .inputMonitoring, .fullDiskAccess].contains(pane)
    }

    /// Where the app is: its bundle, or the tool itself for one listed by path.
    static func location(of client: Client) -> URL? {
        switch client {
        case .bundle(let id): NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        case .path(let path): FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
    }

    /// Shows the helper for one app and one kind of access, in place of any before it.
    /// `isGranted` is asked now and then, and the helper leaves once it says yes.
    func show(for client: Client, pane: Pane, isGranted: @escaping @MainActor () -> Bool) {
        close()
        guard Self.applies(to: pane), let app = Self.location(of: client) else { return }
        let name = AppInfo.name(client)
        let view = GrantHelperView(name: name, icon: AppInfo.icon(client), app: app, access: pane.title,
                                   done: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.title = "Add \(name) to \(pane.title)"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.setContentSize(hosting.view.fittingSize)
        self.panel = panel
        settingsSeen = nil
        shown = Date()
        placedAt = nil
        movedByPerson = false
        place()
        panel.orderFrontRegardless()
        // The helper never takes the keyboard from System Settings, so VoiceOver
        // wouldn't come across it. This says what to do there.
        Announcement.post("To give \(name) \(pane.title) back, press the Add button under the list in System Settings, then Shift Command G, and paste \(name)'s location. Revoke's helper window has a button that copies it.",
                          isUrgent: true)

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Closed with its own close button: nothing is left to keep in place.
                guard self.panel?.isVisible == true else { return self.close() }
                if isGranted() { return self.close() }
                self.place()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.close()
        panel = nil
    }

    /// Keeps the helper by System Settings' window and follows it when it moves: under
    /// it, or beside it, wherever there's room on the screen, and over its bottom edge
    /// only when there's none. Leaves when that window has gone, or never came.
    private func place() {
        guard let panel else { return }
        let now = Date()
        guard let settings = Self.settingsFrame() else {
            let waitedFrom = settingsSeen ?? shown
            // A moment for System Settings to open, or to come back from another pane.
            if now.timeIntervalSince(waitedFrom) > (settingsSeen == nil ? 15 : 3) { close() }
            else if settingsSeen == nil, let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 40))
            }
            return
        }
        settingsSeen = now
        if let placedAt, panel.frame.origin != placedAt { movedByPerson = true }
        guard !movedByPerson else { return }
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main)?.visibleFrame ?? settings
        let origin = PanelLayout.helperOrigin(for: size, by: settings, on: screen)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        placedAt = panel.frame.origin
    }

    /// System Settings' main window, in AppKit's coordinates, read from the window list.
    /// The bounds and owner are there for any app to read; only window titles and
    /// contents need Screen Recording. The owner is matched by process: its name in
    /// the list is in the person's language, and the bundle ID is the same in all.
    private static func settingsFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], let primary = NSScreen.screens.first else { return nil }
        let owners = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map { Int($0.processIdentifier) }
        return PanelLayout.mainWindowFrame(in: list, ownedBy: Set(owners), primaryScreenHeight: primary.frame.maxY)
    }
}

private struct GrantHelperView: View {
    let name: String
    let icon: NSImage
    let app: URL
    let access: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add \(name) back in System Settings")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Revoke took \(name) off the \(access) list, so there's no switch to flip.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click + under the list. macOS asks for your password or Touch ID.")
                    step(2, "Press \u{21E7}\u{2318}G, paste the location below with \u{2318}V, and press Return.",
                         spoken: "Press Shift Command G, paste the location below with Command V, and press Return.")
                    step(3, "Click Open. \(name) joins the list, switched on.")
                }
                HStack(spacing: 8) {
                    Text(app.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.panelTrack.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("\(name)'s location: \(app.path)")
                    Button(copied ? "Copied" : "Copy Location") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.path, forType: .string)
                        copied = true
                        Announcement.post("Copied \(name)'s location")
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Copies where \(name) is, to paste after pressing \u{21E7}\u{2318}G in the window the + button opens.")
                }
                Text("If \(name) is still in the list, switch it on there instead.")
                    .font(.caption)
                    .foregroundStyle(Color.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                        .help("Shows \(name) in Finder, if you'd rather find it by browsing.")
                    Spacer()
                    Button("Done", action: done)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        // Escape puts the helper away, as Done does.
        .onExitCommand(perform: done)
    }

    /// One numbered step. The numbers are real: these happen in order.
    private func step(_ number: Int, _ text: String, spoken: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(Color.panelSecondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(spoken ?? text)")
    }
}
