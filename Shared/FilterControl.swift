import Foundation

/// How the Revoke app talks to its network filter, which runs as a system
/// extension in a process of its own.
///
/// The filter's list, which it saves as root, is the one that counts. The app reads
/// it and asks for changes one way at a time, and never replaces it whole, so a copy
/// someone edited in the app's own settings can't empty it. Each call answers with
/// the apps blocked at that moment.
@objc(RevokeFilterControl)
protocol FilterControl {
    /// The apps, by code-signing identifier, kept off the local network.
    func getBlocked(reply: @escaping @Sendable ([String]) -> Void)
    /// Adds apps to the list.
    func block(_ identifiers: [String], reply: @escaping @Sendable ([String]) -> Void)
    /// Takes apps off the list. The app only asks this when the person switches an
    /// app's Local Network back on in the panel.
    func unblock(_ identifiers: [String], reply: @escaping @Sendable ([String]) -> Void)
    /// Lets blocked apps through for a while. They stay on the list, and the filter
    /// blocks them again when the time is up, whether or not the app is still running.
    /// The app only asks this when the person says yes to an app's request.
    func allow(_ identifiers: [String], minutes: Int, reply: @escaping @Sendable ([String]) -> Void)

    /// The apps kept to their model provider's hosts on the internet at this moment.
    func getLimited(reply: @escaping @Sendable ([String]) -> Void)
    /// Keeps apps to these hosts, and subdomains of them, on the internet. The local
    /// network isn't touched: that's the list above.
    func limitInternet(_ identifiers: [String], hosts: [String], reply: @escaping @Sendable ([String]) -> Void)
    /// Gives apps the whole internet back. Like `unblock`, only on the person's say-so.
    func unlimitInternet(_ identifiers: [String], reply: @escaping @Sendable ([String]) -> Void)
    /// Gives limited apps the whole internet for a while. The filter brings the limit
    /// back itself when the time is up.
    func allowInternet(_ identifiers: [String], minutes: Int, reply: @escaping @Sendable ([String]) -> Void)

    /// When each allowance given for a while ends, by code-signing identifier: first
    /// the blocked apps let onto the local network, then the limited apps given the
    /// whole internet. The panel shows these, so on-for-now doesn't look like on.
    func getAllowances(reply: @escaping @Sendable ([String: Date], [String: Date]) -> Void)
}

enum FilterIdentity {
    static let extensionBundleID = "dev.benjweaver.Revoke.Filter"
    /// The filter's XPC service. A system extension's service has to start with one
    /// of its app groups, which in turn start with the team ID.
    ///
    /// The name ends in the build number, which the app and the filter inside it
    /// share. With one name for every build, a filter that takes over from an older
    /// one can come up without its service: launchd won't give a new job a name the
    /// old job still holds, and never offers it again. The filter then runs, deaf to
    /// Revoke, until the Mac restarts.
    static let machService = "AR25V66TVY.dev.benjweaver.Revoke.filter."
        + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    /// Only Revoke itself, signed with this team's Developer ID, may change what the
    /// filter blocks. Otherwise any app could take itself off the list.
    static let client = """
        anchor apple generic and identifier "dev.benjweaver.Revoke" and \
        certificate leaf[subject.OU] = "AR25V66TVY"
        """
}
