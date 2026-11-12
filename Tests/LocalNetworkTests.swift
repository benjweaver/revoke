import Foundation
import Network
import Testing

/// Which addresses count as the local network: the fixed private ranges, and the
/// subnets the Mac's own interfaces put it on.
struct LocalNetworkTests {
    private func address(_ text: String) -> [UInt8] {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        precondition(inet_pton(AF_INET6, text, &v6) == 1, "not an address: \(text)")
        return withUnsafeBytes(of: v6) { Array($0) }
    }

    private func mask(_ prefix: Int, bytes: Int) -> [UInt8] {
        (0..<bytes).map { index in
            let bits = min(max(prefix - index * 8, 0), 8)
            return bits == 0 ? 0 : ~(0xFF >> UInt8(bits)) & 0xFF
        }
    }

    private func onLink(_ text: String, _ prefix: Int) -> LocalNetwork.Range? {
        let bytes = address(text)
        return LocalNetwork.onLinkRange(address: bytes, mask: mask(prefix, bytes: bytes.count))
    }

    private func endpoint(_ host: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: 443)
    }

    @Test func fixedRangesCoverPrivateAddressesAndNothingPublic() {
        for local in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.64.1", "169.254.10.10", "224.0.0.251",
                      "255.255.255.255", "fe80::1", "fd12:3456::1", "ff02::fb", "::ffff:192.168.1.1"] {
            #expect(LocalNetwork.contains(endpoint(local), in: LocalNetwork.fixedRanges), "\(local)")
        }
        for other in ["8.8.8.8", "172.32.0.1", "172.15.255.255", "192.169.0.1", "100.64.3.9", "127.0.0.1", "::1",
                      "2001:db8::1", "::ffff:8.8.8.8"] {
            #expect(!LocalNetwork.contains(endpoint(other), in: LocalNetwork.fixedRanges), "\(other)")
        }
        // A name isn't an address: the filter sees where a connection really goes.
        #expect(!LocalNetwork.contains(endpoint("router.local"), in: LocalNetwork.fixedRanges))
    }

    @Test func anInterfaceAddsTheSubnetsTheFixedRangesMiss() {
        // Carrier-grade NAT, a global IPv6 prefix from the ISP, and a publicly addressed LAN.
        #expect(onLink("100.64.3.7", 24) == LocalNetwork.Range(address: "100.64.3.0", prefix: 24))
        #expect(onLink("100.100.20.9", 10) == LocalNetwork.Range(address: "100.64.0.0", prefix: 10))
        #expect(onLink("2001:db8:1:2::5", 64) == LocalNetwork.Range(address: "2001:db8:1:2::", prefix: 64))
        #expect(onLink("203.0.113.9", 24) == LocalNetwork.Range(address: "203.0.113.0", prefix: 24))
    }

    @Test func anInterfaceAddsNothingAlreadyCoveredOrTooWide() {
        // Covered by a fixed range.
        #expect(onLink("192.168.1.5", 24) == nil)
        #expect(onLink("10.0.0.5", 8) == nil)
        #expect(onLink("fd00:1::5", 64) == nil)
        #expect(onLink("fe80::1", 64) == nil)
        // Loopback stays reachable, whatever the interface says.
        #expect(onLink("127.0.0.1", 8) == nil)
        // A single host has no neighbors.
        #expect(onLink("100.64.3.7", 32) == nil)
        #expect(onLink("2001:db8::5", 128) == nil)
        // Wide enough to take much of the internet with it.
        #expect(onLink("100.64.3.7", 7) == nil)
        #expect(onLink("2001:db8::5", 16) == nil)
        // Not an address and netmask of one family.
        #expect(LocalNetwork.onLinkRange(address: address("100.64.3.7"), mask: mask(64, bytes: 16)) == nil)
        #expect(LocalNetwork.onLinkRange(address: [], mask: []) == nil)
    }

    @Test func anOnLinkSubnetCoversItsNeighborsOnly() throws {
        let ranges = LocalNetwork.fixedRanges + [try #require(onLink("100.64.3.7", 24)), try #require(onLink("2001:db8:1:2::5", 64))]
        #expect(LocalNetwork.contains(endpoint("100.64.3.200"), in: ranges))
        #expect(!LocalNetwork.contains(endpoint("100.64.4.200"), in: ranges))
        #expect(LocalNetwork.contains(endpoint("2001:db8:1:2:aaaa::9"), in: ranges))
        #expect(!LocalNetwork.contains(endpoint("2001:db8:1:3::9"), in: ranges))
    }
}
