import Darwin
import Foundation
import NetworkExtension
import Security
import Synchronization

/// Works out which apps stand behind a connection, by code-signing identifier.
///
/// A connection counts as an app's when the app opened it or anything it started
/// did. An agent that runs `curl` or `ssh` to reach the local network is still the
/// agent reaching it, so a block on the app has to reach its commands too.
enum AppIdentity {
    /// How far up the chain of parent processes to look.
    private static let maxAncestors = 16

    static func identifiers(of flow: NEFilterFlow) -> Set<String> {
        var identifiers: Set<String> = []
        for token in [flow.sourceProcessAuditToken, flow.sourceAppAuditToken].compactMap({ $0 }) {
            guard let pid = pid(from: token) else { continue }
            if let identifier = signingIdentifier(token: token) { identifiers.insert(identifier) }
            // The process macOS holds responsible: the app that launched a command,
            // even after the command has detached from it.
            if let responsible = responsiblePID(of: pid), responsible != pid,
               let identifier = signingIdentifier(pid: responsible) {
                identifiers.insert(identifier)
            }
            // The plain parent chain too, in case the responsibility lookup isn't there.
            var ancestor = pid
            for _ in 0..<maxAncestors {
                guard let parent = parentPID(of: ancestor), parent > 1 else { break }
                if let identifier = signingIdentifier(pid: parent) { identifiers.insert(identifier) }
                ancestor = parent
            }
            // The app whose resource coalition the process is in. A helper can shed
            // both of the links above: disclaim responsibility when it's spawned, and
            // be re-parented to launchd once its parent exits. It can't leave the
            // coalition launchd put the app in, which every descendant inherits.
            // Checked after the PID lookup that the token's process is still the one
            // at that PID, so a reused PID can't lend it another app's coalition.
            if let coalition = Coalition.id(of: pid), isLive(token) {
                identifiers.formUnion(Coalition.apps(in: coalition))
            }
        }
        return identifiers
    }

    private static func pid(from token: Data) -> pid_t? {
        auditToken(token).map { pid_t(bitPattern: $0.val.5) }
    }

    private static func auditToken(_ token: Data) -> audit_token_t? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        return token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
    }

    /// The flow's own process is named by its audit token, which the kernel checks
    /// against the live process, so a PID reused since the connection opened can't
    /// stand in for it.
    private static func signingIdentifier(token: Data) -> String? {
        auditToken(token).flatMap(kernelIdentifier) ?? signingIdentifier([kSecGuestAttributeAudit: token as CFData])
    }

    private static func signingIdentifier(pid: pid_t) -> String? {
        kernelIdentifier(pid: pid) ?? signingIdentifier([kSecGuestAttributePid: NSNumber(value: pid)])
    }

    // CS_OPS_STATUS and CS_OPS_IDENTITY from <sys/codesign.h>, which the SDK leaves out.
    private static let statusOperation: UInt32 = 0
    private static let identityOperation: UInt32 = 11

    /// The signing identifier the kernel recorded when the process started, read
    /// with `csops`. It never opens the program's file, which the extension's
    /// sandbox can't read when it's in someone's home folder, as Claude Code's is.
    private static func kernelIdentifier(pid: pid_t) -> String? {
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        var blob = [UInt8](repeating: 0, count: 1024)
        guard unsafeBitCast(symbol, to: CSOps.self)(pid, identityOperation, &blob, blob.count) == 0 else { return nil }
        return identity(in: blob)
    }

    /// The same, read with `csops_audittoken`, which fails with ESRCH unless the
    /// process at the token's PID has the token's PID version (XNU's
    /// csops_internal in bsd/kern/kern_proc.c compares val[5] and val[7]). Without
    /// that call it falls back to the PID form.
    private static func kernelIdentifier(token: audit_token_t) -> String? {
        var token = token
        var blob = [UInt8](repeating: 0, count: 1024)
        guard let result = csopsAuditToken(identityOperation, &blob, blob.count, &token) else {
            return kernelIdentifier(pid: pid_t(bitPattern: token.val.5))
        }
        return result == 0 ? identity(in: blob) : nil
    }

    /// Whether the token's process is still running, rather than gone with its PID
    /// free for reuse. Without `csops_audittoken` there's no telling, so it counts
    /// as running, as the PID lookups above assume.
    private static func isLive(_ token: Data) -> Bool {
        guard var token = auditToken(token) else { return false }
        var status: UInt32 = 0
        guard let result = csopsAuditToken(statusOperation, &status, MemoryLayout<UInt32>.size, &token)
        else { return true }
        return result == 0
    }

    /// Calls `csops_audittoken`, or returns nil if libsystem_kernel doesn't export it.
    private static func csopsAuditToken(_ operation: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: Int,
                                        _ token: UnsafeMutablePointer<audit_token_t>) -> Int32? {
        typealias CSOpsAuditToken = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int,
                                                    UnsafeMutablePointer<audit_token_t>?) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops_audittoken") else { return nil }
        return unsafeBitCast(symbol, to: CSOpsAuditToken.self)(pid_t(bitPattern: token.pointee.val.5), operation,
                                                                buffer, size, token)
    }

    private static func identity(in blob: [UInt8]) -> String? {
        // An 8-byte header (magic and length) comes before the identifier.
        let name = blob.dropFirst(8).prefix { $0 != 0 }
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }

    private static func signingIdentifier(_ attributes: [CFString: Any]) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess
        else { return nil }
        return (information as? [CFString: Any])?[kSecCodeInfoIdentifier] as? String
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// `responsibility_get_pid_responsible_for_pid` is what macOS's own Local
    /// Network permission uses to charge a command to the app that launched it.
    /// It isn't in the SDK, so it's looked up at run time and skipped if it's gone.
    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Resource coalitions, which launchd gives each app it starts and every process
    /// the app starts inherits, re-parented or not. The kernel won't say which
    /// member leads one (only DEVELOPMENT kernels have the sysctls), so the apps are
    /// the members launchd itself spawned: the app, and the XPC services it asked
    /// for. A helper that was re-parented to launchd isn't among them, because the
    /// kernel keeps its original parent's PID version in read-only process data.
    ///
    /// Calls and layouts are from XNU's bsd/sys/proc_info_private.h, which the SDK
    /// leaves out: PROC_PIDCOALITIONINFO (20) and PROC_PIDUNIQIDENTIFIERINFO (17).
    /// The app sandbox allows process-info-pidinfo for any process
    /// (appsandbox-common.sb), and the kernel skips its same-user check for both.
    private enum Coalition {
        private static let coalitionInfo: Int32 = 20
        private static let coalitionInfoSize = 40
        private static let uniqueIdentifierInfo: Int32 = 17
        private static let uniqueIdentifierInfoSize = 56
        /// Coalition 1 is the kernel's, holding kernel_task and launchd.
        private static let kernelCoalition: UInt64 = 1
        /// How long a coalition's apps are trusted before they're read again, since
        /// an app can quit and relaunch into a coalition its helpers kept alive.
        private static let lifetime: Duration = .seconds(10)
        private static let capacity = 64

        private struct Entry {
            var apps: Set<String>
            var read: ContinuousClock.Instant
        }

        /// Coalition IDs come from a 64-bit counter that only goes up
        /// (osfmk/kern/coalition.c), so an ID is never reused for another app
        /// while the Mac is up, and an entry can only grow out of date, not wrong.
        private static let cache = Mutex<[UInt64: Entry]>([:])

        /// The process's resource coalition.
        static func id(of pid: pid_t) -> UInt64? {
            var info = [UInt8](repeating: 0, count: coalitionInfoSize)
            guard proc_pidinfo(pid, coalitionInfo, 0, &info, Int32(info.count)) == Int32(info.count) else { return nil }
            // coalition_id[COALITION_TYPE_RESOURCE], the first word.
            let id = info.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return id > kernelCoalition ? id : nil
        }

        /// The signing identifiers of the apps launchd started in a coalition.
        static func apps(in coalition: UInt64) -> Set<String> {
            let now = ContinuousClock.now
            if let entry = cache.withLock({ $0[coalition] }), now - entry.read < lifetime { return entry.apps }
            // Read without the lock, so other flows aren't held up behind the scan.
            let apps = scan(coalition)
            return cache.withLock { cache in
                // Kept from the last read too: an app that has quit still started
                // the helpers left behind in its coalition.
                let merged = apps.union(cache[coalition]?.apps ?? [])
                cache[coalition] = Entry(apps: merged, read: now)
                if cache.count > capacity {
                    cache = cache.filter { now - $0.value.read < lifetime }
                    while cache.count > capacity, let oldest = cache.min(by: { $0.value.read < $1.value.read }) {
                        cache[oldest.key] = nil
                    }
                }
                return merged
            }
        }

        private static func scan(_ coalition: UInt64) -> Set<String> {
            guard let launchd = versions(of: 1)?.pid else { return [] }
            var apps: Set<String> = []
            for pid in allPIDs() where pid > 1 && id(of: pid) == coalition {
                guard let versions = versions(of: pid), versions.originalParent == launchd else { continue }
                // Named by PID and PID version, so a process that exited since the
                // list was read can't be confused with a new one at its PID.
                var token = audit_token_t()
                token.val.5 = UInt32(bitPattern: pid)
                token.val.7 = UInt32(bitPattern: versions.pid)
                if let identifier = kernelIdentifier(token: token) { apps.insert(identifier) }
            }
            return apps
        }

        /// A process's PID version, and its original parent's, which doesn't change
        /// when the process is re-parented.
        private static func versions(of pid: pid_t) -> (pid: Int32, originalParent: Int32)? {
            var info = [UInt8](repeating: 0, count: uniqueIdentifierInfoSize)
            guard proc_pidinfo(pid, uniqueIdentifierInfo, 0, &info, Int32(info.count)) == Int32(info.count)
            else { return nil }
            // p_idversion and p_orig_ppidversion follow the 16-byte UUID and two
            // 64-bit unique IDs.
            return info.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 32, as: Int32.self), $0.loadUnaligned(fromByteOffset: 36, as: Int32.self))
            }
        }

        /// Every process ID, from the kern.proc.all sysctl, which the sandbox allows
        /// where proc_listallpids isn't.
        private static func allPIDs() -> [pid_t] {
            var name = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
            var size = 0
            guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0 else { return [] }
            // Room for processes started between the two calls.
            size += size / 8
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            guard sysctl(&name, UInt32(name.count), &processes, &size, nil, 0) == 0 else { return [] }
            return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
        }
    }
}
