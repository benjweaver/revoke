import Darwin
import Network
import Synchronization

/// The addresses macOS counts as the local network: private and link-local
/// ranges, multicast, and broadcast, plus whatever subnets the Mac is on right
/// now. Loopback isn't among them, matching macOS's own Local Network permission,
/// so an app can still reach servers on this Mac.
enum LocalNetwork {
    struct Range: Equatable, Sendable {
        let address: String
        let prefix: Int

        var host: NWEndpoint.Host { NWEndpoint.Host(address) }
    }

    /// The ranges that are local on any network.
    static let fixedRanges = [
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

    /// Never local, even on an interface that isn't flagged as loopback, so servers
    /// on this Mac stay reachable. IPv6's ::1 is a single host, which the prefix
    /// limits below already leave out.
    private static let loopback = [Range(address: "127.0.0.0", prefix: 8)]

    /// The subnets of the Mac's active interfaces that the fixed ranges miss: a
    /// global IPv6 /64 the ISP delegated, a carrier-grade NAT 100.64.0.0/10 address,
    /// or a publicly addressed LAN. Devices there are just as local as ones at
    /// 192.168.x.x, which is how macOS's own Local Network permission treats them.
    /// Read from any thread by the filter, so it sits behind a Mutex.
    private static let onLink = Mutex<[Range]>([])

    /// The fixed ranges and the current on-link subnets, which the filter's rules
    /// are built from.
    static var ranges: [Range] { fixedRanges + onLink.withLock { $0 } }

    /// Whether an endpoint's address falls in one of the ranges. Hostnames don't:
    /// the filter sees the address a connection actually goes to.
    static func contains(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, let address = bytes(of: host) else { return false }
        return ranges.contains { covers($0, address) }
    }

    /// Reads the subnets of the Mac's interfaces again, and says whether they
    /// changed, so the caller knows to rebuild the filter's rules.
    @discardableResult
    static func refreshOnLinkRanges() -> Bool {
        let current = interfaceRanges()
        return onLink.withLock { ranges in
            guard ranges != current else { return false }
            ranges = current
            return true
        }
    }

    /// The subnet of every address on an interface that's up, leaving out loopback,
    /// point-to-point links, and tunnels: a VPN's addresses lead to a remote network,
    /// not to devices next to the Mac. Subnets the fixed ranges already cover are
    /// left out too, so they don't add rules twice.
    private static func interfaceRanges() -> [Range] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }

        var found: [Range] = []
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  !isTunnel(String(cString: entry.ifa_name)),
                  let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  let bytes = bytes(of: address), let mask = self.bytes(of: netmask, family: address.pointee.sa_family),
                  bytes.count == mask.count
            else { continue }
            let prefix = mask.reduce(0) { $0 + $1.nonzeroBitCount }
            // A host route has no neighbors to reach, and a very short prefix would
            // make much of the internet "local" and cut a blocked app off from it.
            let minimum = bytes.count == 4 ? 8 : 32
            guard prefix >= minimum, prefix < bytes.count * 8 else { continue }
            let network = zip(bytes, mask).map { $0 & $1 }
            guard !(fixedRanges + loopback).contains(where: { $0.prefix <= prefix && covers($0, network) }),
                  let range = range(network, prefix: prefix), !found.contains(range)
            else { continue }
            found.append(range)
        }
        return found
    }

    /// Tunnel interfaces that don't set IFF_POINTOPOINT: VPNs (utun, ipsec) and
    /// IPv6-over-IPv4 links (gif, stf).
    private static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "gif", "stf", "ppp"].contains { name.hasPrefix($0) }
    }

    private static func covers(_ range: Range, _ address: [UInt8]) -> Bool {
        guard let network = bytes(of: range.host), network.count == address.count else { return false }
        return matches(address, network, prefix: range.prefix)
    }

    private static func range(_ network: [UInt8], prefix: Int) -> Range? {
        let family = network.count == 4 ? AF_INET : AF_INET6
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard network.withUnsafeBytes({ inet_ntop(family, $0.baseAddress, &text, socklen_t(text.count)) }) != nil
        else { return nil }
        let address = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return Range(address: String(decoding: address, as: UTF8.self), prefix: prefix)
    }

    /// An interface address as 4 or 16 bytes. IPv6 link-local addresses from
    /// getifaddrs carry their scope in the second word, but fe80::/10 already
    /// covers them, so it doesn't matter here.
    private static func bytes(of address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        bytes(of: address, family: address.pointee.sa_family)
    }

    /// A netmask's sa_family isn't always set, so it's read as the family of the
    /// address it belongs to.
    private static func bytes(of address: UnsafeMutablePointer<sockaddr>, family: sa_family_t) -> [UInt8]? {
        switch Int32(family) {
        case AF_INET:
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
        default: nil
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
