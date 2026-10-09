import AppKit
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
    ]

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
