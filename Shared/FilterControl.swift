import Foundation

/// How the Revoke app talks to its network filter, which runs as a system
/// extension in a process of its own.
@objc(RevokeFilterControl)
protocol FilterControl {
    /// Replaces the list of apps, by code-signing identifier, kept off the local network.
    func setBlocked(_ identifiers: [String], reply: @escaping @Sendable () -> Void)
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
