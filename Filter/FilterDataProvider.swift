import Foundation
import Network
import NetworkExtension
import os

/// Drops connections from blocked apps to the local network and lets everything
/// else through.
///
/// The filter's rules only hand it connections bound for local-network addresses;
/// the rest never reach this code. If the extension stops or crashes, macOS lets
/// traffic through rather than cutting the Mac off.
final class FilterDataProvider: NEFilterDataProvider {
    private let control = ControlService()
    private let log = Logger(subsystem: "dev.benjweaver.Revoke.Filter", category: "filter")

    override func startFilter(completionHandler: @escaping @Sendable (Error?) -> Void) {
        control.start()
        let rules = LocalNetwork.ranges.map { range in
            NEFilterRule(networkRule: NENetworkRule(
                remoteNetworkEndpoint: .hostPort(host: range.host, port: .any),
                remotePrefix: range.prefix,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .any,
                direction: .outbound), action: .filterData)
        }
        apply(NEFilterSettings(rules: rules, defaultAction: .allow)) { error in
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
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
