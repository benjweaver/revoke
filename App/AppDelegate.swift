import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: Settings
    private let filter: NetworkFilter
    private let model: AccessModel
    private let prompt: LinkPrompt
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    /// Watches for clicks in other apps while the panel is open.
    private var outsideClicks: Any?
    /// Keeps the Running column current while the panel is open: what an app started,
    /// like an agent's shells, only shows up in a look at every process.
    private var runningTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        settings = Settings()
        filter = NetworkFilter()
        model = AccessModel(settings: settings, filter: filter)
        prompt = LinkPrompt(settings: settings)
        super.init()
        prompt.onActivity = { [weak model] in model?.note($0) }
    }

    /// macOS opened Revoke for a link or a file it stands in for. The Apple event says
    /// which process asked, so the question can name it.
    func application(_ application: NSApplication, open urls: [URL]) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let sender = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        prompt.receive(urls, sender: sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        // A right click shows a menu instead of the panel.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let panel = NSHostingController(rootView: PanelView(model: model, settings: settings, filter: filter) { [weak self] in
            self?.showSettings()
        })
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self
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

    /// An open lock while any watched app is running or can control the Mac or see
    /// what's on it, so a glance at the menu bar says whether anything was left on.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isOpen = !model.exposedNames.isEmpty || !model.runningNames.isEmpty
        let symbol = !model.snapshot.canReadTCC ? "lock.trianglebadge.exclamationmark"
            : isOpen ? "lock.open.fill" : "lock.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusText)
        button.toolTip = !model.snapshot.canReadTCC ? "Revoke: \(model.statusText)"
            : isOpen ? "Revoke: \(model.statusText). The lock stays open until no watched app is running or has access."
            : "Revoke: \(model.statusText). No watched app is running or has access."
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(nil)
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Local Network has no change notification, and apps may have been installed
        // or deleted, so read everything fresh.
        AppInfo.forget()
        model.refresh()
        model.refreshRunning()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A transient popover only closes on outside clicks while Revoke is the
        // active app, and macOS may turn down the activation, so close it here too.
        // Global monitors see only other apps' events: clicks in the panel and on
        // the menu bar icon still go to them.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshRunning() }
        }
        RunLoop.main.add(timer, forMode: .common)
        runningTimer = timer
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Revoke All Watched", action: #selector(revokeAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop All Apps", action: #selector(stopAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Revoke", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func revokeAll() { model.revokeWatched(reason: nil) }

    @objc private func stopAll() { model.stopAll() }

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

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        Tooltip.shared.hide()
        runningTimer?.invalidate()
        runningTimer = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
}
