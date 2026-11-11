import Foundation
import os
import Synchronization

/// The list of blocked apps, and the XPC service the Revoke app changes it through.
///
/// The list is saved, so blocks hold from the moment the filter starts, before
/// the app has opened, and across restarts. It's saved as root, where the person's
/// account (and an agent running as them) can't change it, so it's the one that
/// counts: the app reads it from here rather than sending its own.
// Unchecked because NSXPCListener isn't Sendable. The listener is only touched in
// start(), and the list itself sits behind a Mutex.
final class ControlService: NSObject, NSXPCListenerDelegate, FilterControl, @unchecked Sendable {
    private static let key = "blocked"
    private static let allowedKey = "allowedUntil"
    /// The longest a block can be lifted for a while, in minutes.
    private static let maxMinutes = 240

    private struct Lists {
        var blocked: Set<String>
        /// Blocked apps let through for now, and when each block comes back. The filter
        /// keeps the time itself, so the block returns even if the app has quit.
        var allowedUntil: [String: Date]

        /// The apps blocked at this moment: the list, less those let through for now.
        func inForce(at now: Date) -> Set<String> {
            blocked.filter { (allowedUntil[$0] ?? .distantPast) <= now }
        }
    }

    private let lists = Mutex(Lists(
        blocked: Set(UserDefaults.standard.stringArray(forKey: ControlService.key) ?? []),
        allowedUntil: UserDefaults.standard.dictionary(forKey: ControlService.allowedKey) as? [String: Date] ?? [:]))
    private let listener = NSXPCListener(machServiceName: FilterIdentity.machService)
    private let log = Logger(subsystem: "dev.benjweaver.Revoke.Filter", category: "control")

    func start() {
        listener.delegate = self
        listener.resume()
    }

    var isEmpty: Bool { lists.withLock { $0.blocked.isEmpty } }

    func blocks(any identifiers: Set<String>) -> Bool {
        lists.withLock { !$0.inForce(at: Date()).isDisjoint(with: identifiers) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Messages from anything but Revoke are refused before they reach the list.
        connection.setCodeSigningRequirement(FilterIdentity.client)
        connection.exportedInterface = NSXPCInterface(with: FilterControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func getBlocked(reply: @escaping @Sendable ([String]) -> Void) {
        reply(change { _ in })
    }

    func block(_ identifiers: [String], reply: @escaping @Sendable ([String]) -> Void) {
        let list = change {
            $0.blocked.formUnion(identifiers)
            // Blocking again ends a block lifted for a while.
            for identifier in identifiers { $0.allowedUntil[identifier] = nil }
        }
        log.notice("Blocking the local network for \(identifiers.sorted(), privacy: .public)")
        reply(list)
    }

    func unblock(_ identifiers: [String], reply: @escaping @Sendable ([String]) -> Void) {
        let list = change {
            $0.blocked.subtract(identifiers)
            for identifier in identifiers { $0.allowedUntil[identifier] = nil }
        }
        log.notice("Stopped blocking the local network for \(identifiers.sorted(), privacy: .public)")
        reply(list)
    }

    func allow(_ identifiers: [String], minutes: Int, reply: @escaping @Sendable ([String]) -> Void) {
        let minutes = min(max(minutes, 1), Self.maxMinutes)
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let list = change { lists in
            for identifier in identifiers where lists.blocked.contains(identifier) { lists.allowedUntil[identifier] = until }
        }
        log.notice("Letting \(identifiers.sorted(), privacy: .public) reach the local network for \(minutes, privacy: .public) minutes")
        reply(list)
    }

    /// Changes the lists and saves them, under the lock so two changes can't cross.
    /// Returns the apps blocked at this moment.
    private func change(_ body: (inout Lists) -> Void) -> [String] {
        lists.withLock { lists in
            let before = (lists.blocked, lists.allowedUntil)
            body(&lists)
            let now = Date()
            // Times that have passed, or belong to apps no longer blocked, are done with.
            lists.allowedUntil = lists.allowedUntil.filter { $0.value > now && lists.blocked.contains($0.key) }
            if before != (lists.blocked, lists.allowedUntil) {
                UserDefaults.standard.set(lists.blocked.sorted(), forKey: Self.key)
                UserDefaults.standard.set(lists.allowedUntil, forKey: Self.allowedKey)
            }
            return lists.inForce(at: now).sorted()
        }
    }
}
