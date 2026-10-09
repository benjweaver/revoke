import AppKit
import Testing
import UniformTypeIdentifiers

/// These tests change LaunchServices for a made-up scheme of their own, with made-up
/// apps they register and remove again. They leave one thing behind: LaunchServices'
/// record of which app opens the made-up scheme, which macOS has no way to delete.
/// The scheme's name stays the same, so runs reuse that one record.
@MainActor
@Suite(.serialized)
struct LinksTests {
    private static let scheme = "dev-benjweaver-revoke-test"
    private static let originalID = "dev.benjweaver.revoke-test.original"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    @Test func takesASchemeAndGivesItBackExactly() async throws {
        let folder = try Self.makeFolder()
        let original = try Self.makeApp(in: folder, name: "Original", id: Self.originalID, schemes: [Self.scheme])
        Self.run(Self.lsregister, ["-f", original.path])
        defer {
            Self.run(Self.lsregister, ["-u", original.path])
            Self.remove(folder)
        }
        let link = Link.scheme(Self.scheme)

        // The app makes itself the handler, as Electron apps do when they start.
        try await Links.setHandler(original, for: link)
        #expect(Self.handlerID(link) == Self.originalID)
        let before = try #require(Self.savedChoice(for: Self.scheme))

        let revoke = try Self.builtRevoke()
        let owner = try #require(try await Links.take(link, for: revoke))
        #expect(owner == LinkOwner(bundleID: Self.originalID, path: original.path))
        #expect(Self.handlerID(link) == "dev.benjweaver.Revoke")
        // Taking it again changes nothing and saves nothing new.
        #expect(try await Links.take(link, for: revoke) == nil)

        try await Links.restore(link, to: owner)
        #expect(Self.handlerID(link) == Self.originalID)
        #expect(Links.handler(for: link)?.path == original.path)
        #expect(Self.savedChoice(for: Self.scheme) == before)
    }

    @Test func readsWhatAnAppRegisters() throws {
        let folder = try Self.makeFolder()
        defer { Self.remove(folder) }
        let app = try Self.makeApp(in: folder, name: "Agent", id: "dev.benjweaver.revoke-test.agent",
                                   schemes: ["Agent", "http", "https"],
                                   documents: [["LSItemContentTypes": ["com.example.skill", "public.data"]],
                                               ["CFBundleTypeExtensions": ["pdf", "*"]]])
        let links = Links.declared(byAppAt: app)
        // The web's schemes are the browser's, and all files are everyone's.
        #expect(links == [.scheme("agent"), .type("com.adobe.pdf"), .type("com.example.skill")].sorted())
    }

    @Test func showsALinkAsText() {
        #expect(Links.readable("claude://new?q=Delete%20my%20files+now") == "claude://new?q=Delete my files now")
        #expect(Links.readable("claude://x?q=100%") == "claude://x?q=100%")
        // Right-to-left overrides, zero-width characters and controls show as escapes.
        #expect(Links.shown("a\u{202E}b\u{200B}c\u{0007}d\u{FEFF}") == "a\\u202Eb\\u200Bc\\u0007d\\uFEFF")
        #expect(Links.shown("line\nnext\ttab") == "line\nnext\ttab")
        let long = String(repeating: "x", count: 1510)
        #expect(Links.shown(long) == String(repeating: "x", count: 1500) + "… (10 more characters)")
    }

    // MARK: - Helpers

    private static func handlerID(_ link: Link) -> String? {
        Links.handler(for: link).flatMap(Links.bundleID(ofAppAt:))
    }

    /// LaunchServices' own record of the choice, less when it was made. Read through
    /// cfprefsd, since the file on disk lags behind.
    private static func savedChoice(for scheme: String) -> NSDictionary? {
        let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
        let handlers = CFPreferencesCopyAppValue("LSHandlers" as CFString, domain) as? [[String: Any]] ?? []
        guard var entry = handlers.first(where: { ($0["LSHandlerURLScheme"] as? String)?.lowercased() == scheme })
        else { return nil }
        entry["LSHandlerModificationDate"] = nil
        return entry as NSDictionary
    }

    /// The Revoke.app built beside the tests.
    private static func builtRevoke() throws -> URL {
        let app = Bundle(for: Token.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Revoke.app")
        try #require(FileManager.default.fileExists(atPath: app.path), "Build Revoke first: \(app.path)")
        return app
    }

    private final class Token {}

    /// Launch Services ignores apps in the temporary folder, so these go in Caches.
    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.benjweaver.Revoke.tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The folder, and the one it's in once that's empty.
    private static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        rmdir(folder.deletingLastPathComponent().path)
    }

    private static func makeApp(in folder: URL, name: String, id: String, schemes: [String],
                                documents: [[String: Any]] = []) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "app",
            "CFBundleName": name,
            "CFBundleURLTypes": [["CFBundleURLName": name, "CFBundleURLSchemes": schemes]],
        ]
        if !documents.isEmpty {
            info["CFBundleDocumentTypes"] = documents.map { $0.merging(["CFBundleTypeRole": "Viewer"]) { $1 } }
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        // Launch Services skips a bundle without a real executable. A script will do.
        let executable = macOS.appendingPathComponent("app")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
