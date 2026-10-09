import AppKit

// `Revoke --restore-links` gives every app back the links and files Revoke asks about,
// for Homebrew's zap and anyone removing Revoke by hand. Without it, macOS hands each
// link to an app that registers it once Revoke is gone, but not always the one that had it.
if CommandLine.arguments.contains("--restore-links") {
    // A running Revoke would take the links straight back.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0 != .current }
    others.forEach { $0.terminate() }
    for _ in 0..<50 where others.contains(where: { !$0.isTerminated }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

    let settings = Settings()
    for id in settings.linksBlocked { settings.setLinksBlocked(id, false) }
    Task {
        let (restored, failure) = await AccessModel.restore(settings.linkOwners, settings: settings)
        print("Gave back \(restored) \(restored == 1 ? "link" : "links").")
        if let failure { FileHandle.standardError.write(Data("Revoke: \(failure)\n".utf8)) }
        exit(failure == nil ? 0 : 1)
    }
    RunLoop.main.run()
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
