import AppKit
import SwiftUI

/// A small window that sits by System Settings while the person gives an app access
/// back, with the app's icon to drag into the list there.
///
/// Revoking takes an app off a privacy list altogether, so there's no switch left to
/// flip: the app has to be added again, and the list's own way is a + button and a
/// file browser. The lists also take an app dropped on them, so this puts the app
/// within reach. macOS still does the granting, and asks for the person's password or
/// Touch ID as it always does.
@MainActor
final class GrantHelper {
    private var panel: NSPanel?
    private var timer: Timer?
    /// When System Settings' window was last on screen, to tell "not open yet" from "closed".
    private var settingsSeen: Date?
    private var shown = Date()
    /// Set once the icon has been picked up. When it's let go the helper leaves, since
    /// macOS then asks for a password in a sheet the helper could be sitting on.
    private var dragBegan = false

    /// The panes with a list an app can be dropped on.
    static func applies(to pane: Pane) -> Bool {
        [.deviceControl, .screenRecording, .inputMonitoring, .fullDiskAccess].contains(pane)
    }

    /// Where the app is, to drag: its bundle, or the tool itself for one listed by path.
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
                                   dragBegan: { [weak self] in self?.dragBegan = true },
                                   done: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.title = "Give \(name) \(pane.title)"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.setContentSize(hosting.view.fittingSize)
        self.panel = panel
        settingsSeen = nil
        shown = Date()
        dragBegan = false
        place()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if isGranted() { return self.close() }
                // Dropped, on the list or not: macOS takes it from here.
                if self.dragBegan, NSEvent.pressedMouseButtons == 0 { return self.close() }
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
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main)?.visibleFrame ?? settings
        let origin = PanelLayout.helperOrigin(for: size, by: settings, on: screen)
        // Not while the icon is in the air: the drag started from where the window was.
        if !dragBegan, panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// System Settings' main window, in AppKit's coordinates, read from the window list.
    /// The bounds and owner are there for any app to read; only window titles and
    /// contents need Screen Recording.
    private static func settingsFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]], let primary = NSScreen.screens.first else { return nil }
        let frames = list.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerName] as? String == "System Settings", window[kCGWindowLayer] as? Int == 0,
                  let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 300, rect.height > 200
            else { return nil }
            // The window list counts down from the top of the first screen; AppKit counts up.
            return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}

private struct GrantHelperView: View {
    let name: String
    let icon: NSImage
    let app: URL
    let access: String
    let dragBegan: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .padding(8)
                    .background(Color.panelTrack.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.panelSecondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .onDrag {
                        dragBegan()
                        return NSItemProvider(contentsOf: app) ?? NSItemProvider()
                    }
                    .accessibilityLabel("\(name), to drag into the list in System Settings")
                    .accessibilityHint("If dragging isn't for you, choose Show in Finder, then use the Add button under the list.")
                Label("Drag", systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(Color.panelSecondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Drag \(name) into the list in System Settings")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Revoke took \(name) off the \(access) list, so there's no switch to flip. Drop its icon on the list and macOS adds it, switched on.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS asks for your password or Touch ID to finish. If \(name) is still in the list, switch it on there.")
                    .font(.caption)
                    .foregroundStyle(Color.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                        .help("Shows \(name) in Finder, for the Add button under the list or to drag from there.")
                    Spacer()
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
