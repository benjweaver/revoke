import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: Settings
    private let filter: NetworkFilter
    private let model: AccessModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        settings = Settings()
        filter = NetworkFilter()
        model = AccessModel(settings: settings, filter: filter)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let panel = NSHostingController(rootView: PanelView(model: model, settings: settings, filter: filter) { [weak self] in
            self?.showSettings()
        })
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        popover.behavior = .transient
        NSApp.mainMenu = Self.makeMainMenu()

        // objectWillChange fires before the change lands, so look a turn later.
        model.objectWillChange.merge(with: settings.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &subscriptions)
        updateIcon()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appDidTerminate(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        Task { await Revoker.removeLeftoverStandIns() }
        filter.refresh()
        // Settings open by themselves only the first time, to set Revoke up; after
        // that it starts quietly in the menu bar.
        if !UserDefaults.standard.bool(forKey: "setUp") {
            UserDefaults.standard.set(true, forKey: "setUp")
            showSettings()
        }
    }

    /// Revoke never shows a menu bar of its own, but the main menu's key equivalents
    /// still work, which gives the settings window the standard ⌘W and ⌘Q.
    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Revoke", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }

    /// Opening the app again while it runs (Finder, Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// An open lock while any watched app has Device Control or Screen Recording,
    /// so a glance at the menu bar says whether anything was left on.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = !model.snapshot.canReadTCC ? "lock.trianglebadge.exclamationmark"
            : model.exposedNames.isEmpty ? "lock.fill" : "lock.open.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusText)
        button.toolTip = model.statusText
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Local Network has no change notification, and apps may have been installed
        // or deleted, so read everything fresh.
        AppInfo.forget()
        model.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, model: model, filter: filter))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Revoke"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        model.appDidQuit(app)
    }

    @objc private func willSleep() {
        model.sleepOrLock(reason: "the Mac went to sleep")
    }

    @objc private func screenLocked() {
        model.sleepOrLock(reason: "the screen locked")
    }
}
