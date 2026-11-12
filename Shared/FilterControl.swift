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
}

enum FilterIdentity {
    static let extensionBundleID = "dev.benjweaver.Revoke.Filter"
    /// The filter's XPC service. A system extension's service has to start with one
    /// of its app groups, which in turn start with the team ID.
    static let machService = "AR25V66TVY.dev.benjweaver.Revoke.filter"
    /// Only Revoke itself, signed with this team's Developer ID, may change what the
    /// filter blocks. Otherwise any app could take itself off the list.
    static let client = """
        anchor apple generic and identifier "dev.benjweaver.Revoke" and \
        certificate leaf[subject.OU] = "AR25V66TVY"
        """
}
