import Network

/// The addresses macOS counts as the local network: private and link-local
/// ranges, multicast, and broadcast. Loopback isn't among them, matching macOS's
/// own Local Network permission, so an app can still reach servers on this Mac.
enum LocalNetwork {
    struct Range {
        let address: String
        let prefix: Int

        var host: NWEndpoint.Host { NWEndpoint.Host(address) }
    }

    static let ranges = [
        Range(address: "10.0.0.0", prefix: 8),
        Range(address: "172.16.0.0", prefix: 12),
        Range(address: "192.168.0.0", prefix: 16),
        Range(address: "169.254.0.0", prefix: 16),
        Range(address: "224.0.0.0", prefix: 4),
        Range(address: "255.255.255.255", prefix: 32),
        Range(address: "fe80::", prefix: 10),
        Range(address: "fc00::", prefix: 7),
        Range(address: "ff00::", prefix: 8),
    ]

    /// Whether an endpoint's address falls in one of the ranges. Hostnames don't:
    /// the filter sees the address a connection actually goes to.
    static func contains(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, let address = bytes(of: host) else { return false }
        return ranges.contains { range in
            guard let network = bytes(of: range.host), network.count == address.count else { return false }
            return matches(address, network, prefix: range.prefix)
        }
    }

    /// An IPv4 address as 4 bytes or an IPv6 address as 16. IPv4 addresses mapped
    /// into IPv6 (::ffff:192.168.1.1) come out as IPv4.
    private static func bytes(of host: NWEndpoint.Host) -> [UInt8]? {
        switch host {
        case .ipv4(let address): Array(address.rawValue)
        case .ipv6(let address): address.asIPv4.map { Array($0.rawValue) } ?? Array(address.rawValue)
        default: nil
        }
    }

    private static func matches(_ address: [UInt8], _ network: [UInt8], prefix: Int) -> Bool {
        var bits = prefix
        for (a, n) in zip(address, network) where bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xFF : ~(0xFF >> UInt8(bits))
            if a & mask != n & mask { return false }
            bits -= 8
        }
        return true
    }
}
