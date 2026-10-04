import Foundation

/// Revokes access with `tccutil`, Apple's command-line tool for the privacy
/// database. It removes the app from the list as if it had never asked, and the
/// app asks again the next time it needs access. It works without admin rights;
/// granting access is the one thing macOS keeps for System Settings.
enum Revoker {
    private static let tccutil = "/usr/bin/tccutil"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    /// Resets each service for one app. Returns nil on success, or why it failed.
    ///
    /// tccutil only takes bundle IDs that Launch Services can find, so on its own it
    /// can't touch what a deleted or replaced app left behind. For those, Revoke
    /// registers an empty stand-in bundle with the same ID for the moment the reset
    /// takes, then unregisters and deletes it. The stand-in never runs.
    static func reset(_ services: [String], for bundleID: String, installed: Bool) async -> String? {
        guard !installed else { return await reset(services, bundleID) }
        let folder: URL
        do {
            folder = try makeStandIn(for: bundleID)
        } catch {
            return error.localizedDescription
        }
        let app = folder.appendingPathComponent("Stand-in.app").path
        _ = await run(lsregister, ["-f", app])
        let result = await reset(services, bundleID)
        await remove(folder)
        return result
    }

    /// Clears stand-ins left by a run that ended partway, so Launch Services doesn't
    /// keep a fake app registered under a real bundle ID.
    static func removeLeftoverStandIns() async {
        guard let root = try? standInRoot(),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders { await remove(folder) }
    }

    private static func reset(_ services: [String], _ bundleID: String) async -> String? {
        for service in services {
            let (status, errors) = await run(tccutil, ["reset", service, bundleID])
            if status != 0 { return describe(errors) }
        }
        return nil
    }

    private static func standInRoot() throws -> URL {
        // Launch Services ignores bundles in the temporary folder, so this lives in Caches.
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("dev.benjweaver.Revoke/Stand-ins", isDirectory: true)
    }

    private static func makeStandIn(for bundleID: String) throws -> URL {
        let folder = try standInRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = folder.appendingPathComponent("Stand-in.app/Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "stand-in",
            "CFBundleName": "Revoke Stand-in",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // Launch Services skips a bundle without a real executable. A script will do.
        let executable = macOS.appendingPathComponent("stand-in")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return folder
    }

    private static func remove(_ folder: URL) async {
        _ = await run(lsregister, ["-u", folder.appendingPathComponent("Stand-in.app").path])
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs a tool and returns its exit status and whatever it wrote to stderr.
    private static func run(_ path: String, _ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let errors = Pipe()
            let reader = errors.fileHandleForReading
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { process in
                let output = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    private static func describe(_ output: String) -> String {
        // OSStatus -10814: Launch Services can't find an app with that bundle ID.
        if output.contains("-10814") { return "macOS can't find the app." }
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "tccutil failed." : message
    }
}
