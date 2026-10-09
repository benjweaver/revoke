import Foundation

/// A column in the panel: a privacy list from System Settings, or Links, which is
/// Revoke's own.
enum Pane: CaseIterable, Identifiable {
    case deviceControl
    case screenRecording
    case localNetwork
    /// Whether other apps can open the app with a link or a file, or Revoke asks first.
    case links

    var id: Self { self }

    /// macOS 27 renamed Accessibility to Device Control and Data Access.
    private static let isRenamed = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    var title: String {
        switch self {
        case .deviceControl: Self.isRenamed ? "Device Control and Data Access" : "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        case .localNetwork: "Local Network"
        case .links: "Links"
        }
    }

    var shortTitle: String {
        switch self {
        case .deviceControl: Self.isRenamed ? "Device Control" : "Accessibility"
        case .screenRecording: "Screen & Audio"
        case .localNetwork: "Local Network"
        case .links: "Links"
        }
    }

    /// What the access lets an app do, for the column's tooltip.
    var explanation: String {
        switch self {
        case .deviceControl:
            "\(title): lets the app click, type and read what's on screen in other apps, which is how AI agents use your Mac."
        case .screenRecording:
            "\(title): lets the app see your screen and hear what your Mac plays."
        case .localNetwork:
            "\(title): lets the app reach devices on your network, such as routers, printers and other computers."
        case .links:
            "\(title): lets web pages, emails, documents and other apps open the app with a link or a file, which can carry instructions for it. Off, Revoke asks you first."
        }
    }

    var symbol: String {
        switch self {
        case .deviceControl: "cursorarrow.rays"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .localNetwork: "network"
        case .links: "link"
        }
    }

    /// The service name in the TCC database. Local Network and Links aren't part of TCC.
    var tccService: String? {
        switch self {
        case .deviceControl: "kTCCServiceAccessibility"
        case .screenRecording: "kTCCServiceScreenCapture"
        case .localNetwork, .links: nil
        }
    }

    /// The names `tccutil reset` takes. System Settings lists System Audio Recording
    /// Only in the screen recording pane, so revoking screen recording revokes both.
    var tccutilServices: [String] {
        switch self {
        case .deviceControl: ["Accessibility"]
        case .screenRecording: ["ScreenCapture", "AudioCapture"]
        case .localNetwork, .links: []
        }
    }

    /// Opens the pane in System Settings. macOS 27 has no link to Local Network, so
    /// that one lands on Privacy & Security, a click away. Links has no pane.
    var settingsURL: URL? {
        let anchor = switch self {
        case .deviceControl: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .localNetwork: "Privacy_LocalNetwork"
        case .links: nil as String?
        }
        guard let anchor else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static let fullDiskAccessURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// An app or tool as macOS's privacy lists record it.
enum Client: Hashable {
    /// An app, by bundle ID. `tccutil` can revoke these.
    case bundle(String)
    /// A command-line tool without a bundle, by executable path. Only System
    /// Settings can change these.
    case path(String)

    /// How settings store the client: paths start with a slash, bundle IDs never do.
    init(key: String) {
        self = key.hasPrefix("/") ? .path(key) : .bundle(key)
    }

    var key: String {
        switch self {
        case .bundle(let id): id
        case .path(let path): path
        }
    }

    var bundleID: String? {
        if case .bundle(let id) = self { id } else { nil }
    }

    /// The developer part of a bundle ID: "com.openai" for "com.openai.codex".
    var vendor: String? {
        bundleID.map { $0.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }
    }
}

enum Access {
    case allowed
    /// Listed in System Settings but switched off.
    case denied
}

struct Entry: Equatable {
    var access: Access
    /// When the entry last changed, which for an allowed entry is when access was
    /// granted. Only TCC records this.
    var since: Date? = nil
    /// Code that ships with macOS, which macOS manages itself.
    var isAppleSystem = false
}

/// The links and file types that open one app.
struct AppLinks: Equatable {
    /// Other apps can open it with these directly.
    var open: [Link] = []
    /// Revoke stands in for these, and asks first.
    var guarded: [Link] = []

    var isEmpty: Bool { open.isEmpty && guarded.isEmpty }
    var all: [Link] { (open + guarded).sorted() }

    mutating func merge(_ other: AppLinks) {
        open = Array(Set(open + other.open)).sorted()
        guarded = Array(Set(guarded + other.guarded)).sorted()
    }
}

/// Everything Revoke could read about the privacy lists at one moment.
struct Snapshot: Equatable {
    var entries: [Client: [Pane: Entry]] = [:]
    var links: [Client: AppLinks] = [:]
    /// False until Revoke has Full Disk Access.
    var canReadTCC = false
    var canReadLocalNetwork = false
}
