import AppKit
import Darwin

// The app Scripts/escape-test.sh blocks, and which then tries to get out. Every few
// seconds it tries the local network and the internet each way an agent might, and
// appends one line of results to a log the script reads:
//
//     <when the round started> lan_direct=ok lan_child=ok lan_orphan=ok net_allowed=ok net_other=ok ...
//
// Each result is "ok" when the connection got through and "no" when it didn't.
//
// It also takes links: each one macOS hands it goes on a line of <log file>.links, so
// the script can tell whether a link Revoke asked about reached it.
//
//     EscapeTest <local address> <allowed host> <other host> <log file> [<on-link address> ...]
//
// The on-link addresses are ones outside the private ranges that an interface's own
// subnet makes local. Each is tried on port 22 and reported as lan_extra1, lan_extra2, ...

/// The tries, which run on their own thread while the main one waits for links.
enum Probe {
    static let arguments = CommandLine.arguments
    static let local = arguments[1]
    static let allowed = arguments[2]
    static let other = arguments[3]
    static let logPath = arguments[4]
    static let extras = Array(arguments.dropFirst(5))
    static let orphanPath = logPath + ".orphan"
    static let linksPath = logPath + ".links"
    static let curlPath = logPath + ".curl"
    /// A TCP port the local address answers on: the VM's gateway runs a DNS server.
    static let localPort = "53"
    /// And one the on-link addresses answer on: they're the VM's own, and it runs sshd.
    static let extraPort = "22"

    static func ok(_ worked: Bool) -> String { worked ? "ok" : "no" }

    /// Runs a tool and returns what it printed, and whether it exited cleanly.
    static func run(_ path: String, _ arguments: [String]) -> (output: String, succeeded: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ("", false) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus == 0)
    }

    /// A connection from this process itself, to an IPv4 or IPv6 address.
    static func lanDirect(_ address: String, _ port: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, port, &hints, &found) == 0, let info = found?.pointee else { return false }
        defer { freeaddrinfo(found) }
        let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Two seconds at most: an address nothing answers at would otherwise hold the
        // round up for as long as TCP keeps trying.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        if connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, 2000) == 1 else { return false }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0
    }

    /// A connection from a command this app runs, as an agent's `curl` or `ssh` would be.
    static func lanChild() -> Bool {
        run("/usr/bin/nc", ["-z", "-G", "2", local, localPort]).succeeded
    }

    /// A connection from a helper that has shed this app: started with responsibility
    /// disclaimed, by a shell that puts it in the background and exits, so macOS hands it
    /// to launchd. It writes its own result, since nothing is left to wait for it.
    static func startOrphan() {
        try? FileManager.default.removeItem(atPath: orphanPath)
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }
        let script = "(/usr/bin/nc -z -G 2 '\(local)' \(localPort) >/dev/null 2>&1; echo $? > '\(orphanPath)') &"
        var argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        var pid: pid_t = 0
        if posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ) == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        posix_spawnattr_destroy(&attributes)
        for pointer in argv { free(pointer) }
    }

    static func orphanResult() -> String {
        for _ in 0..<40 {
            if let text = try? String(contentsOfFile: orphanPath, encoding: .utf8) {
                return ok(text.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
            usleep(100_000)
        }
        return "none"
    }

    /// A request from `curl`, which looks the host up itself and connects to an address.
    /// What curl made of each one goes in <log file>.curl, for working out a failure:
    /// the HTTP status, curl's exit code, and how long the lookup, the connection, and
    /// the whole request took.
    static func curl(_ url: String, _ more: [String] = []) -> Bool {
        let report = "%{http_code} exit=%{exitcode} lookup=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total} ip=%{remote_ip}"
        let output = run("/usr/bin/curl", ["-s", "-k", "-m", "5", "-o", "/dev/null", "-w", report] + more + [url]).output
        append("\(Int(Date().timeIntervalSince1970)) \(url) \(more.joined(separator: " ")) -> \(output)", to: curlPath)
        return output.hasPrefix("2") || output.hasPrefix("3")
    }

    /// A request through URLSession, which hands macOS the host name.
    static func session(_ url: String) -> Bool {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var worked = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        URLSession(configuration: configuration).dataTask(with: URL(string: url)!) { _, response, _ in
            worked = response is HTTPURLResponse
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 7)
        return worked
    }

    static func append(_ line: String, to path: String) {
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    static func round() {
        // The round's start comes first on the line, so the script can tell a round that
        // began after a switch was flipped from one already under way.
        let started = Int(Date().timeIntervalSince1970)
        startOrphan()
        let results = [
            "lan_direct=\(ok(lanDirect(local, localPort)))",
            "lan_child=\(ok(lanChild()))",
            "net_allowed=\(ok(curl("https://\(allowed)")))",
            "net_allowed_session=\(ok(session("https://\(allowed)")))",
            "net_other=\(ok(curl("https://\(other)")))",
            "net_other_session=\(ok(session("https://\(other)")))",
            // The allowed host's address, asked for the other host: what a liar would send.
            "net_fronted=\(ok(curl("https://\(other)", ["--connect-to", "\(other):443:\(allowed):443"])))",
        ] + extras.enumerated().map { "lan_extra\($0.offset + 1)=\(ok(lanDirect($0.element, extraPort)))" } + [
            "lan_orphan=\(orphanResult())",
        ]
        append("\(started) " + results.joined(separator: " "), to: logPath)
    }
}

/// Writes down each link macOS opens the app with.
final class LinkCatcher: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Probe.append(url.absoluteString, to: Probe.linksPath) }
    }
}

guard CommandLine.arguments.count >= 5 else {
    FileHandle.standardError.write(Data("usage: EscapeTest <local address> <allowed host> <other host> <log file> [<on-link address> ...]\n".utf8))
    exit(2)
}
Thread.detachNewThread {
    while true {
        Probe.round()
        sleep(2)
    }
}
let catcher = LinkCatcher()
NSApplication.shared.delegate = catcher
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
