import AppKit
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "dev.benjweaver.Revoke", category: "links")

/// macOS opened Revoke in an app's place, for a link or a file. Shows the person what's
/// being opened and by whom, and opens the app only if they say so. The link is shown
/// whole, since it's the part that can carry instructions for the agent.
@MainActor
final class LinkPrompt {
    private let settings: Settings
    /// Reports what happened, for the panel's activity line.
    var onActivity: ((String) -> Void)?
    /// Links wait their turn while a question is up, so each gets its own answer.
    private var waiting: [(url: URL, opener: String?)] = []
    private var isAsking = false

    init(settings: Settings) {
        self.settings = settings
    }

    /// `sender` is the process that asked macOS to open the links, from the Apple event.
    func receive(_ urls: [URL], sender: pid_t?) {
        let opener = sender.flatMap(Self.opener)
        waiting += urls.map { ($0, opener) }
        askNext()
    }

    private func askNext() {
        guard !isAsking, !waiting.isEmpty else { return }
        isAsking = true
        let (url, opener) = waiting.removeFirst()
        ask(url, opener: opener)
        isAsking = false
        DispatchQueue.main.async { [weak self] in self?.askNext() }
    }

    private func ask(_ url: URL, opener: String?) {
        let target = url.isFileURL ? url.path : url.absoluteString
        guard let link = link(for: url), let owner = settings.linkOwners[link] else {
            log.error("Nothing to open \(target, privacy: .public) with")
            let unknown = Links.shown(target)
            return warn("Revoke was asked to open something, but it doesn't know which app it was for:\n\n\(unknown.text)\(Self.omission(unknown))")
        }
        let name = AppInfo.linkOwnerName(owner.bundleID)
        guard let app = Links.location(of: owner) else {
            return warn("\(opener ?? "Something") wanted to open \(name), but it isn't installed any more.")
        }
        let who = opener ?? "Something"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSWorkspace.shared.icon(forFile: app.path)
        let shown: Links.Shown
        var warning: String
        if link.isFile {
            alert.messageText = "\(who) wants to open this file in \(name):"
            shown = Links.shown(target)
            warning = "Open it only if you just opened it yourself. A file can carry instructions for \(name)."
        } else {
            alert.messageText = "\(who) wants to open \(name) with this link:"
            shown = Links.shown(Links.readable(target))
            warning = "Open it only if you just clicked it yourself. A link can carry instructions for \(name), like a prompt for it to run."
        }
        if shown.isLong {
            warning += " This \(link.isFile ? "path" : "link") is long. Scroll through all of it before you decide."
        }
        warning += Self.omission(shown)
        alert.accessoryView = Self.accessory(shown: shown.text, warning: warning, question: "Open \(name)?")
        // No comes first, so it's the default and Return says no.
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes").keyEquivalent = ""
        alert.layout()
        alert.window.level = .floating
        NSApp.activate()
        Self.showFromTheTop(alert)
        let answer = alert.runModal()

        let what = link.isFile ? "a file" : "a link"
        guard answer == .alertSecondButtonReturn else {
            // Mid-sentence, "A command (curl)" and "Something" start lowercase.
            let kept = opener == nil || who.hasPrefix("A command") ? who.prefix(1).lowercased() + who.dropFirst() : who
            log.notice("Kept \(kept, privacy: .public) from opening \(name, privacy: .public) with \(target, privacy: .public)")
            onActivity?("Kept \(kept) from opening \(name) with \(what)")
            return
        }
        log.notice("Opening \(name, privacy: .public) with \(target, privacy: .public), as asked")
        // Straight to the app, so it doesn't come back through Revoke.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
            let message = error.map { "Couldn't open \(name): \($0.localizedDescription)" }
            DispatchQueue.main.async {
                if let message { self?.warn(message) }
                self?.onActivity?(message ?? "Opened \(name) with \(what) you allowed")
            }
        }
    }

    /// Which of the links Revoke stands in for this is.
    private func link(for url: URL) -> Link? {
        guard url.isFileURL else { return url.scheme.map { .scheme($0.lowercased()) } }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension) else { return nil }
        let exact = Link.type(type.identifier)
        if settings.linkOwners[exact] != nil { return exact }
        // A file whose type is a kind of one Revoke stands in for.
        return settings.linkOwners.keys.sorted().first {
            if case .type(let id) = $0, let other = UTType(id) { return type.conforms(to: other) }
            return false
        }
    }

    /// A sentence for the warning when the link was too long to show whole, which the
    /// person must know before they say yes to opening something they haven't read.
    private static func omission(_ shown: Links.Shown) -> String {
        shown.omitted == 0 ? "" : " The last \(shown.omitted) characters of it are too long to show here, so you can't read all of it: say No."
    }

    private func warn(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke"
        alert.informativeText = text
        alert.window.level = .floating
        NSApp.activate()
        alert.runModal()
    }

    /// Starts the box at the link's first line. As the alert comes up macOS gives the
    /// text keyboard focus and centers it, which hides the start of a long link, so this
    /// scrolls back on the first pass of the alert's own run loop.
    private static func showFromTheTop(_ alert: NSAlert) {
        let box = ScrollBox(alert.accessoryView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { box.scrollToTop() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Holds the scroll view for the timer, whose block can only take what's safe to
    /// hand between threads.
    @MainActor private final class ScrollBox {
        private weak var scroll: NSScrollView?
        init(_ scroll: NSScrollView?) { self.scroll = scroll }

        func scrollToTop() {
            guard let scroll, let text = scroll.documentView else { return }
            text.scroll(.zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The link in a box of its own that scrolls when it's long, then the warning.
    static func accessory(shown: String, warning: String, question: String) -> NSView {
        let width: CGFloat = 400
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        text.string = shown
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        // A text view can't grow past its first size unless told so. Left at that, a long
        // link sits in a document ten points tall and the box opens partway down it.
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let needed = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 40) + 10
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(max(needed, 28), 220)))
        scroll.documentView = text
        scroll.hasVerticalScroller = needed > 220
        // A scroller that stays in view, so it's plain there is more to read.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        text.frame.size.width = scroll.contentSize.width
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.sizeToFit()

        let warningLabel = NSTextField(wrappingLabelWithString: warning)
        let questionLabel = NSTextField(labelWithString: question)
        questionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for label in [warningLabel, questionLabel] { label.preferredMaxLayoutWidth = width }

        let stack = NSStackView(views: [scroll, warningLabel, questionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        warningLabel.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.frame.size = stack.fittingSize
        return stack
    }

    // MARK: - Who's opening it

    /// The app that asked macOS to open the link, by the name the person knows it by:
    /// Safari, Mail, Google Chrome. A command names the app it runs in, when there is one.
    static func opener(_ pid: pid_t) -> String? {
        guard pid > 0, pid != getpid() else { return nil }
        if let path = Processes.path(of: pid) {
            if let app = appName(containing: path) { return app }
            // macOS's own services pass links on for other apps, and say nothing useful.
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") { return nil }
            let command = (path as NSString).lastPathComponent
            var ancestor = Processes.parent(of: pid)
            for _ in 0..<10 {
                guard let current = ancestor, current > 1 else { break }
                if let ancestorPath = Processes.path(of: current), let app = appName(containing: ancestorPath) {
                    return "A command (\(command)) in \(app)"
                }
                ancestor = Processes.parent(of: current)
            }
            return "A command (\(command))"
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// The outermost app a path is in, so Chrome's helpers count as Google Chrome.
    private static func appName(containing path: String) -> String? {
        guard let end = path.range(of: ".app/") else { return nil }
        let app = String(path[..<end.lowerBound]) + ".app"
        var name = FileManager.default.displayName(atPath: app)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }
}
