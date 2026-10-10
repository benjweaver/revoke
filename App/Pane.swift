import Foundation

/// A column in the panel: whether the app is running, a privacy list from System
/// Settings, Links, which is Revoke's own, or the access Revoke can reset but not see.
enum Pane: CaseIterable, Identifiable {
    /// The app, its helpers, or something they started is running.
    case running
    case deviceControl
    case screenRecording
    case inputMonitoring
    case fullDiskAccess
    case localNetwork
    /// Whether other apps can open the app with a link or a file, or Revoke asks first.
    case links
    /// Automation, the camera and microphone, files and folders, and the rest, which
    /// macOS 27 doesn't let any app see: a menu to reset them rather than a switch.
    case other

    var id: Self { self }

    /// The columns that are access, which Revoke All Watched and the automatic options
    /// take away. Running isn't: stopping apps is Stop App's job.
    static let access = allCases.filter { $0 != .running }

    /// Access that lets an app control the Mac or see what's on it. These open the menu
    /// bar lock, and list apps you don't watch under other apps with access.
    static let control: [Pane] = [.deviceControl, .screenRecording, .inputMonitoring]

    /// macOS 27 renamed Accessibility to Device Control and Data Access.
    private static let isRenamed = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    var title: String {
        switch self {
        case .running: "Running"
        case .deviceControl: Self.isRenamed ? "Device Control and Data Access" : "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        case .inputMonitoring: "Input Monitoring"
        case .fullDiskAccess: "Full Disk Access"
        case .localNetwork: "Local Network"
        case .links: "Links"
        case .other: "Other access"
        }
    }

    var shortTitle: String {
        switch self {
        case .running: "Running"
        case .deviceControl: Self.isRenamed ? "Device Control" : "Accessibility"
        case .screenRecording: "Screen & Audio"
        case .inputMonitoring: "Input"
        case .fullDiskAccess: "Full Disk"
        case .localNetwork: "Local Network"
        case .links: "Links"
        case .other: "Other"
        }
    }

    /// What the access lets an app do, for the column's tooltip.
    var explanation: String {
        switch self {
        case .running:
            "\(title): the app, its helpers, or something they started, such as an agent's shells and tools, is running. Off stops all of it."
        case .deviceControl:
            "\(title): lets the app click, type, and read what's on screen in other apps, which is how AI agents use your Mac."
        case .screenRecording:
            "\(title): lets the app see your screen and hear what your Mac plays."
        case .inputMonitoring:
            "\(title): lets the app see every key you press and every click, in any app."
        case .fullDiskAccess:
            "\(title): lets the app read and change all your files, including Mail, Messages, Safari, and other apps' data."
        case .localNetwork:
            "\(title): lets the app reach devices on your network, such as routers, printers, and other computers, and lets them reach it."
        case .links:
            "\(title): lets web pages, emails, documents, and other apps open the app with a link or a file, which can carry instructions for it. Off, Revoke asks you first."
        case .other:
            "\(title): Automation, the camera and microphone, files and folders, and more. macOS keeps these where only Apple's own software can see them, so Revoke can't show them, but it can reset them: the app asks again next time."
        }
    }

    var symbol: String {
        switch self {
        case .running: "play.circle"
        case .deviceControl: "cursorarrow.rays"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .inputMonitoring: "keyboard"
        case .fullDiskAccess: "internaldrive"
        case .localNetwork: "network"
        case .links: "link"
        case .other: "ellipsis.circle"
        }
    }

    /// The service name in the system's TCC database. Running, Local Network and Links
    /// aren't part of TCC, and Other's services are in each user's database.
    var tccService: String? {
        switch self {
        case .deviceControl: "kTCCServiceAccessibility"
        case .screenRecording: "kTCCServiceScreenCapture"
        case .inputMonitoring: "kTCCServiceListenEvent"
        case .fullDiskAccess: "kTCCServiceSystemPolicyAllFiles"
        case .running, .localNetwork, .links, .other: nil
        }
    }

    /// The names `tccutil reset` takes. System Settings lists System Audio Recording
    /// Only in the screen recording pane, so revoking screen recording revokes both.
    var tccutilServices: [String] {
        switch self {
        case .deviceControl: ["Accessibility"]
        case .screenRecording: ["ScreenCapture", "AudioCapture"]
        case .inputMonitoring: ["ListenEvent"]
        case .fullDiskAccess: ["SystemPolicyAllFiles"]
        case .other: OtherAccess.allCases.flatMap(\.tccutilServices)
        case .running, .localNetwork, .links: []
        }
    }

    /// Opens the pane in System Settings. macOS 27 has no link to Local Network, so
    /// that one lands on Privacy & Security, a click away.
    var settingsURL: URL? {
        let anchor = switch self {
        case .deviceControl: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .localNetwork: "Privacy_LocalNetwork"
        case .other: ""
        case .running, .links: nil as String?
        }
        guard let anchor else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static let fullDiskAccessURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// Access macOS keeps in each user's privacy database. macOS 27 keeps that where only
/// Apple's own software can read it (tccd answers other apps only with a private
/// entitlement), so Revoke can't show who has these, but `tccutil` resets them.
enum OtherAccess: CaseIterable, Identifiable {
    /// Controlling other apps with Apple events, as AppleScript does.
    case automation
    case camera
    case microphone
    /// Desktop, Documents and Downloads, and network and removable volumes.
    case files
    /// Changing or deleting other apps.
    case appManagement
    /// Contacts, Calendars, Reminders and Photos.
    case personalData

    var id: Self { self }

    var title: String {
        switch self {
        case .automation: "Automation"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .files: "Files & Folders"
        case .appManagement: "App Management"
        case .personalData: "Contacts, Calendars, Reminders & Photos"
        }
    }

    /// What it lets an app do, for the menu's tooltip.
    var explanation: String {
        switch self {
        case .automation: "Lets the app control other apps with Apple events, as AppleScript does: Terminal, Finder, Mail, System Events, and anything else you allowed. Resetting it clears every app it was allowed to control."
        case .camera: "Lets the app use the camera."
        case .microphone: "Lets the app use the microphone."
        case .files: "Lets the app read and change what's in Desktop, Documents, and Downloads, and on network and removable volumes."
        case .appManagement: "Lets the app change or delete other apps, Revoke included."
        case .personalData: "Lets the app read your contacts, calendars, reminders, and photos."
        }
    }

    var tccutilServices: [String] {
        switch self {
        case .automation: ["AppleEvents"]
        case .camera: ["Camera"]
        case .microphone: ["Microphone"]
        case .files: ["SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder",
                      "SystemPolicyNetworkVolumes", "SystemPolicyRemovableVolumes"]
        case .appManagement: ["SystemPolicyAppBundles"]
        case .personalData: ["AddressBook", "Calendar", "Reminders", "Photos"]
        }
    }

    /// The Info.plist keys that show an app can ask for it. macOS turns an app down, or
    /// stops it, when it asks without one. Any app can ask for files and folders, and
    /// for App Management, which has no key.
    var usageKeys: [String]? {
        switch self {
        case .automation: ["NSAppleEventsUsageDescription"]
        case .camera: ["NSCameraUsageDescription"]
        case .microphone: ["NSMicrophoneUsageDescription"]
        case .files, .appManagement: nil
        case .personalData: ["NSContactsUsageDescription", "NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription",
                             "NSCalendarsWriteOnlyAccessUsageDescription", "NSRemindersUsageDescription",
                             "NSRemindersFullAccessUsageDescription", "NSPhotoLibraryUsageDescription",
                             "NSPhotoLibraryAddUsageDescription"]
        }
    }

    /// The hardened runtime's entitlements that let an app ask for it, which an app
    /// can have without the Info.plist key.
    var entitlementPrefixes: [String] {
        switch self {
        case .automation: ["com.apple.security.automation.apple-events"]
        case .camera: ["com.apple.security.device.camera"]
        case .microphone: ["com.apple.security.device.audio-input", "com.apple.security.device.microphone"]
        case .files, .appManagement: []
        case .personalData: ["com.apple.security.personal-information.addressbook", "com.apple.security.personal-information.calendars",
                             "com.apple.security.personal-information.photos-library"]
        }
    }

    /// What an app can ask for, from its Info.plist and entitlements.
    static func askable(info: [String: Any], entitlements: [String: Any]) -> [OtherAccess] {
        allCases.filter { access in
            guard let keys = access.usageKeys else { return true }
            return keys.contains { info[$0] != nil } || access.entitlementPrefixes.contains { entitlements[$0] as? Bool == true }
        }
    }
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
    /// An app can have several entries for one column. It has the access if any allows
    /// it, since the earliest of those.
    mutating func add(_ entry: Entry, for client: Client, _ pane: Pane) {
        guard let existing = entries[client]?[pane] else {
            entries[client, default: [:]][pane] = entry
            return
        }
        var merged = existing
        if entry.access == .allowed {
            merged.since = existing.access == .allowed ? [existing.since, entry.since].compactMap { $0 }.min() : entry.since
            merged.access = .allowed
        }
        merged.isAppleSystem = existing.isAppleSystem && entry.isAppleSystem
        entries[client]?[pane] = merged
    }

    /// Whether Revoke can see a column's entries: TCC's need Full Disk Access.
    func canRead(_ pane: Pane) -> Bool {
        pane.tccService == nil || canReadTCC
    }

    /// False until Revoke has Full Disk Access.
    var canReadTCC = false
    var canReadLocalNetwork = false
}
