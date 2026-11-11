import Foundation
import Network
import NetworkExtension
import os

/// Drops connections between blocked apps and the local network, both ways, and lets
/// everything else through: a blocked app can't reach devices on your network, and
/// they can't connect to it.
///
/// The filter's rules only hand it connections to or from local-network addresses;
/// the rest never reach this code. If the extension stops or crashes, macOS lets
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
        return NEFilterSettings(rules: rules, defaultAction: .allow)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        pathMonitor.cancel()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let flow = flow as? NEFilterSocketFlow, !control.isEmpty else { return .allow() }
        guard let remote = flow.remoteFlowEndpoint else {
            // Not addressed yet, like a UDP socket that names its destination per
            // packet: decide when the first data goes out.
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: 1)
        }
        return blocks(flow, going: remote) ? .drop() : .allow()
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        guard let flow = flow as? NEFilterSocketFlow, let remote = flow.remoteFlowEndpoint else { return .allow() }
        return blocks(flow, going: remote) ? .drop() : .allow()
    }

    private func blocks(_ flow: NEFilterSocketFlow, going remote: NWEndpoint) -> Bool {
        guard LocalNetwork.contains(remote) else { return false }
        let identifiers = AppIdentity.identifiers(of: flow)
        guard control.blocks(any: identifiers) else { return false }
        log.notice("Dropped a local network connection from \(identifiers.sorted(), privacy: .public)")
        return true
    }
}
