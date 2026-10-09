import AppKit
import Combine
import notify
import os

private let log = Logger(subsystem: "dev.benjweaver.Revoke", category: "revoke")

/// One app's line in the panel.
struct Row: Identifiable {
    let client: Client
    let name: String
    let icon: NSImage
    let entries: [Pane: Entry]
    /// When the time limit will revoke this app's access.
    let deadline: Date?
    /// Revoke's network filter is keeping the app off the local network, whatever
    /// macOS's own Local Network switch says.
    let isBlockedFromLocalNetwork: Bool

    var id: Client { client }

    func isAllowed(_ pane: Pane) -> Bool {
        if pane == .localNetwork && isBlockedFromLocalNetwork { return false }
        return entries[pane]?.access == .allowed
    }
}

struct Activity {
    let date = Date()
    let text: String
    let isError: Bool
}

/// What the privacy lists say right now, and everything that revokes access.
@MainActor
final class AccessModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var lastActivity: Activity?
    @Published private(set) var isRevoking = false
    /// Bundle IDs of the apps running now, so the lock and the panel's dots follow
    /// apps as they launch and quit, even while the panel is open.
    @Published private(set) var runningIDs = Set<String>()

    private let settings: Settings
    let filter: NetworkFilter
    private var notifyToken = NOTIFY_TOKEN_INVALID
    private var deadlineTimer: Timer?
    /// Revocations run one at a time, in the order they were asked for.
    private var queue: Task<Void, Never>?
    private var pending = 0
    private var runningApps: AnyCancellable?

    init(settings: Settings, filter: NetworkFilter) {
        self.settings = settings
        self.filter = filter
        // Whenever the filter (re)starts, it gets the whole list again.
        filter.onReady = { [weak self] in self?.sendBlocklist() }
        // tccd posts this whenever any app's access changes, in either database.
        notify_register_dispatch("com.apple.tcc.access.changed", &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        settings.onChange = { [weak self] in self?.refresh() }
        // KVO reports the list after it changes, so an app that just quit is gone.
        runningApps = NSWorkspace.shared.publisher(for: \.runningApplications, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apps in
                let ids = Set(apps.compactMap(\.bundleIdentifier))
                if ids != self?.runningIDs { self?.runningIDs = ids }
            }
        refresh()
    }

    func refresh() {
        var next = Snapshot()
        if let rows = TCCDatabase.read() {
            next.canReadTCC = true
            for (client, pane, entry) in rows { next.entries[client, default: [:]][pane] = entry }
        }
        if let decisions = LocalNetworkStore.read() {
            next.canReadLocalNetwork = true
            for (client, access) in decisions {
                next.entries[client, default: [:]][.localNetwork] = Entry(access: access)
            }
        }
        if next != snapshot { snapshot = next }
        enforceTimeLimit()
    }

    // MARK: - Reading

    /// Installed watched apps in any list, or other apps that have Device Control or
    /// Screen Recording, sorted by name. Apps that only use the local network aren't
    /// a worry worth a row unless they're watched.
    func rows(watched: Bool) -> [Row] {
        var all = snapshot.entries
        // Without Full Disk Access, apps watched by choice still get a row of question marks.
        if watched && !snapshot.canReadTCC {
            for client in settings.addedClients where all[client] == nil { all[client] = [:] }
        }
        return makeRows(all.filter { client, entries in
            guard settings.isWatched(client) == watched, !isMissing(client), !isHidden(client) else { return false }
            return watched || entries[.deviceControl]?.access == .allowed
                || entries[.screenRecording]?.access == .allowed
        })
    }

    /// Deleted apps whose Device Control or Screen Recording entries stayed behind.
    /// macOS keeps them when an app is deleted, or replaced by one with a new bundle ID.
    var leftoverRows: [Row] {
        makeRows(snapshot.entries.filter { client, entries in
            isMissing(client) && (entries[.deviceControl] != nil || entries[.screenRecording] != nil)
        })
    }

    /// A deleted app, whose entries can go. Parts of macOS can't be found the way
    /// apps can (the Screen Sharing agent is a plain bundle Launch Services doesn't
    /// list), so they never count: macOS grants their access again on its own.
    private func isMissing(_ client: Client) -> Bool {
        client.bundleID != nil && !AppInfo.isInstalled(client) && !isAppleSystem(client)
    }

    /// Parts of macOS that aren't apps, which System Settings doesn't list either.
    private func isHidden(_ client: Client) -> Bool {
        isAppleSystem(client) && !AppInfo.isInstalled(client)
    }

    private func isAppleSystem(_ client: Client) -> Bool {
        snapshot.entries[client]?.values.contains(where: \.isAppleSystem) ?? false
    }

    private func makeRows(_ entries: [Client: [Pane: Entry]]) -> [Row] {
        entries.map { client, entries in
            Row(client: client, name: AppInfo.name(client), icon: AppInfo.icon(client),
                entries: entries, deadline: deadline(for: entries),
                isBlockedFromLocalNetwork: isBlockedFromLocalNetwork(client))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Installed watched apps that have Device Control or Screen Recording right now.
    var exposedNames: [String] {
        rows(watched: true)
            .filter { $0.isAllowed(.deviceControl) || $0.isAllowed(.screenRecording) }
            .map(\.name)
    }

    /// Watched apps that are running now.
    var runningNames: [String] {
        runningIDs.filter { settings.isWatched(.bundle($0)) }.map { AppInfo.name(.bundle($0)) }
    }

    /// Whether the app is running now, for the dot under its icon in the panel.
    func isRunning(_ client: Client) -> Bool {
        client.bundleID.map(runningIDs.contains) ?? false
    }

    var statusText: String {
        guard snapshot.canReadTCC else { return "Needs Full Disk Access to show status" }
        let exposed = exposedNames
        if !exposed.isEmpty {
            return "\(exposed.formatted(.list(type: .and))) \(exposed.count == 1 ? "has" : "have") access"
        }
        let running = Set(runningNames).sorted()
        if !running.isEmpty { return "\(running.formatted(.list(type: .and))) \(running.count == 1 ? "is" : "are") running" }
        return "Watched apps are locked down"
    }

    /// Every installed app the settings could list, watched ones first.
    var knownClients: [Client] {
        Set(snapshot.entries.keys).union(settings.addedClients).filter { !isMissing($0) && !isHidden($0) }.sorted {
            let (a, b) = (settings.isWatched($0), settings.isWatched($1))
            if a != b { return a }
            return AppInfo.name($0).localizedStandardCompare(AppInfo.name($1)) == .orderedAscending
        }
    }

    /// Whether the network filter is keeping an app off the local network now.
    func isBlockedFromLocalNetwork(_ client: Client) -> Bool {
        filter.isOn && client.bundleID.map(settings.localNetworkBlocked.contains) == true
    }

    // MARK: - Changing access

    /// A switch in the panel. Only System Settings can grant access, and only it
    /// can change command-line tools, so those open it. Local Network is Revoke's
    /// own block once the network filter is on, and System Settings' switch before.
    func set(_ pane: Pane, on: Bool, for client: Client) {
        if pane == .localNetwork, filter.isOn, let id = client.bundleID {
            let name = AppInfo.name(client)
            if on {
                settings.allowLocalNetwork(id)
                lastActivity = Activity(text: "Stopped blocking Local Network for \(name)", isError: false)
                // macOS's own switch has to be on too.
                if snapshot.entries[client]?[.localNetwork]?.access != .allowed {
                    NSWorkspace.shared.open(pane.settingsURL)
                }
            } else {
                settings.blockLocalNetwork([id])
                lastActivity = Activity(text: "Blocked Local Network for \(name)", isError: false)
            }
            log.notice("\(self.lastActivity?.text ?? "", privacy: .public)")
            sendBlocklist()
        } else if !on, !pane.tccutilServices.isEmpty, client.bundleID != nil {
            revoke([client], panes: [pane], reason: nil)
        } else {
            NSWorkspace.shared.open(pane.settingsURL)
        }
    }

    /// Revokes Device Control and Screen & System Audio Recording for every
    /// watched app, or only those from one developer. That includes what deleted
    /// watched apps left behind.
    func revokeWatched(vendor: String? = nil, reason: String?) {
        var clients = Set(snapshot.entries.keys.filter(settings.isWatched))
        clients.formUnion(settings.addedClients)
        if let vendor { clients = clients.filter { $0.vendor == vendor } }
        revoke(Array(clients), panes: Pane.allCases, reason: reason)
    }

    /// Clears the entries deleted apps left behind, all of them or the ones given.
    func removeLeftovers(_ clients: [Client]? = nil) {
        revoke(clients ?? leftoverRows.map(\.client), panes: [.deviceControl, .screenRecording], reason: nil)
    }

    private func sendBlocklist() {
        filter.send(blocked: settings.localNetworkBlocked.sorted())
    }

    /// `reason` finishes "Revoked access for … when …"; nil means the person asked.
    func revoke(_ clients: [Client], panes: [Pane], reason: String?) {
        let ids = clients.compactMap(\.bundleID).sorted()
        guard !ids.isEmpty else { return }
        // Notice level keeps a record: log show --predicate 'subsystem == "dev.benjweaver.Revoke"'
        log.notice("Revoking \(panes.map(\.shortTitle), privacy: .public) for \(ids, privacy: .public)")
        pending += 1
        isRevoking = true
        let previous = queue
        queue = Task {
            await previous?.value
            await perform(ids: ids, panes: panes, reason: reason)
            pending -= 1
            isRevoking = pending > 0
            if pending == 0 { enforceTimeLimit() }
        }
    }

    private func perform(ids: [String], panes: [Pane], reason: String?) async {
        refresh()
        let before = snapshot
        // Local Network is the network filter's block, for installed apps.
        var newlyBlocked: Set<String> = []
        if panes.contains(.localNetwork), filter.isOn {
            newlyBlocked = Set(ids.filter { !isMissing(.bundle($0)) }).subtracting(settings.localNetworkBlocked)
            settings.blockLocalNetwork(newlyBlocked)
            sendBlocklist()
        }
        let services = panes.flatMap(\.tccutilServices)
        var failures: [String: String] = [:]
        for id in ids {
            let client = Client.bundle(id)
            if let error = await Revoker.reset(services, for: id, installed: !isMissing(client)) {
                log.error("tccutil reset \(services, privacy: .public) \(id, privacy: .public): \(error, privacy: .public)")
                failures[AppInfo.name(client)] = error
            }
        }
        refresh()

        // Report what changed: installed apps that lost access, and deleted apps
        // whose entries are gone.
        var revoked: [String] = []
        var cleared = 0
        for client in ids.map(Client.bundle) {
            if isMissing(client) {
                if panes.contains(where: { before.entries[client]?[$0] != nil && snapshot.entries[client]?[$0] == nil }) {
                    cleared += 1
                }
            } else if panes.contains(where: {
                before.entries[client]?[$0]?.access == .allowed && snapshot.entries[client]?[$0]?.access != .allowed
            }) || client.bundleID.map(newlyBlocked.contains) == true
                && before.entries[client]?[.localNetwork]?.access == .allowed {
                revoked.append(AppInfo.name(client))
            }
        }
        let what = panes.count == 1 ? panes[0].shortTitle : "access"
        var changes: [String] = []
        if !revoked.isEmpty { changes.append("revoked \(what) for \(revoked.formatted(.list(type: .and)))") }
        if cleared > 0 { changes.append("cleared what \(cleared) deleted \(cleared == 1 ? "app" : "apps") left behind") }

        var text: String
        if let failure = failures.min(by: { $0.key < $1.key }) {
            text = "Couldn't revoke \(what) for \(failure.key): \(failure.value)"
        } else if !before.canReadTCC {
            text = "Revoked \(what) for watched apps"
        } else if changes.isEmpty {
            // Automatic runs often find nothing to do; only answer a click.
            guard reason == nil else { return }
            text = "Nothing to revoke"
        } else {
            let sentence = changes.joined(separator: " and ")
            text = sentence.prefix(1).uppercased() + sentence.dropFirst()
        }
        if let reason { text += " when \(reason)" }
        log.notice("\(text, privacy: .public)")
        lastActivity = Activity(text: text, isError: !failures.isEmpty)
    }

    // MARK: - Automatic revoking

    /// Quitting a watched app revokes every watched app from its developer, once
    /// none of that developer's watched apps still have windows open. Quitting
    /// ChatGPT also covers Codex Computer Use, which runs in the background.
    func appDidQuit(_ app: NSRunningApplication) {
        guard settings.revokeOnQuit, app.activationPolicy == .regular,
              let id = app.bundleIdentifier, settings.isWatched(.bundle(id)),
              let vendor = Client.bundle(id).vendor else { return }
        let othersOpen = NSWorkspace.shared.runningApplications.contains { other in
            guard other.processIdentifier != app.processIdentifier, other.activationPolicy == .regular,
                  let otherID = other.bundleIdentifier else { return false }
            let client = Client.bundle(otherID)
            return client.vendor == vendor && settings.isWatched(client)
        }
        guard !othersOpen else { return }
        revokeWatched(vendor: vendor, reason: "\(AppInfo.name(.bundle(id))) quit")
    }

    func sleepOrLock(reason: String) {
        guard settings.revokeOnSleepOrLock else { return }
        revokeWatched(reason: reason)
    }

    private func deadline(for entries: [Pane: Entry]) -> Date? {
        [Pane.deviceControl, .screenRecording].compactMap { deadline(for: entries[$0]) }.min()
    }

    private func deadline(for entry: Entry?) -> Date? {
        guard settings.revokeAfterLimit, let entry, entry.access == .allowed, let since = entry.since
        else { return nil }
        return max(since, settings.limitStart).addingTimeInterval(TimeInterval(settings.limitMinutes * 60))
    }

    /// Revokes whatever is past its time limit and sets a timer for the next one.
    /// While a revocation is running this waits; it runs again when the queue empties.
    private func enforceTimeLimit() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard settings.revokeAfterLimit, pending == 0 else { return }

        let now = Date()
        var next: Date?
        for (client, entries) in snapshot.entries where client.bundleID != nil && settings.isWatched(client) {
            var due: [Pane] = []
            for pane in [Pane.deviceControl, .screenRecording] {
                guard let deadline = deadline(for: entries[pane]) else { continue }
                if deadline <= now { due.append(pane) } else { next = min(next ?? deadline, deadline) }
            }
            if !due.isEmpty { revoke([client], panes: due, reason: "its time limit ran out") }
        }

        if let next {
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            deadlineTimer = timer
        }
    }
}
