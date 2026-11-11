import Combine
import Foundation

/// User preferences, stored locally in UserDefaults. Nothing leaves the machine.
@MainActor
final class Settings: ObservableObject {
    /// Apps from these developers are watched unless unchecked.
    static var watchedVendors: Set<String> { Client.watchedVendors }
    static let timeLimits = [15, 30, 60, 120, 240]

    private let defaults = UserDefaults.standard
    /// Runs after every change, so the model can check deadlines again.
    var onChange: (() -> Void)?

    @Published var revokeOnQuit: Bool {
        didSet { defaults.set(revokeOnQuit, forKey: "revokeOnQuit"); onChange?() }
    }
    @Published var revokeAfterLimit: Bool {
        didSet {
            defaults.set(revokeAfterLimit, forKey: "revokeAfterLimit")
            // Count from now, so switching this on doesn't cut off access that was
            // granted hours ago on the spot.
            if revokeAfterLimit && !oldValue {
                limitStart = Date()
                defaults.set(limitStart, forKey: "limitStart")
            }
            onChange?()
        }
    }
    @Published var limitMinutes: Int {
        didSet { defaults.set(limitMinutes, forKey: "limitMinutes"); onChange?() }
    }
    @Published var revokeOnSleepOrLock: Bool {
        didSet { defaults.set(revokeOnSleepOrLock, forKey: "revokeOnSleepOrLock"); onChange?() }
    }
    /// Whether the menu bar lock opens only while a watched app is running, rather than
    /// also while one has Device Control, Screen Recording, or Input Monitoring.
    @Published var lockFollowsRunningOnly: Bool {
        didSet { defaults.set(lockFollowsRunningOnly, forKey: "lockFollowsRunningOnly"); onChange?() }
    }
    /// Watched apps from other developers, and unwatched ones from the watched developers.
    @Published private var added: Set<String> {
        didSet { defaults.set(Array(added), forKey: "watched") }
    }
    @Published private var removed: Set<String> {
        didSet { defaults.set(Array(removed), forKey: "unwatched") }
    }
    /// Unwatched apps hidden from the panel's list of other apps, by client key.
    @Published private(set) var hidden: Set<String> {
        didSet { defaults.set(hidden.sorted(), forKey: "hidden") }
    }
    /// The time limit never counts from before it was switched on.
    private(set) var limitStart: Date
    /// Apps, by bundle ID, that the network filter keeps off the local network, as it
    /// last said. This is a copy for the panel only: the filter's own list, saved as
    /// root, is the one that counts, and Revoke never sends this one back to it.
    @Published private(set) var localNetworkBlocked: Set<String> {
        didSet { defaults.set(localNetworkBlocked.sorted(), forKey: "localNetworkBlocked"); onChange?() }
    }
    /// Apps, by bundle ID, that the network filter keeps to their model provider's hosts
    /// on the internet, as it last said. A copy for the panel, like the list above.
    @Published private(set) var internetLimited: Set<String> {
        didSet { defaults.set(internetLimited.sorted(), forKey: "internetLimited"); onChange?() }
    }
    /// Hosts every limited app may reach besides its developer's own, such as a proxy
    /// or a model you host yourself. They take effect the next time an app is limited.
    @Published var extraInternetHosts: [String] {
        didSet { defaults.set(extraInternetHosts, forKey: "extraInternetHosts") }
    }
    /// Apps, by bundle ID, whose links and files Revoke asks about before they open.
    @Published private(set) var linksBlocked: Set<String> {
        didSet { defaults.set(linksBlocked.sorted(), forKey: "linksBlocked") }
    }
    /// The app each link Revoke stands in for belongs to, to open on Yes and to give
    /// the link back to.
    private(set) var linkOwners: [Link: LinkOwner] {
        didSet { defaults.set(try? JSONEncoder().encode(linkOwners.map(SavedOwner.init)), forKey: "linkOwners") }
    }

    private struct SavedOwner: Codable {
        let link: Link
        let owner: LinkOwner
        init(_ pair: (key: Link, value: LinkOwner)) { (link, owner) = pair }
    }

    init() {
        revokeOnQuit = defaults.bool(forKey: "revokeOnQuit")
        revokeAfterLimit = defaults.bool(forKey: "revokeAfterLimit")
        let minutes = defaults.integer(forKey: "limitMinutes")
        limitMinutes = Self.timeLimits.contains(minutes) ? minutes : 30
        revokeOnSleepOrLock = defaults.bool(forKey: "revokeOnSleepOrLock")
        lockFollowsRunningOnly = defaults.bool(forKey: "lockFollowsRunningOnly")
        added = Set(defaults.stringArray(forKey: "watched") ?? [])
        removed = Set(defaults.stringArray(forKey: "unwatched") ?? [])
        hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
        limitStart = defaults.object(forKey: "limitStart") as? Date ?? .distantPast
        localNetworkBlocked = Set(defaults.stringArray(forKey: "localNetworkBlocked") ?? [])
        internetLimited = Set(defaults.stringArray(forKey: "internetLimited") ?? [])
        extraInternetHosts = InternetHosts.parse((defaults.stringArray(forKey: "extraInternetHosts") ?? []).joined(separator: " "))
        linksBlocked = Set(defaults.stringArray(forKey: "linksBlocked") ?? [])
        let saved = defaults.data(forKey: "linkOwners").flatMap { try? JSONDecoder().decode([SavedOwner].self, from: $0) }
        linkOwners = Dictionary((saved ?? []).map { ($0.link, $0.owner) }, uniquingKeysWith: { $1 })
    }

    func isWatched(_ client: Client) -> Bool {
        if removed.contains(client.key) { return false }
        if added.contains(client.key) { return true }
        return client.vendor.map(Self.watchedVendors.contains) ?? false
    }

    func setWatched(_ client: Client, _ watched: Bool) {
        let byDefault = client.vendor.map(Self.watchedVendors.contains) ?? false
        if watched {
            removed.remove(client.key)
            if !byDefault { added.insert(client.key) }
        } else {
            added.remove(client.key)
            if byDefault { removed.insert(client.key) }
        }
        onChange?()
    }

    /// Hiding an app only takes it off the panel's list of other apps; its access stays.
    func setHidden(_ client: Client, _ hide: Bool) {
        if hide { hidden.insert(client.key) } else { hidden.remove(client.key) }
        onChange?()
    }

    var hiddenClients: [Client] { hidden.map(Client.init(key:)) }

    /// Takes on the list the network filter answered with.
    func adoptLocalNetworkBlocked(_ bundleIDs: some Sequence<String>) {
        let list = Set(bundleIDs)
        if list != localNetworkBlocked { localNetworkBlocked = list }
    }

    /// Takes on the list of limited apps the network filter answered with.
    func adoptInternetLimited(_ bundleIDs: some Sequence<String>) {
        let list = Set(bundleIDs)
        if list != internetLimited { internetLimited = list }
    }

    func setLinksBlocked(_ bundleID: String, _ blocked: Bool) {
        if blocked { linksBlocked.insert(bundleID) } else { linksBlocked.remove(bundleID) }
    }

    func setLinkOwner(_ owner: LinkOwner?, for link: Link) {
        linkOwners[link] = owner
    }

    /// Apps watched by choice rather than by developer, including ones that aren't
    /// in any list right now.
    var addedClients: [Client] { added.map(Client.init(key:)) }

    static func describe(minutes: Int) -> String {
        // A request can ask for any number of minutes, not only the time limits above.
        if minutes < 60 || minutes % 60 != 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }
}
