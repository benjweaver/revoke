import Combine
import Foundation

/// User preferences, stored locally in UserDefaults. Nothing leaves the machine.
@MainActor
final class Settings: ObservableObject {
    /// Apps from these developers are watched unless unchecked.
    static let watchedVendors: Set<String> = ["com.anthropic", "com.openai"]
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
    /// The time limit never counts from before it was switched on.
    private(set) var limitStart: Date
    /// Apps, by bundle ID, that the network filter keeps off the local network.
    @Published private(set) var localNetworkBlocked: Set<String> {
        didSet { defaults.set(localNetworkBlocked.sorted(), forKey: "localNetworkBlocked"); onChange?() }
    }

    init() {
        revokeOnQuit = defaults.bool(forKey: "revokeOnQuit")
        revokeAfterLimit = defaults.bool(forKey: "revokeAfterLimit")
        let minutes = defaults.integer(forKey: "limitMinutes")
        limitMinutes = Self.timeLimits.contains(minutes) ? minutes : 30
        revokeOnSleepOrLock = defaults.bool(forKey: "revokeOnSleepOrLock")
        added = Set(defaults.stringArray(forKey: "watched") ?? [])
        removed = Set(defaults.stringArray(forKey: "unwatched") ?? [])
        limitStart = defaults.object(forKey: "limitStart") as? Date ?? .distantPast
        localNetworkBlocked = Set(defaults.stringArray(forKey: "localNetworkBlocked") ?? [])
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

    func blockLocalNetwork(_ bundleIDs: some Sequence<String>) {
        localNetworkBlocked.formUnion(bundleIDs)
    }

    func allowLocalNetwork(_ bundleID: String) {
        localNetworkBlocked.remove(bundleID)
    }

    /// Apps watched by choice rather than by developer, including ones that aren't
    /// in any list right now.
    var addedClients: [Client] { added.map(Client.init(key:)) }

    static func describe(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }
}
