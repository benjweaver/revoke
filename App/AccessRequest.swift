import Foundation

/// What an agent asks Revoke for with a link: one kind of access, for a while, and why.
///
///     revoke://request?access=local-network&minutes=15&reason=Reach%20the%20test%20VM
///
/// An agent that finds something blocked can open one of these instead of working around
/// the block. Revoke shows the person who's asking and for what, and nothing changes
/// unless they say yes. The link only asks: who sent it is worked out from the process
/// that opened it, never from what the link says, and the reason is shown as text.
struct AccessRequest: Equatable {
    static let scheme = "revoke"
    /// How long access lasts when the link doesn't say.
    static let defaultMinutes = 15
    /// The longest a link can ask for, the same as the longest time limit in settings.
    static let maxMinutes = 240
    /// Reasons are a line or two. Anything longer is cut, and nothing reads the rest.
    static let reasonLimit = 300

    /// The names a link uses for each kind of access Revoke can be asked for. Links and
    /// Running aren't here: an agent has no business switching those on for itself.
    static let names: [String: Pane] = [
        "local-network": .localNetwork,
        "device-control": .deviceControl,
        "accessibility": .deviceControl,
        "screen-recording": .screenRecording,
        "input-monitoring": .inputMonitoring,
        "full-disk-access": .fullDiskAccess,
    ]

    let pane: Pane
    /// How long the access is wanted for, between 1 and `maxMinutes`.
    let minutes: Int
    let reason: String?
    /// The app the link says it's for, by bundle ID. Only a fallback for when Revoke
    /// can't tell which process opened the link, since any link can claim any app.
    let claimedApp: String?

    /// Whether a link is addressed to Revoke itself, rather than one it stands in for.
    static func isRequest(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Nil for anything that isn't a well-formed request, which Revoke then ignores.
    init?(url: URL) {
        guard Self.isRequest(url), url.host?.lowercased() == "request",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        // The first of each name counts, so a second one can't override what was shown.
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let access = value("access")?.lowercased(), let pane = Self.names[access] else { return nil }
        self.pane = pane
        minutes = value("minutes").flatMap(Int.init).map { min(max($0, 1), Self.maxMinutes) } ?? Self.defaultMinutes
        let reason = value("reason") ?? ""
        self.reason = reason.isEmpty ? nil : String(String.UnicodeScalarView(reason.unicodeScalars.prefix(Self.reasonLimit)))
        claimedApp = value("app").flatMap { Self.isBundleID($0) ? $0 : nil }
    }

    /// Letters, digits, dots, hyphens, and underscores, as bundle IDs are.
    private static func isBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 255 && text.contains(".") && text.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || ".-_".unicodeScalars.contains($0))
        }
    }
}
