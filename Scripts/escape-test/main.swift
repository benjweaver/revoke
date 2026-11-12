import Darwin
import Foundation

// The app Scripts/escape-test.sh blocks, and which then tries to get out. Every few
// seconds it tries the local network and the internet each way an agent might, and
// appends one line of results to a log the script reads:
//
//     <when the round started> lan_direct=ok lan_child=ok lan_orphan=ok net_allowed=ok net_other=ok ...
//
// Each result is "ok" when the connection got through and "no" when it didn't.
//
//     EscapeTest <local address> <allowed host> <other host> <log file>

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    FileHandle.standardError.write(Data("usage: EscapeTest <local address> <allowed host> <other host> <log file>\n".utf8))
    exit(2)
}
let (local, allowed, other, logPath) = (arguments[1], arguments[2], arguments[3], arguments[4])
let orphanPath = logPath + ".orphan"
/// A TCP port the local address answers on: the VM's gateway runs a DNS server.
let localPort = "53"

func ok(_ worked: Bool) -> String { worked ? "ok" : "no" }

/// Runs a tool and returns what it printed, and whether it exited cleanly.
func run(_ path: String, _ arguments: [String]) -> (output: String, succeeded: Bool) {
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

/// A connection from this process itself.
func lanDirect() -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(53).bigEndian
    inet_pton(AF_INET, local, &address.sin_addr)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    } == 0
}

/// A connection from a command this app runs, as an agent's `curl` or `ssh` would be.
func lanChild() -> Bool {
    run("/usr/bin/nc", ["-z", "-G", "2", local, localPort]).succeeded
}

/// A connection from a helper that has shed this app: started with responsibility
/// disclaimed, by a shell that puts it in the background and exits, so macOS hands it
/// to launchd. It writes its own result, since nothing is left to wait for it.
func startOrphan() {
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

func orphanResult() -> String {
    for _ in 0..<40 {
        if let text = try? String(contentsOfFile: orphanPath, encoding: .utf8) {
            return ok(text.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        }
        usleep(100_000)
    }
    return "none"
}

/// A request from `curl`, which looks the host up itself and connects to an address.
func curl(_ url: String, _ more: [String] = []) -> Bool {
    let status = run("/usr/bin/curl", ["-s", "-k", "-m", "5", "-o", "/dev/null", "-w", "%{http_code}"] + more + [url]).output
    return status.hasPrefix("2") || status.hasPrefix("3")
}

/// A request through URLSession, which hands macOS the host name.
func session(_ url: String) -> Bool {
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

func append(_ line: String) {
    let data = Data((line + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

while true {
    // The round's start comes first on the line, so the script can tell a round that
    // began after a switch was flipped from one already under way.
    let started = Int(Date().timeIntervalSince1970)
    startOrphan()
    let results = [
        "lan_direct=\(ok(lanDirect()))",
        "lan_child=\(ok(lanChild()))",
        "net_allowed=\(ok(curl("https://\(allowed)")))",
        "net_allowed_session=\(ok(session("https://\(allowed)")))",
        "net_other=\(ok(curl("https://\(other)")))",
        "net_other_session=\(ok(session("https://\(other)")))",
        // The allowed host's address, asked for the other host: what a liar would send.
        "net_fronted=\(ok(curl("https://\(other)", ["--connect-to", "\(other):443:\(allowed):443"])))",
        "lan_orphan=\(orphanResult())",
    ]
    append("\(started) " + results.joined(separator: " "))
    sleep(2)
}
