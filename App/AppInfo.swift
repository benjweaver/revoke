import AppKit
import Security
import UniformTypeIdentifiers

/// Names and icons for clients, as Finder shows them, and whether they're still installed.
@MainActor
enum AppInfo {
    private struct Info {
        let name: String
        let icon: NSImage
        let isInstalled: Bool
    }

    private static var cache: [Client: Info] = [:]

    /// Clearer names for apps whose own names are confusing in a list.
    private static let names = [
        // The engine inside the Claude app that runs Claude Code. System Settings
        // lists it as "claude", right under "Claude".
        "com.anthropic.claude-code": "Claude Code",
    ]

    /// A line under the name for apps whose name alone doesn't say what they are.
    private static let roles = [
        "com.anthropic.claude-code": "Runs Claude's Code tab",
        // OpenAI renamed the Codex app ChatGPT, keeping Codex's bundle ID.
        "com.openai.codex": "Includes Codex",
        // A background app of its own, which macOS also calls ChatGPT Computer Use.
        "com.openai.sky.CUAService": "ChatGPT's computer use agent",
    ]

    /// Apps that register links for a watched app, by the bundle ID of the app whose row
    /// they belong in. Claude Code writes itself a URL Handler app in ~/Applications for
    /// claude-cli:// links, and Revoke shows those under Claude Code.
    private static let linkHandlers = [
        "com.anthropic.claude-code-url-handler": "com.anthropic.claude-code",
    ]

    /// Watched apps known to register links, looked for even when they aren't in any
    /// privacy list or running.
    static let knownLinkApps = ["com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat"]
        + linkHandlers.keys

    /// The row an app's links show in: its own, or the app it handles links for.
    static func linkClient(_ bundleID: String) -> String {
        guard let owner = linkHandlers[bundleID], isInstalled(.bundle(owner)) else { return bundleID }
        return owner
    }

    /// The name to ask about opening, as the panel shows it: Claude Code for its URL Handler.
    static func linkOwnerName(_ bundleID: String) -> String { name(.bundle(linkClient(bundleID))) }

    private static var declared: [String: (Date?, [Link])] = [:]

    /// The links an app's Info.plist registers, read again only when it changes.
    static func declaredLinks(_ app: URL) -> [Link] {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let modified = (try? plist.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let (date, links) = declared[app.path], date == modified { return links }
        let links = Links.declared(byAppAt: app)
        declared[app.path] = (modified, links)
        return links
    }

    private static var askable: [String: (Date?, [OtherAccess])] = [:]

    /// The access Revoke can't see that the app can ask for, from its Info.plist and
    /// entitlements, read again only when the app changes.
    static func otherAccess(_ client: Client) -> [OtherAccess] {
        guard let id = client.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return OtherAccess.allCases
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let modified = (try? plist.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let (date, access) = askable[app.path], date == modified { return access }
        let info = NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
        let access = OtherAccess.askable(info: info, entitlements: entitlements(of: app))
        askable[app.path] = (modified, access)
        return access
    }

    private static func entitlements(of app: URL) -> [String: Any] {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return [:] }
        return (information as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    static func name(_ client: Client) -> String { info(client).name }
    static func role(_ client: Client) -> String? { client.bundleID.flatMap { roles[$0] } }
    static func icon(_ client: Client) -> NSImage { info(client).icon }
    static func isInstalled(_ client: Client) -> Bool { info(client).isInstalled }

    /// Apps come and go while Revoke runs, so the panel looks again each time it opens.
    static func forget() { cache.removeAll() }

    private static func info(_ client: Client) -> Info {
        if let cached = cache[client] { return cached }
        let workspace = NSWorkspace.shared
        let result: Info
        switch client {
        case .bundle(let id):
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                // Finder's name, minus ".app" when Finder shows extensions.
                var name = FileManager.default.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                result = Info(name: names[id] ?? name, icon: workspace.icon(forFile: url.path), isInstalled: true)
            } else {
                result = Info(name: names[id] ?? id, icon: workspace.icon(for: .applicationBundle), isInstalled: false)
            }
        case .path(let path):
            result = Info(name: (path as NSString).lastPathComponent, icon: workspace.icon(forFile: path),
                          isInstalled: FileManager.default.fileExists(atPath: path))
        }
        cache[client] = result
        return result
    }
}
