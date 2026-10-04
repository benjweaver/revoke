import Darwin
import Foundation
import NetworkExtension
import Security

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
        }
        return identifiers
    }

    private static func pid(from token: Data) -> pid_t? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        // The sixth word of an audit token is the process ID.
        return token.withUnsafeBytes { pid_t(bitPattern: $0.load(as: audit_token_t.self).val.5) }
    }

    private static func signingIdentifier(token: Data) -> String? {
        pid(from: token).flatMap(kernelIdentifier) ?? signingIdentifier([kSecGuestAttributeAudit: token as CFData])
    }

    private static func signingIdentifier(pid: pid_t) -> String? {
        kernelIdentifier(pid: pid) ?? signingIdentifier([kSecGuestAttributePid: NSNumber(value: pid)])
    }

    /// The signing identifier the kernel recorded when the process started, read
    /// with `csops`. It never opens the program's file, which the extension's
    /// sandbox can't read when it's in someone's home folder, as Claude Code's is.
    private static func kernelIdentifier(pid: pid_t) -> String? {
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        // CS_OPS_IDENTITY from <sys/codesign.h>, which the SDK leaves out.
        let identity: UInt32 = 11
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        var blob = [UInt8](repeating: 0, count: 1024)
        guard unsafeBitCast(symbol, to: CSOps.self)(pid, identity, &blob, blob.count) == 0 else { return nil }
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
}
