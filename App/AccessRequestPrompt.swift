import AppKit
import os
import Security

private let log = Logger(subsystem: "dev.benjweaver.Revoke", category: "requests")

/// An app opened a revoke://request link to ask for access. Shows the person who's
/// asking, for what, and why, and changes nothing unless they say yes.
///
/// Revoke can lift its own Local Network block, for the time asked. The privacy lists
/// are macOS's, which only System Settings can add to, so for those a yes opens the
/// right pane. Who's asking comes from the process that opened the link and the apps it
/// runs inside, not from the link, so an app can't ask in another's name.
@MainActor
final class AccessRequestPrompt {
    private let settings: Settings
    private let model: AccessModel
    /// Requests wait their turn while a question is up, so each gets its own answer.
    private var waiting: [(request: AccessRequest, apps: [String], isClaimed: Bool, answer: (Answer) -> Void)] = []
    private var isAsking = false
    /// When the person last said no, by app and access. The same request is ignored
    /// for a while after, so an app can't keep asking until a click lands on Yes.
    private var declined: [String: Date] = [:]
    private static let quietAfterNo: TimeInterval = 60
    /// How far up the chain of parent processes to look for the app that asked.
    private static let maxAncestors = 16

    init(settings: Settings, model: AccessModel) {
        self.settings = settings
        self.model = model
    }

    /// What became of a request, for the command that's waiting to hear.
    enum Answer: String {
        case yes, no
        /// Not asked: unreadable, from nobody Revoke could name, nothing to allow, or
        /// asked again too soon after a no.
        case ignored
    }

    /// `sender` is the process that asked: the one that had macOS open the link, from
    /// the Apple event, or a `Revoke --request` command. `answer` hears what was decided.
    func receive(_ url: URL, sender: pid_t?, answer: @escaping (Answer) -> Void = { _ in }) {
        guard let request = AccessRequest(url: url) else {
            log.error("Ignored a request Revoke couldn't read: \(url.absoluteString, privacy: .public)")
            model.note("Ignored a request for access that Revoke couldn't read")
            return answer(.ignored)
        }
        // Looked up now: a command like `open` is gone moments after it sends the link.
        var apps = sender.map(Self.apps(behind:)) ?? []
        var isClaimed = false
        if apps.isEmpty, let claimed = request.claimedApp, AppInfo.isInstalled(.bundle(claimed)) {
            apps = [claimed]
            isClaimed = true
        }
        waiting.append((request, apps, isClaimed, answer))
        askNext()
    }

    private func askNext() {
        guard !isAsking, !waiting.isEmpty else { return }
        isAsking = true
        let (request, apps, isClaimed, answer) = waiting.removeFirst()
        answer(ask(request, apps: apps, isClaimed: isClaimed))
        isAsking = false
        DispatchQueue.main.async { [weak self] in self?.askNext() }
    }

    /// `isClaimed` is when the app is only the link's word for it, which the question says.
    private func ask(_ request: AccessRequest, apps: [String], isClaimed: Bool) -> Answer {
        let what = request.what
        // A command's own app is the one the person knows: Claude, not the shell inside it.
        guard let app = apps.first(where: { settings.isWatched(.bundle($0)) }) ?? apps.first else {
            log.notice("Ignored a request for \(what.title, privacy: .public) from an unknown process")
            model.note("Something asked for \(what.title), but Revoke couldn't tell which app it was")
            return .ignored
        }
        let name = AppInfo.name(.bundle(app))
        let key = "\(app) \(what)"
        if let last = declined[key], Date().timeIntervalSince(last) < Self.quietAfterNo {
            log.notice("Ignored \(name, privacy: .public) asking for \(what.title, privacy: .public) again so soon")
            return .ignored
        }

        // Every app in the chain that the filter holds back has to be let through,
        // since a block on any one of them stops the command.
        let held: [String]
        switch what {
        case .pane(.localNetwork):
            held = apps.filter(settings.localNetworkBlocked.contains)
            guard model.filter.isOn, !held.isEmpty else {
                model.note("\(name) asked for Local Network, which Revoke isn't blocking")
                return .ignored
            }
        case .internet:
            held = apps.filter(settings.internetLimited.contains)
            guard model.filter.isOn, !held.isEmpty else {
                model.note("\(name) asked for the whole internet, which Revoke isn't limiting")
                return .ignored
            }
        case .pane(let pane):
            held = []
            if model.snapshot.entries[.bundle(app)]?[pane]?.access == .allowed {
                model.note("\(name) asked for \(pane.title), which it already has")
                return .ignored
            }
        }
        let isTimed = !held.isEmpty

        let duration = Settings.describe(minutes: request.minutes)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        var warning: String
        let who = isClaimed ? "Something, saying it's \(name)," : name
        if isTimed {
            alert.messageText = "\(who) is asking for \(what.title) for \(duration):"
            let after = what == .internet ? "keeps it to its model's hosts again" : "blocks it again"
            warning = "Say yes only if you're expecting this. Revoke \(after) after \(duration). The reason is \(name)'s own words, not Revoke's."
        } else {
            alert.messageText = "\(who) is asking for \(what.title):"
            warning = "Say yes only if you're expecting this. Only you can switch it on, so Yes opens System Settings. The reason is \(name)'s own words, not Revoke's."
        }
        if isClaimed { warning += " Revoke couldn't tell which app sent this, so \(name) is only what the request says." }
        let reason = request.reason.map { Links.shown($0).text } ?? "It gave no reason."
        let question = what == .internet ? "Allow the whole internet?" : "Allow \(what.title)?"
        alert.accessoryView = LinkPrompt.accessory(shown: reason, warning: warning, question: question)
        // No comes first, so it's the default and Return says no.
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes").keyEquivalent = ""
        alert.layout()
        alert.window.level = .floating
        NSApp.activate()

        guard alert.runModal() == .alertSecondButtonReturn else {
            declined[key] = Date()
            log.notice("Turned down \(name, privacy: .public) asking for \(what.title, privacy: .public)")
            model.note("Turned down \(name) asking for \(what.title)")
            return .no
        }
        log.notice("Said yes to \(name, privacy: .public) asking for \(what.title, privacy: .public)")
        switch what {
        case .pane(.localNetwork):
            model.allowLocalNetwork(held, minutes: request.minutes, name: name)
        case .internet:
            model.allowInternet(held, minutes: request.minutes, name: name)
        case .pane(let pane):
            if let url = pane.settingsURL {
                NSWorkspace.shared.open(url)
                model.note("Opened System Settings for you to allow \(pane.title) for \(name)")
            }
        }
        return .yes
    }

    // MARK: - Requests from the command line

    /// `Revoke --request` posts this with the link and its own process ID, and waits
    /// for the answer under the second name.
    nonisolated static let asked = Notification.Name("dev.benjweaver.Revoke.request")
    nonisolated static let answered = Notification.Name("dev.benjweaver.Revoke.request.answered")

    /// Listens for requests from `Revoke --request`. A link opened with `open` often
    /// can't be traced: `open` has exited by the time Revoke looks for who ran it. The
    /// command stays until it's answered, so the apps it runs inside can be found.
    func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.asked, object: nil, queue: .main
        ) { [weak self] notification in
            let link = notification.userInfo?["url"] as? String
            let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value
            MainActor.assumeIsolated {
                guard let self, let link, let url = URL(string: link), let pid else { return }
                // Anything can post a notification and name any process in it. Only a
                // real Revoke command counts, and the apps come from its own parents.
                guard Self.isRevoke(pid) else {
                    log.error("Ignored a request posted by something other than Revoke (process \(pid, privacy: .public))")
                    return
                }
                self.receive(url, sender: pid) { answer in
                    DistributedNotificationCenter.default().postNotificationName(
                        Self.answered, object: "\(pid)", userInfo: ["answer": answer.rawValue], deliverImmediately: true)
                }
            }
        }
    }

    /// Whether a running process is Revoke's own program, by its code signature.
    private static func isRevoke(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(FilterIdentity.client as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: - Who's asking

    /// The apps a process runs inside, by bundle ID, nearest first: its own bundle, any
    /// app that bundle sits in, then the same for each parent. A command an agent runs
    /// gives the agent's engine and the app around it.
    static func apps(behind pid: pid_t) -> [String] {
        guard pid > 0, pid != getpid() else { return [] }
        let me = Bundle.main.bundleIdentifier
        var apps: [String] = []
        var current: pid_t? = pid
        for _ in 0...maxAncestors {
            guard let process = current, process > 1 else { break }
            if let path = Processes.path(of: process) {
                for id in bundleIDs(containing: path) where id != me && !apps.contains(id) { apps.append(id) }
            }
            current = Processes.parent(of: process)
        }
        return apps
    }

    /// The bundle IDs of every app a path is inside, innermost first.
    private static func bundleIDs(containing path: String) -> [String] {
        var ids: [String] = []
        var search = path.startIndex..<path.endIndex
        while let end = path.range(of: ".app/", range: search) {
            let app = String(path[..<end.lowerBound]) + ".app"
            if let id = Bundle(path: app)?.bundleIdentifier { ids.insert(id, at: 0) }
            search = end.upperBound..<path.endIndex
        }
        return ids
    }
}
