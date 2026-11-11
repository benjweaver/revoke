import Foundation

/// The hosts an app limited to its model provider may still reach on the internet.
///
/// An agent needs its provider's servers to work at all, and nothing else to do most
/// of its job. Keeping it to those means a page or a file that talks it into fetching
/// or posting somewhere else gets nowhere. The local network isn't part of this: it has
/// its own switch.
enum InternetHosts {
    /// Each developer's own domains, by the vendor part of the app's bundle ID. A
    /// subdomain of any of them counts. Apps from other developers start with none, and
    /// only reach the hosts added in Settings.
    static let builtIn: [String: [String]] = [
        "com.anthropic": ["anthropic.com", "claude.ai", "claude.com"],
        "com.openai": ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com"],
        // Cursor.
        "com.todesktop.230313mzl4w4u92": ["cursor.sh", "cursor.com"],
        "com.deepseek": ["deepseek.com"],
    ]

    /// Whether a host name is one of the allowed domains or inside one.
    /// "api.anthropic.com" is inside "anthropic.com"; "notanthropic.com" isn't.
    static func matches(_ name: String, _ allowed: some Sequence<String>) -> Bool {
        guard let name = normalized(name) else { return false }
        return allowed.contains { domain in name == domain || name.hasSuffix("." + domain) }
    }

    /// Host names as typed, one per line or separated by commas or spaces, tidied into
    /// domains: lowercased, without a scheme, path, port, or leading "*.". Anything that
    /// isn't a plain name with a dot in it is left out, so a stray "*" or "com" can't
    /// open everything.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { normalized(String($0)) }
            .filter { seen.insert($0).inserted }
    }

    /// A single host name tidied the same way, or nil when it isn't one.
    static func normalized(_ name: String) -> String? {
        var name = name.lowercased()
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        name = String(name.prefix { $0 != "/" && $0 != ":" })
        while name.hasPrefix("*.") || name.hasPrefix(".") { name = String(name.drop { $0 == "*" || $0 == "." }) }
        while name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, name.utf8.count <= 253 else { return nil }
        let isName = labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
        }
        // An address isn't a name: its last label is all digits.
        guard isName, let last = labels.last, !last.allSatisfy(\.isNumber) else { return nil }
        return name
    }
}

/// Reads the server name out of the start of a TLS connection.
///
/// Most agents resolve names themselves and connect to a bare address, so macOS has no
/// host name to give the filter. The name is in the first thing a TLS client sends,
/// unencrypted, so the server knows which site is wanted. It's the client's own claim:
/// good against an agent that was talked into visiting a site, not against one built
/// to lie about where it's going.
enum TLSClientHello {
    enum Reading: Equatable {
        case name(String)
        /// A complete hello with no server name in it, or one that hides it.
        case noName
        /// A hello that isn't all here yet.
        case incomplete
        case notTLS
    }

    static func serverName(in data: Data) -> Reading {
        let bytes = [UInt8](data)
        // Record: type 22 (handshake), version, length. Then the handshake: type 1
        // (client hello) and its length.
        guard bytes.count >= 6 else { return bytes.first.map { $0 == 22 } ?? true ? .incomplete : .notTLS }
        guard bytes[0] == 22, bytes[1] == 3, bytes[5] == 1 else { return .notTLS }
        var reader = Reader(bytes: bytes, at: 9)
        // Client version and random, then the session ID, cipher suites, and
        // compression methods, each with its own length in front.
        guard reader.skip(2 + 32), reader.skip(lengthBytes: 1), reader.skip(lengthBytes: 2),
              reader.skip(lengthBytes: 1) else { return .incomplete }
        guard let extensionsLength = reader.number(bytes: 2) else {
            // A hello may end before any extensions; a longer one is just not here yet.
            return reader.at == bytes.count && isWhole(bytes) ? .noName : .incomplete
        }
        let end = reader.at + extensionsLength
        while reader.at + 4 <= min(end, bytes.count) {
            guard let type = reader.number(bytes: 2), let length = reader.number(bytes: 2) else { return .incomplete }
            guard type == 0 else {
                guard reader.skip(length) else { return .incomplete }
                continue
            }
            // Server name: a list length, then name type 0 (host name) and the name.
            guard reader.skip(2), let kind = reader.number(bytes: 1), let nameLength = reader.number(bytes: 2),
                  let name = reader.take(nameLength) else { return .incomplete }
            guard kind == 0, let text = String(bytes: name, encoding: .utf8), let host = InternetHosts.normalized(text)
            else { return .noName }
            return .name(host)
        }
        return end <= bytes.count ? .noName : .incomplete
    }

    /// Whether the first record's stated length has all arrived.
    private static func isWhole(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 5 + (Int(bytes[3]) << 8 | Int(bytes[4]))
    }

    private struct Reader {
        let bytes: [UInt8]
        var at: Int

        mutating func skip(_ count: Int) -> Bool {
            guard at + count <= bytes.count else { return false }
            at += count
            return true
        }

        mutating func number(bytes count: Int) -> Int? {
            guard at + count <= bytes.count else { return nil }
            defer { at += count }
            return bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func skip(lengthBytes: Int) -> Bool {
            guard let length = number(bytes: lengthBytes) else { return false }
            return skip(length)
        }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard at + count <= bytes.count else { return nil }
            defer { at += count }
            return bytes[at..<at + count]
        }
    }
}
