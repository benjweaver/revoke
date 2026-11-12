import Foundation
import Network
import NetworkExtension
import os

/// Drops connections between blocked apps and the local network, both ways, and lets
/// everything else through: a blocked app can't reach devices on your network, and
/// they can't connect to it.
///
/// It also keeps apps limited to their model provider off the rest of the internet.
///
/// The filter's rules only hand it connections to or from local-network addresses,
/// unless some app is limited; the rest never reach this code. If the extension stops or crashes, macOS lets
/// traffic through rather than cutting the Mac off.
// Unchecked because NEFilterDataProvider isn't marked Sendable, though the system
// already calls it from any thread. Its own state is immutable lets of Sendable
// types, and the subnets it filters sit behind LocalNetwork's Mutex.
final class FilterDataProvider: NEFilterDataProvider, @unchecked Sendable {
    private let control = ControlService()
    private let log = Logger(subsystem: "dev.benjweaver.Revoke.Filter", category: "filter")
    /// Watches for the Mac joining or leaving a network, whose subnets then become
    /// or stop being local.
    private let pathMonitor = NWPathMonitor()

    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        control.onLimitsChange = { [weak self] in self?.reapply(why: "The internet limits changed") }
        control.start()
        LocalNetwork.refreshOnLinkRanges()
        apply(settings()) { [weak self] error in
            // Watched once the first settings are in, so a second apply can't land
            // before them with older subnets.
            if error == nil { self?.watchNetwork() }
            completionHandler(error)
        }
    }

    /// Rebuilds the rules when the Mac's subnets change. The first update arrives at
    /// once and only reapplies if the subnets changed since the filter started.
    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard LocalNetwork.refreshOnLinkRanges(), let self else { return }
            self.log.notice("The network changed; filtering \(LocalNetwork.ranges.map { "\($0.address)/\($0.prefix)" }, privacy: .public)")
            self.apply(self.settings()) { [log = self.log] error in
                if let error { log.error("Couldn't update the filter's rules: \(error, privacy: .public)") }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.benjweaver.Revoke.Filter.path"))
    }

    private func reapply(why: String) {
        log.notice("\(why, privacy: .public); applying the filter's rules again")
        apply(settings()) { [log] error in
            if let error { log.error("Couldn't update the filter's rules: \(error, privacy: .public)") }
        }
    }

    /// Rules that hand the filter every connection to or from a local-network
    /// address, rebuilt whenever the Mac's subnets change.
    private func settings() -> NEFilterSettings {
        let rules = LocalNetwork.ranges.map { range in
            NEFilterRule(networkRule: NENetworkRule(
                remoteNetworkEndpoint: .hostPort(host: range.host, port: .any),
                remotePrefix: range.prefix,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .any,
                // Inbound too, so a device on the network can't connect to a server the
                // app runs, as Revoke for Windows closes its inbound firewall rules.
                direction: .any), action: .filterData)
        }
        // While an app is kept to its model provider, the filter has to see where every
        // connection goes. Otherwise the rest of the Mac's traffic never comes near it.
        return NEFilterSettings(rules: rules, defaultAction: control.hasLimits ? .filterData : .allow)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        pathMonitor.cancel()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let flow = flow as? NEFilterSocketFlow, !control.isEmpty || control.hasLimits else { return .allow() }
        guard let remote = flow.remoteFlowEndpoint else {
            // Not addressed yet, like a UDP socket that names its destination per
            // packet: decide when the first data goes out.
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: 1)
        }
        if LocalNetwork.contains(remote) { return blocks(flow, going: remote) ? .drop() : .allow() }
        switch internetVerdict(for: flow, going: remote, firstBytes: nil) {
        case .allow: return .allow()
        case .drop: return .drop()
        case .needsHello:
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: Self.helloBytes)
        }
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        guard let flow = flow as? NEFilterSocketFlow, let remote = flow.remoteFlowEndpoint else { return .allow() }
        if LocalNetwork.contains(remote) { return blocks(flow, going: remote) ? .drop() : .allow() }
        switch internetVerdict(for: flow, going: remote, firstBytes: offset == 0 ? readBytes : nil) {
        case .allow: return .allow()
        case .drop: return .drop()
        case .needsHello:
            // The hello came in pieces: look again when more of it is here.
            guard offset == 0, readBytes.count < Self.helloLimit else { return .drop() }
            return NEFilterDataVerdict(passBytes: 0, peekBytes: readBytes.count + Self.helloBytes)
        }
    }

    private func blocks(_ flow: NEFilterSocketFlow, going remote: NWEndpoint) -> Bool {
        guard !control.isEmpty else { return false }
        let identifiers = AppIdentity.identifiers(of: flow)
        guard control.blocks(any: identifiers) else { return false }
        log.notice("Dropped a local network connection from \(identifiers.sorted(), privacy: .public)")
        return true
    }

    // MARK: - The internet

    /// How much of a connection's start to ask for at a time, and when to give up on
    /// finding a TLS hello in it. Hellos run to a couple of thousand bytes.
    private static let helloBytes = 4096
    private static let helloLimit = 16384

    private enum InternetVerdict {
        case allow, drop
        /// A TLS connection to an address, whose server name is in its first bytes.
        case needsHello
    }

    /// What to do with a connection that isn't to the local network. Only apps kept to
    /// their model provider are looked at; everything else goes straight through.
    private func internetVerdict(for flow: NEFilterSocketFlow, going remote: NWEndpoint,
                                 firstBytes: Data?) -> InternetVerdict {
        guard control.hasLimits, !Self.isLoopback(remote) else { return .allow }
        let identifiers = AppIdentity.identifiers(of: flow)
        guard let allowed = control.internetHosts(for: identifiers) else { return .allow }
        let who = identifiers.sorted()
        guard flow.direction == .outbound else {
            log.notice("Dropped a connection from the internet to \(who, privacy: .public)")
            return .drop
        }
        // macOS knows a name when the app connected by name, or looked the address up
        // just before. That name has to be allowed, and it isn't enough on its own:
        // one address serves many sites, so a TLS connection must also ask for an
        // allowed name itself.
        var isVouchedFor = false
        if let name = flow.remoteHostname, InternetHosts.normalized(name) != nil {
            guard verdict(for: name, allowed: allowed, who: who) == .allow else { return .drop }
            isVouchedFor = true
        }
        guard flow.socketProtocol == IPPROTO_TCP else {
            if isVouchedFor { return .allow }
            log.notice("Dropped an internet connection without a host name from \(who, privacy: .public)")
            return .drop
        }
        guard let firstBytes else { return .needsHello }
        switch TLSClientHello.serverName(in: firstBytes) {
        case .name(let name): return verdict(for: name, allowed: allowed, who: who)
        case .incomplete: return .needsHello
        case .noName, .notTLS:
            // Plain HTTP and the like, which name no host of their own.
            if isVouchedFor { return .allow }
            log.notice("Dropped an internet connection that names no host from \(who, privacy: .public)")
            return .drop
        }
    }

    private func verdict(for name: String, allowed: [String], who: [String]) -> InternetVerdict {
        if InternetHosts.matches(name, allowed) { return .allow }
        log.notice("Dropped a connection to \(name, privacy: .public) from \(who, privacy: .public)")
        return .drop
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }
}
