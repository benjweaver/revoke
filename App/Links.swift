import AppKit
import UniformTypeIdentifiers

/// A way other apps open an app: a link scheme (claude://, codex://) or a file type
/// (.skill), as LaunchServices routes them.
enum Link: Hashable, Codable, Comparable {
    /// A URL scheme, lowercased.
    case scheme(String)
    /// A file type, by its uniform type identifier.
    case type(String)

    var isFile: Bool { if case .type = self { true } else { false } }

    /// "claude://" or ".skill".
    var description: String {
        switch self {
        case .scheme(let scheme): return "\(scheme)://"
        case .type(let id):
            guard let type = UTType(id) else { return id }
            return type.preferredFilenameExtension.map { ".\($0)" } ?? type.localizedDescription ?? id
        }
    }
}

/// The app that handled a link before Revoke stood in for it, to put back.
struct LinkOwner: Codable, Equatable {
    let bundleID: String
    let path: String
}

/// Links and files that open an app. A web page, an email or a document can open an
/// agent with a link that carries a prompt, while nobody's looking, and macOS starts
/// the app to take it. Revoke can make itself the handler instead, so macOS opens
/// Revoke, which shows the link and opens the app only if the person says so.
///
/// LaunchServices keeps the choices per user, so this needs no admin rights and works
/// while Revoke isn't running: macOS starts Revoke for the link. A link scheme changes
/// hands silently. A file type doesn't: macOS asks the person to confirm every change
/// to which app opens it, Revoke's or anyone's.
@MainActor
enum Links {
    /// Schemes Revoke never takes: the web's, which belong to the browser even though
    /// ChatGPT lists them, and files'.
    private static let neverTaken: Set<String> = ["http", "https", "file"]
    /// Types so broad that taking them would put Revoke in front of everything.
    private static let tooBroad: Set<String> = [
        UTType.item, .data, .content, .folder, .directory, .text, .plainText, .package,
    ].map(\.identifier).reduce(into: []) { $0.insert($1) }

    /// Every scheme and file type the app's Info.plist registers, which other apps
    /// could open it with if it's their handler.
    static func declared(byAppAt app: URL) -> [Link] {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        else { return [] }
        var links: [Link] = []
        for type in info["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
            for scheme in type["CFBundleURLSchemes"] as? [String] ?? [] {
                let scheme = scheme.lowercased()
                if !neverTaken.contains(scheme) { links.append(.scheme(scheme)) }
            }
        }
        for type in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            var ids = type["LSItemContentTypes"] as? [String] ?? []
            for ext in type["CFBundleTypeExtensions"] as? [String] ?? [] where ext != "*" {
                if let id = UTType(filenameExtension: ext)?.identifier { ids.append(id) }
            }
            links += ids.filter { !tooBroad.contains($0) }.map(Link.type)
        }
        return Array(Set(links)).sorted()
    }

    /// The app macOS opens the link or file type with now.
    static func handler(for link: Link) -> URL? {
        switch link {
        case .scheme(let scheme):
            guard let url = URL(string: "\(scheme):") else { return nil }
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        case .type(let id):
            guard let type = UTType(id) else { return nil }
            return NSWorkspace.shared.urlForApplication(toOpen: type)
        }
    }

    static func bundleID(ofAppAt app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// Makes `app` the handler. A file type waits for the person to confirm in
    /// macOS's own dialog, and throws if they keep the app it had.
    static func setHandler(_ app: URL, for link: Link) async throws {
        switch link {
        case .scheme(let scheme):
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        case .type(let id):
            guard let type = UTType(id) else { throw LinkError("macOS doesn't know the file type \(id).") }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            } catch let error as NSError where Self.isCancelled(error) {
                // macOS asked, and the person kept the app it had.
                let kept = handler(for: link).map { FileManager.default.displayName(atPath: $0.path) } ?? "the app it had"
                throw LinkError("You kept \(kept.replacingOccurrences(of: ".app", with: "")) for \(link.description) files.")
            }
        }
        // A file type can be left as it was when the person keeps the old app.
        guard let now = handler(for: link), bundleID(ofAppAt: now) == bundleID(ofAppAt: app) else {
            throw LinkError("macOS kept another app for \(link.description).")
        }
    }

    /// macOS's answer when the person turns down its confirmation: userCanceledErr,
    /// sometimes wrapped in a Cocoa error.
    private static func isCancelled(_ error: NSError) -> Bool {
        if error.domain == NSOSStatusErrorDomain && error.code == userCanceledErr { return true }
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isCancelled) ?? false
    }

    /// Makes `standIn` the handler, and returns the app it took the link from, to put
    /// back later. Nil when `standIn` already had it.
    static func take(_ link: Link, for standIn: URL) async throws -> LinkOwner? {
        guard let current = handler(for: link), let id = bundleID(ofAppAt: current) else {
            throw LinkError("No app opens \(link.description).")
        }
        if id == bundleID(ofAppAt: standIn) { return nil }
        let owner = LinkOwner(bundleID: id, path: current.path)
        try await setHandler(standIn, for: link)
        return owner
    }

    /// Gives the link back to the app it was taken from.
    static func restore(_ link: Link, to owner: LinkOwner) async throws {
        guard let app = location(of: owner) else {
            throw LinkError("\(owner.bundleID) isn't installed any more.")
        }
        try await setHandler(app, for: link)
    }

    /// Where the app is now: where it was, if it's still there, or wherever macOS
    /// finds an app with its bundle ID.
    static func location(of owner: LinkOwner) -> URL? {
        let saved = URL(fileURLWithPath: owner.path)
        if bundleID(ofAppAt: saved) == owner.bundleID { return saved }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner.bundleID)
    }

    // MARK: - Showing a link

    /// The link with %-escapes decoded, so a prompt in it reads as text.
    nonisolated static func readable(_ link: String) -> String {
        let spaced = link.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Text safe to show: characters that reorder or hide text (right-to-left
    /// overrides, zero-width spaces, controls) are shown as \uXXXX escapes, so a link
    /// can't make itself look like something else, and very long text is cut.
    nonisolated static func shown(_ text: String, limit: Int = 1500) -> String {
        var shown = ""
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if index == limit {
                shown += "… (\(scalars.count - limit) more characters)"
                break
            }
            if isHidden(scalar) {
                shown += String(format: "\\u%04X", scalar.value)
            } else {
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }

    nonisolated private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return scalar.properties.generalCategory == .control
        }
    }
}

struct LinkError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
