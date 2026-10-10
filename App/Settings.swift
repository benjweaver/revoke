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
    /// Apps, by bundle ID, that the network filter keeps off the local network.
    @Published private(set) var localNetworkBlocked: Set<String> {
        didSet { defaults.set(localNetworkBlocked.sorted(), forKey: "localNetworkBlocked"); onChange?() }
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
        added = Set(defaults.stringArray(forKey: "watched") ?? [])
        removed = Set(defaults.stringArray(forKey: "unwatched") ?? [])
        hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
        limitStart = defaults.object(forKey: "limitStart") as? Date ?? .distantPast
        localNetworkBlocked = Set(defaults.stringArray(forKey: "localNetworkBlocked") ?? [])
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

    func blockLocalNetwork(_ bundleIDs: some Sequence<String>) {
        localNetworkBlocked.formUnion(bundleIDs)
    }

    func allowLocalNetwork(_ bundleID: String) {
        localNetworkBlocked.remove(bundleID)
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
        minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }
}
