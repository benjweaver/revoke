import Foundation
import os
import Synchronization

/// The list of blocked apps, and the XPC service the Revoke app changes it through.
///
/// The list is saved, so blocks hold from the moment the filter starts, before
/// the app has opened, and across restarts.
// Unchecked because NSXPCListener isn't Sendable. The listener is only touched in
// start(), and the list itself sits behind a Mutex.
final class ControlService: NSObject, NSXPCListenerDelegate, FilterControl, @unchecked Sendable {
    private static let key = "blocked"
    private let blocked = Mutex(Set(UserDefaults.standard.stringArray(forKey: ControlService.key) ?? []))
    private let listener = NSXPCListener(machServiceName: FilterIdentity.machService)
    private let log = Logger(subsystem: "dev.benjweaver.Revoke.Filter", category: "control")

    func start() {
        listener.delegate = self
        listener.resume()
    }

    var isEmpty: Bool { blocked.withLock { $0.isEmpty } }

    func blocks(any identifiers: Set<String>) -> Bool {
        blocked.withLock { !$0.isDisjoint(with: identifiers) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Messages from anything but Revoke are refused before they reach setBlocked.
        connection.setCodeSigningRequirement(FilterIdentity.client)
        connection.exportedInterface = NSXPCInterface(with: FilterControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setBlocked(_ identifiers: [String], reply: @escaping @Sendable () -> Void) {
        blocked.withLock { $0 = Set(identifiers) }
        UserDefaults.standard.set(identifiers.sorted(), forKey: Self.key)
        log.notice("Blocking the local network for \(identifiers.sorted(), privacy: .public)")
        reply()
    }
}
