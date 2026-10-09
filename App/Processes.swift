import AppKit
import Darwin

/// Stopping an app the way an agent can't wriggle out of: the app, its helpers, and
/// everything they started, such as the shells and tools an agent runs.
enum Processes {
    private struct Process {
        let pid: pid_t
        let parent: pid_t
        let path: String
    }

    /// The processes that belong to each app, by bundle ID: those running from inside
    /// any installed copy of it, and everything they started, at any depth. Apps with
    /// nothing running are left out.
    static func pids(of bundleIDs: some Sequence<String>) -> [String: Set<pid_t>] {
        let all = list()
        let me = getpid()
        var result: [String: Set<pid_t>] = [:]
        for id in bundleIDs {
            let roots = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map { $0.path + "/" }
            var found = Set(all.filter { process in roots.contains { process.path.hasPrefix($0) } }.map(\.pid))
            // macOS knows which processes it started as the app, even one that has
            // since replaced itself with another program.
            found.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
            // Children whose parents are found, until nothing new turns up.
            var grew = !found.isEmpty
            while grew {
                grew = false
                for process in all where !found.contains(process.pid) && found.contains(process.parent) {
                    found.insert(process.pid)
                    grew = true
                }
            }
            found.remove(me)
            if !found.isEmpty { result[id] = found }
        }
        return result
    }

    /// Asks every process to stop, then forces whatever is still running after a few
    /// seconds. Returns how many were running.
    static func stop(_ pids: Set<pid_t>) async -> Int {
        let running = pids.filter { kill($0, 0) == 0 }
        for pid in running { kill(pid, SIGTERM) }
        for _ in 0..<30 {
            if !running.contains(where: isAlive) { return running.count }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in running where isAlive(pid) { kill(pid, SIGKILL) }
        return running.count
    }

    /// Alive and not a zombie waiting for its parent.
    private static func isAlive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != SZOMB
    }

    private static func list() -> [Process] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(bytes)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { return nil }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            return Process(pid: pid, parent: pid_t(info.pbi_ppid), path: path)
        }
    }

    /// The process's executable, for naming what opened a link.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
