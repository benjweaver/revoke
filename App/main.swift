import AppKit

// `Revoke --restore-links` gives every app back the links and files Revoke asks about,
// for Homebrew's zap and anyone removing Revoke by hand. It asks first, because any
// process running as the person can run it. Without it, macOS hands each
// link to an app that registers it once Revoke is gone, but not always the one that had it.
if CommandLine.arguments.contains("--restore-links") {
    // Nothing below runs until the person confirms. The alert needs an app to show it.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Give every app its links back?"
    alert.informativeText = "Something ran Revoke with --restore-links. Revoke will quit and stop asking before links and files open the apps it stands in for. Say yes only if you ran this yourself, for example while removing Revoke."
    // No comes first, so it's the default and Return says no.
    alert.addButton(withTitle: "No")
    alert.addButton(withTitle: "Yes").keyEquivalent = ""
    alert.window.level = .floating
    guard alert.runModal() == .alertSecondButtonReturn else {
        FileHandle.standardError.write(Data("Revoke: left the links as they are.\n".utf8))
        exit(1)
    }

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

// `Revoke --request "revoke://request?access=internet&minutes=10&reason=…"` asks the
// person for access and waits for their answer: it prints yes, no, or ignored, and
// exits 0 only for yes. An agent should ask this way rather than with `open`, which
// exits before Revoke can see which app ran it. This command stays, so Revoke can.
if let flag = CommandLine.arguments.firstIndex(of: "--request") {
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Revoke: \(message)\n".utf8))
        exit(2)
    }
    guard CommandLine.arguments.count > flag + 1, let url = URL(string: CommandLine.arguments[flag + 1]),
          AccessRequest(url: url) != nil else {
        fail("that isn't a request. Try: Revoke --request \"revoke://request?access=local-network&minutes=15&reason=Why\"")
    }
    let me = Bundle.main.bundleIdentifier ?? ""
    if NSRunningApplication.runningApplications(withBundleIdentifier: me).allSatisfy({ $0 == .current }) {
        fail("Revoke isn't running, so there's nobody to ask.")
    }
    let center = DistributedNotificationCenter.default()
    let pid = getpid()
    _ = center.addObserver(forName: AccessRequestPrompt.answered, object: "\(pid)", queue: .main) { notification in
        let answer = notification.userInfo?["answer"] as? String ?? "ignored"
        print(answer)
        exit(answer == "yes" ? 0 : 1)
    }
    center.postNotificationName(AccessRequestPrompt.asked, object: nil,
                                userInfo: ["url": url.absoluteString, "pid": NSNumber(value: pid)],
                                deliverImmediately: true)
    // Long enough for someone to come back to the Mac and read the question.
    RunLoop.main.run(until: Date().addingTimeInterval(10 * 60))
    fail("nobody answered.")
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
