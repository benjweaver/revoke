import Foundation
import Testing

/// Which hosts an app kept to its model provider may reach, and reading the host out of
/// the start of a TLS connection.
struct InternetHostsTests {
    @Test func aDomainCoversItsSubdomainsAndNothingElse() {
        let allowed = ["anthropic.com", "claude.ai"]
        #expect(InternetHosts.matches("api.anthropic.com", allowed))
        #expect(InternetHosts.matches("ANTHROPIC.com.", allowed))
        #expect(InternetHosts.matches("a.b.claude.ai", allowed))
        #expect(!InternetHosts.matches("notanthropic.com", allowed))
        #expect(!InternetHosts.matches("anthropic.com.example.org", allowed))
        #expect(!InternetHosts.matches("example.org", allowed))
        #expect(!InternetHosts.matches("", allowed))
        #expect(!InternetHosts.matches("api.anthropic.com", []))
    }

    @Test func tidiesWhatIsTypedAndDropsWhatIsTooBroad() {
        #expect(InternetHosts.parse("Proxy.Example.com, https://models.example.org/v1  *.example.net:8443")
                == ["proxy.example.com", "models.example.org", "example.net"])
        #expect(InternetHosts.parse("example.com example.com") == ["example.com"])
        // Nothing that would let everything through, and no addresses.
        #expect(InternetHosts.parse("* com . *.com localhost 10.0.0.1 2001:db8::1 a..b -a.com") == [])
        #expect(InternetHosts.normalized("exa mple.com") == nil)
    }

    @Test func everyBuiltInHostIsAPlainDomain() {
        for (vendor, hosts) in InternetHosts.builtIn {
            #expect(!hosts.isEmpty, "\(vendor)")
            for host in hosts { #expect(InternetHosts.normalized(host) == host, "\(host)") }
        }
    }

    @Test func readsTheServerNameFromATLSHello() {
        let hello = Self.hello(serverName: "api.example.com")
        #expect(TLSClientHello.serverName(in: hello) == .name("api.example.com"))
        // Cut anywhere short of the name, it isn't all here yet.
        for length in [0, 3, 6, 20, 60, 100] {
            #expect(TLSClientHello.serverName(in: hello.prefix(length)) == .incomplete, "\(length)")
        }
        #expect(TLSClientHello.serverName(in: Self.hello(serverName: nil)) == .noName)
    }

    @Test func turnsDownWhatIsNotATLSHello() {
        #expect(TLSClientHello.serverName(in: Data("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)) == .notTLS)
        #expect(TLSClientHello.serverName(in: Data("SSH-2.0-OpenSSH_9.9\r\n".utf8)) == .notTLS)
        // A server hello, and a name that isn't a host name.
        var other = Self.hello(serverName: "api.example.com")
        other[5] = 2
        #expect(TLSClientHello.serverName(in: other) == .notTLS)
        #expect(TLSClientHello.serverName(in: Self.hello(serverName: "10.0.0.1")) == .noName)
    }

    /// A TLS 1.2-style client hello with a few extensions around the server name.
    private static func hello(serverName: String?) -> Data {
        func sized(_ bytes: [UInt8], lengthBytes: Int) -> [UInt8] {
            (0..<lengthBytes).reversed().map { UInt8(bytes.count >> ($0 * 8) & 0xFF) } + bytes
        }
        var extensions: [UInt8] = [0x00, 0x17, 0x00, 0x00]  // extended master secret, empty
        if let serverName {
            let entry = [0x00] + sized(Array(serverName.utf8), lengthBytes: 2)
            extensions += [0x00, 0x00] + sized(sized(entry, lengthBytes: 2), lengthBytes: 2)
        }
        extensions += [0x00, 0x0B] + sized([0x01, 0x00], lengthBytes: 2)  // point formats
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32)
        body += sized([UInt8](repeating: 0x01, count: 32), lengthBytes: 1)  // session ID
        body += sized([0x13, 0x01, 0x13, 0x02], lengthBytes: 2)  // cipher suites
        body += sized([0x00], lengthBytes: 1)  // compression
        body += sized(extensions, lengthBytes: 2)
        let handshake = [0x01] + sized(body, lengthBytes: 3)
        return Data([0x16, 0x03, 0x01] + sized(handshake, lengthBytes: 2))
    }
}
