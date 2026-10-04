import Collaboration
import Foundation

/// Reads Local Network decisions from NetworkExtension's preferences. Any app can
/// read the file, but only root can change it, in a private format that nehelper
/// owns, so Revoke leaves changes to System Settings.
enum LocalNetworkStore {
    private static let path = "/Library/Preferences/com.apple.networkextension.plist"

    /// The current user's decision for each app that has asked, or nil when the
    /// file can't be read.
    static func read() -> [Client: Access]? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let top = plist["$top"] as? [String: Any],
              let user = CBUserIdentity(posixUID: getuid(), authority: .local())?.uniqueIdentifier
        else { return nil }

        // Each user has a configuration named after their account's UUID, stored
        // under a key that is the configuration's own UUID.
        let name = "com.apple.preferences.networkprivacy-\(user.uuidString)"
        for key in top.keys where UUID(uuidString: key) != nil {
            // A failed decode poisons an unarchiver, so each key gets a fresh one.
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.setClass(ConfigurationShim.self, forClassName: "NEConfiguration")
            unarchiver.setClass(PathControllerShim.self, forClassName: "NEPathController")
            unarchiver.setClass(PathRuleShim.self, forClassName: "NEPathRule")
            guard let configuration = unarchiver.decodeObject(of: ConfigurationShim.self, forKey: key),
                  configuration.name?.caseInsensitiveCompare(name) == .orderedSame else { continue }

            var result: [Client: Access] = [:]
            // Rules without a preference are apps that never asked.
            for rule in configuration.rules where rule.preferenceSet {
                guard let client = rule.client else { continue }
                result[client] = rule.denyMulticast ? .denied : .allowed
            }
            return result
        }
        return [:]
    }
}

// Stand-ins for NetworkExtension's private classes that decode only what Revoke needs.

@objc(RevokeConfigurationShim)
private final class ConfigurationShim: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let name: String?
    let rules: [PathRuleShim]

    init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "Name") as String?
        rules = coder.decodeObject(of: PathControllerShim.self, forKey: "PathController")?.rules ?? []
        super.init()
    }

    func encode(with coder: NSCoder) {}
}

@objc(RevokePathControllerShim)
private final class PathControllerShim: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let rules: [PathRuleShim]

    init?(coder: NSCoder) {
        rules = coder.decodeArrayOfObjects(ofClass: PathRuleShim.self, forKey: "Rules") ?? []
        super.init()
    }

    func encode(with coder: NSCoder) {}
}

@objc(RevokePathRuleShim)
private final class PathRuleShim: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let signingIdentifier: String?
    let path: String?
    let denyMulticast: Bool
    let preferenceSet: Bool

    init?(coder: NSCoder) {
        signingIdentifier = coder.decodeObject(of: NSString.self, forKey: "SigningIdentifier") as String?
        path = coder.decodeObject(of: NSString.self, forKey: "Path") as String?
        denyMulticast = coder.decodeBool(forKey: "DenyMulticast")
        preferenceSet = coder.decodeBool(forKey: "MulticastPreferenceSet")
        super.init()
    }

    func encode(with coder: NSCoder) {}

    /// Apps are matched by signing identifier, which is normally the bundle ID.
    /// Tools signed without one ("Moonlight" for a dev build) are matched by path.
    var client: Client? {
        if let id = signingIdentifier, id.contains(".") { return .bundle(id) }
        if let path { return .path(path) }
        return signingIdentifier.map(Client.bundle)
    }
}
