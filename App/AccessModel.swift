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
    /// The same, with helpers counted as the app they're inside, so the status says
    /// "Claude is running" rather than "Claude and Claude Helper are running".
    @Published private(set) var runningAppIDs = Set<String>()

    private let settings: Settings
    let filter: NetworkFilter
    private var notifyToken = NOTIFY_TOKEN_INVALID
    private var deadlineTimer: Timer?
    /// Revocations run one at a time, in the order they were asked for.
    private var queue: Task<Void, Never>?
    private var pending = 0
    private var runningApps: AnyCancellable?
    /// Watched apps with something running, by bundle ID, for Stop App.
    @Published private(set) var stoppableIDs = Set<String>()
    /// Checks that apps haven't taken their links back from Revoke.
    private var linkTimer: Timer?

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
                let appIDs = Set(apps.compactMap { Self.containingAppID($0) ?? $0.bundleIdentifier })
                if ids != self?.runningIDs { self?.runningIDs = ids }
                if appIDs != self?.runningAppIDs { self?.runningAppIDs = appIDs }
            }
        // Apps make themselves their links' handler again (ChatGPT each time it starts,
        // Claude Code daily), so look every couple of seconds while Revoke stands in.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.settings.linksBlocked.isEmpty, self.pending == 0 else { return }
                self.keepLinksBlocked()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        linkTimer = timer
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
        next.links = readLinks(known: next.entries.keys)
        for (client, links) in next.links {
            next.entries[client, default: [:]][.links] = Entry(access: links.open.isEmpty ? .denied : .allowed)
        }
        if next != snapshot { snapshot = next }
        enforceTimeLimit()
    }

    /// Looks for the watched apps that have something running, for Stop App. That takes
    /// a look at every process, so it's done when the panel opens rather than each refresh.
    func refreshRunning() {
        let stoppable = Set(Processes.pids(of: watchedBundleIDs).keys)
        if stoppable != stoppableIDs { stoppableIDs = stoppable }
    }

    /// Each app's links: the ones other apps can open it with, and the ones Revoke
    /// stands in for. Apps are looked for among those in the privacy lists, watched by
    /// choice or by default, running, or that Revoke holds links for.
    private func readLinks(known: some Sequence<Client>) -> [Client: AppLinks] {
        var ids = Set(known.compactMap(\.bundleID))
        ids.formUnion(settings.addedClients.compactMap(\.bundleID))
        ids.formUnion(runningAppIDs.filter { settings.isWatched(.bundle($0)) })
        ids.formUnion(settings.linksBlocked)
        ids.formUnion(settings.linkOwners.values.map(\.bundleID))
        ids.formUnion(AppInfo.knownLinkApps)
        let me = Bundle.main.bundleIdentifier
        var result: [Client: AppLinks] = [:]
        for id in ids {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            var links = AppLinks()
            for link in AppInfo.declaredLinks(app) {
                guard let handler = Links.handler(for: link), let handlerID = Links.bundleID(ofAppAt: handler) else { continue }
                if handlerID == id {
                    links.open.append(link)
                } else if handlerID == me, settings.linkOwners[link]?.bundleID == id {
                    links.guarded.append(link)
                }
            }
            if links.isEmpty { continue }
            let client = Client.bundle(AppInfo.linkClient(id))
            result[client, default: AppLinks()].merge(links)
        }
        return result
    }

    /// Every watched app, by bundle ID, running or in a list.
    private var watchedBundleIDs: [String] {
        Set(snapshot.entries.keys).union(settings.addedClients).union(runningAppIDs.map(Client.bundle))
            .filter(settings.isWatched).compactMap(\.bundleID)
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
            if !watched && settings.hidden.contains(client.key) { return false }
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

    /// Watched apps that are running now, helpers counted as their app.
    var runningNames: [String] {
        runningAppIDs.filter { settings.isWatched(.bundle($0)) }.map { AppInfo.name(.bundle($0)) }
    }

    /// The outermost app a helper sits inside, such as Claude.app for Claude Helper.
    private nonisolated static func containingAppID(_ app: NSRunningApplication) -> String? {
        guard let path = app.bundleURL?.path, let end = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<end.lowerBound]) + ".app")?.bundleIdentifier
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
        if pane == .links {
            if on { giveLinksBack([client]) } else { revoke([client], panes: [.links], reason: nil) }
        } else if pane == .localNetwork, filter.isOn, let id = client.bundleID {
            let name = AppInfo.name(client)
            if on {
                settings.allowLocalNetwork(id)
                lastActivity = Activity(text: "Stopped blocking Local Network for \(name)", isError: false)
                // macOS's own switch has to be on too.
                if snapshot.entries[client]?[.localNetwork]?.access != .allowed, let url = pane.settingsURL {
                    NSWorkspace.shared.open(url)
                }
            } else {
                settings.blockLocalNetwork([id])
                lastActivity = Activity(text: "Blocked Local Network for \(name)", isError: false)
            }
            log.notice("\(self.lastActivity?.text ?? "", privacy: .public)")
            sendBlocklist()
        } else if !on, !pane.tccutilServices.isEmpty, client.bundleID != nil {
            revoke([client], panes: [pane], reason: nil)
        } else if let url = pane.settingsURL {
            NSWorkspace.shared.open(url)
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
        enqueue { await self.perform(ids: ids, panes: panes, reason: reason) }
    }

    /// Runs after everything already asked for, one thing at a time.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        pending += 1
        isRevoking = true
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
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
        var failures: [String: String] = [:]
        // Links. Automatic runs leave file types be: macOS asks the person to confirm
        // each one, and nobody may be there to answer.
        if panes.contains(.links) {
            for id in ids where !isMissing(.bundle(id)) {
                if let error = await takeLinks(of: .bundle(id), files: reason == nil) {
                    failures[AppInfo.name(.bundle(id))] = error
                }
            }
        }
        let services = panes.flatMap(\.tccutilServices)
        for id in ids where !services.isEmpty {
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
        if !revoked.isEmpty {
            changes.append(panes == [.links] ? "switched Links off for \(revoked.formatted(.list(type: .and)))"
                : "revoked \(what) for \(revoked.formatted(.list(type: .and)))")
        }
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

    /// Something worth a line in the panel that happened outside the model.
    func note(_ text: String) {
        lastActivity = Activity(text: text, isError: false)
    }

    // MARK: - Links

    /// Makes Revoke the handler for every link the app opens itself, saving which app
    /// had each to give back. Returns why something failed, if it did.
    private func takeLinks(of client: Client, files: Bool) async -> String? {
        guard let id = client.bundleID, let links = snapshot.links[client] else { return nil }
        settings.setLinksBlocked(id, true)
        var error: String?
        for link in links.open where files || !link.isFile {
            do {
                if let owner = try await Links.take(link, for: Bundle.main.bundleURL) {
                    settings.setLinkOwner(owner, for: link)
                    log.notice("Took \(link.description, privacy: .public) from \(owner.bundleID, privacy: .public)")
                }
            } catch let failure {
                log.error("Couldn't take \(link.description, privacy: .public): \(failure.localizedDescription, privacy: .public)")
                error = error ?? failure.localizedDescription
            }
        }
        refresh()
        return error
    }

    /// Gives apps back the links Revoke stands in for, and stops asking about them.
    func giveLinksBack(_ clients: [Client]) {
        enqueue { await self.performGiveLinksBack(clients) }
    }

    /// Every app's links, as when Revoke is about to be removed.
    func giveAllLinksBack() {
        let clients = Set(settings.linksBlocked.map(Client.bundle))
            .union(settings.linkOwners.values.map { .bundle(AppInfo.linkClient($0.bundleID)) })
        enqueue { await self.performGiveLinksBack(Array(clients), all: true) }
    }

    private func performGiveLinksBack(_ clients: [Client], all: Bool = false) async {
        let ids = Set(clients.compactMap(\.bundleID))
        for id in ids { settings.setLinksBlocked(id, false) }
        let mine = settings.linkOwners.filter { ids.contains(AppInfo.linkClient($0.value.bundleID)) }
        let (restored, failure) = await Self.restore(mine, settings: settings)
        refresh()
        let names = ids.map { AppInfo.name(.bundle($0)) }.sorted()
        let text: String
        if let failure {
            text = "Couldn't give every link back: \(failure)"
        } else if all {
            text = restored == 0 ? "No app's links needed giving back" : "Gave every app its links back"
        } else {
            text = "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "opens" : "open") from links and files again"
        }
        log.notice("\(text, privacy: .public)")
        lastActivity = Activity(text: text, isError: failure != nil)
    }

    /// Gives each link back to its app, where Revoke still has it. Returns how many
    /// went back, and why one didn't.
    static func restore(_ owners: [Link: LinkOwner], settings: Settings) async -> (Int, String?) {
        let me = Bundle.main.bundleIdentifier
        var restored = 0
        var failure: String?
        for (link, owner) in owners.sorted(by: { $0.key < $1.key }) {
            // Something else took it since; it isn't Revoke's to give.
            guard let handler = Links.handler(for: link), Links.bundleID(ofAppAt: handler) == me else {
                settings.setLinkOwner(nil, for: link)
                continue
            }
            do {
                try await Links.restore(link, to: owner)
                settings.setLinkOwner(nil, for: link)
                restored += 1
                log.notice("Gave \(link.description, privacy: .public) back to \(owner.bundleID, privacy: .public)")
            } catch {
                log.error("Couldn't give \(link.description, privacy: .public) back: \(error.localizedDescription, privacy: .public)")
                failure = failure ?? error.localizedDescription
            }
        }
        return (restored, failure)
    }

    /// Takes link schemes back from apps that made themselves their handler again, as
    /// ChatGPT does each time it starts. File types are left, since macOS would ask
    /// the person out of nowhere; the switch shows they're open again.
    private func keepLinksBlocked() {
        // Only links can have changed hands in between, so look at those first.
        guard readLinks(known: snapshot.entries.keys) != snapshot.links else { return }
        refresh()
        let retaken = snapshot.links.filter { client, links in
            client.bundleID.map(settings.linksBlocked.contains) == true && links.open.contains { !$0.isFile }
        }
        guard !retaken.isEmpty else { return }
        enqueue {
            var names: [String] = []
            for client in retaken.keys.sorted(by: { $0.key < $1.key }) {
                let before = self.snapshot.links[client]?.open.filter { !$0.isFile } ?? []
                _ = await self.takeLinks(of: client, files: false)
                if self.snapshot.links[client]?.open.filter({ !$0.isFile }) != before { names.append(AppInfo.name(client)) }
            }
            guard !names.isEmpty else { return }
            let text = "\(names.formatted(.list(type: .and))) registered \(names.count == 1 ? "its" : "their") links again, so Revoke took them back"
            log.notice("\(text, privacy: .public)")
            self.lastActivity = Activity(text: text, isError: false)
        }
    }

    // MARK: - Stopping apps

    /// Stops the app, its helpers, and everything they started.
    func stop(_ client: Client) {
        guard let id = client.bundleID else { return }
        enqueue { await self.performStop([id], none: "\(AppInfo.name(client)) isn't running") }
    }

    /// Stops every watched app that way, and leaves their switches as they are.
    func stopAll() {
        let ids = watchedBundleIDs
        enqueue { await self.performStop(ids, none: "No watched apps are running") }
    }

    private func performStop(_ ids: [String], none: String) async {
        let found = Processes.pids(of: ids)
        guard !found.isEmpty else {
            lastActivity = Activity(text: none, isError: false)
            return
        }
        let count = await Processes.stop(found.values.reduce(into: Set()) { $0.formUnion($1) })
        let names = found.keys.map { AppInfo.name(.bundle($0)) }.sorted()
        let text = "Stopped \(names.formatted(.list(type: .and))) (\(count) \(count == 1 ? "process" : "processes"))"
        log.notice("\(text, privacy: .public)")
        lastActivity = Activity(text: text, isError: false)
        refreshRunning()
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
            if !due.isEmpty { revoke([client], panes: due + [.links], reason: "its time limit ran out") }
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
