import Foundation
import Tally

enum EndpointProvenance {
    case selfAdvertisement
    case referral(String)

    var label: String {
        switch self {
        case .selfAdvertisement: "session metadata"
        case .referral(let source): source
        }
    }
}

enum LookupRouteSource: Hashable, Sendable, Comparable {
    case referral(String)
    case authenticated

    private var sortKey: String {
        switch self {
        case .referral(let peer): peer
        case .authenticated: "~authenticated"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.sortKey < rhs.sortKey }
}

struct LookupRoute: Equatable, Sendable {
    let endpoint: PeerEndpoint
    let source: LookupRouteSource
}

extension IvyCore {
    func isAcceptableDiscoveredEndpoint(
        _ endpoint: PeerEndpoint,
        provenance: EndpointProvenance,
        from peer: PeerID
    ) -> Bool {
        if case .referral = provenance, !config.mode.participatesInPublicDiscovery {
            return false
        }
        let source = provenance.label
        guard let key = try? PeerKey(endpoint.publicKey), config.allowsEndpoint(key) else {
            config.logger.warning("Rejecting \(source) endpoint from \(peer.publicKey.prefix(16))…: empty public key")
            return false
        }

        let discovered = key.peerID
        guard discovered != localID else { return false }

        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              host != "0.0.0.0",
              host != "::",
              host != "unknown",
              endpoint.port != 0 else {
            config.logger.warning("Rejecting \(source) endpoint \(endpoint.publicKey.prefix(16))… from \(peer.publicKey.prefix(16))…: unusable address")
            return false
        }

        if !allowsDiscoveredHost(
            host,
            provenance: provenance,
            fromObservedHost: endpointLink(for: peer)?.observedHost
        ) {
            config.logger.warning("Rejecting \(source) endpoint \(endpoint.publicKey.prefix(16))… from \(peer.publicKey.prefix(16))…: non-routable address \(host)")
            return false
        }

        // Measure the canonical raw key form (ed01 Multikey prefix stripped)
        // so a key ground to the threshold passes regardless of which
        // spelling the endpoint record carries.
        if config.minPeerKeyBits > 0 {
            let bits = KeyDifficulty.keyWorkBits(key.hex)
            guard bits >= config.minPeerKeyBits else {
                config.logger.warning("Rejecting \(source) endpoint \(endpoint.publicKey.prefix(16))… from \(peer.publicKey.prefix(16))…: \(bits) key PoW bits, need \(config.minPeerKeyBits)")
                return false
            }
        }

        return true
    }

    func allowsDiscoveredHost(
        _ host: String,
        provenance: EndpointProvenance,
        fromObservedHost sourceHost: String?
    ) -> Bool {
        if !isNonRoutableDiscoveredHost(host) { return true }
        guard case .selfAdvertisement = provenance,
              isPrivateUnicastHost(host) || isLoopbackHost(host),
              let sourceHost else { return false }
        return sameIPAddress(host, sourceHost)
    }

    private func sameIPAddress(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if let left = discoveredIPv4Octets(left),
           let right = discoveredIPv4Octets(right) {
            return left == right
        }
        if let left = NetGroup.ipv6Hextets(left),
           let right = NetGroup.ipv6Hextets(right) {
            return left == right
        }
        return false
    }

    /// True if `host` is NOT a globally-routable IP literal: a non-IP string, or
    /// an address in any non-global / special-use range. Parses the FULL address
    /// (all four IPv4 octets / all eight IPv6 hextets) via the canonical
    /// `NetGroup` parser, NOT the coarse /16-/32 group grain — so a /24 or /32
    /// special range (e.g. an RFC 5737 TEST-NET) is classified precisely without
    /// over-rejecting the real-public space surrounding it.
    func isNonRoutableDiscoveredHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let octets = discoveredIPv4Octets(trimmed) {
            return Self.isNonRoutableIPv4(octets)
        }
        if trimmed.contains(":"), let hextets = NetGroup.ipv6Hextets(trimmed) {
            return Self.isNonRoutableIPv6(hextets)
        }
        return true   // not an IP literal
    }

    private func isPrivateUnicastHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = discoveredIPv4Octets(trimmed) {
            return o[0] == 10
                || (o[0] == 172 && (16...31).contains(o[1]))
                || (o[0] == 192 && o[1] == 168)
        }
        if let h = NetGroup.ipv6Hextets(trimmed) {
            return (0xfc00...0xfdff).contains(h[0])
        }
        return false
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = discoveredIPv4Octets(trimmed) { return o[0] == 127 }
        guard let h = NetGroup.ipv6Hextets(trimmed) else { return false }
        return h.dropLast().allSatisfy { $0 == 0 } && h.last == 1
    }

    private func discoveredIPv4Octets(_ host: String) -> [Int]? {
        if let octets = NetGroup.ipv4Octets(host) { return octets }
        return host.contains(":") ? NetGroup.embeddedIPv4Octets(host) : nil
    }

    /// Precise IPv4 special-use classification over the full dotted-quad.
    static func isNonRoutableIPv4(_ o: [Int]) -> Bool {
        let (a, b, c, d) = (o[0], o[1], o[2], o[3])
        switch a {
        case 0: return true                              // "this network" 0.0.0.0/8 (RFC 1122)
        case 10: return true                             // private 10.0.0.0/8 (RFC 1918)
        case 127: return true                            // loopback 127.0.0.0/8 (RFC 1122)
        case 100: return (64...127).contains(b)          // CGNAT/shared 100.64.0.0/10 (RFC 6598)
        case 169: return b == 254                        // link-local 169.254.0.0/16 (RFC 3927)
        case 172: return (16...31).contains(b)           // private 172.16.0.0/12 (RFC 1918)
        case 192:
            if b == 168 { return true }                  // private 192.168.0.0/16 (RFC 1918)
            if b == 0 && c == 0 { return d != 9 && d != 10 } // IETF special-purpose /24; two global anycasts
            if b == 0 && c == 2 { return true }          // TEST-NET-1 192.0.2.0/24 (RFC 5737)
            if b == 88 && c == 99 { return true }        // deprecated 6to4 relay anycast 192.88.99.0/24
            return false
        case 198:
            if b == 18 || b == 19 { return true }        // benchmarking 198.18.0.0/15 (RFC 2544)
            if b == 51 && c == 100 { return true }       // TEST-NET-2 198.51.100.0/24 (RFC 5737)
            return false
        case 203:
            if b == 0 && c == 113 { return true }        // TEST-NET-3 203.0.113.0/24 (RFC 5737)
            return false
        case 224...239: return true                      // multicast 224.0.0.0/4 (RFC 5771)
        case 240...255: return true                      // reserved 240.0.0.0/4, incl. broadcast (RFC 1112)
        default: return false
        }
    }

    /// Returns the IPv4 address embedded by the globally reachable NAT64
    /// well-known prefix, or nil for every other IPv6 form.
    static func embeddedTransitionIPv4(_ h: [UInt16]) -> [Int]? {
        func octets(_ hi: UInt16, _ lo: UInt16) -> [Int] {
            [Int(hi >> 8), Int(hi & 0xff), Int(lo >> 8), Int(lo & 0xff)]
        }
        // NAT64 well-known prefix 64:ff9b::/96 (RFC 6052): 0064:ff9b then 64 zero
        // bits; the embedded IPv4 is the last two hextets.
        if h[0] == 0x0064, h[1] == 0xff9b, h[2] == 0, h[3] == 0, h[4] == 0, h[5] == 0 {
            return octets(h[6], h[7])
        }
        return nil
    }

    /// Precise IPv6 special-use classification over the full eight hextets.
    static func isNonRoutableIPv6(_ h: [UInt16]) -> Bool {
        let first = h[0]
        // The NAT64 well-known prefix is globally reachable, but its embedded
        // destination must still pass the IPv4 special-purpose filter.
        if let v4 = embeddedTransitionIPv4(h) { return isNonRoutableIPv4(v4) }
        if !(0x2000...0x3fff).contains(first) { return true } // outside global unicast 2000::/3
        if first == 0x2001 && h[1] <= 0x01ff {
            let exactAnycast = h[1] == 1
                && h[2...6].allSatisfy { $0 == 0 }
                && (1...3).contains(h[7])
            let globalAssignment = exactAnycast
                || h[1] == 3
                || (h[1] == 4 && h[2] == 0x0112)
                || (0x0030...0x003f).contains(h[1])
            if !globalAssignment { return true }
        }
        if first == 0x2001 && h[1] == 0x0db8 { return true } // documentation 2001:db8::/32 (RFC 3849)
        if first == 0x2002 { return true }                  // deprecated 6to4 2002::/16
        if first == 0x3fff && h[1] <= 0x0fff { return true } // documentation 3fff::/20
        return false
    }
}

func selectedLookupRoutes(
    _ routes: [LookupRoute],
    preferred: PeerEndpoint?,
    maxRoutesPerIdentity: Int
) -> [LookupRoute] {
    var unique: [PeerEndpoint: LookupRoute] = [:]
    for route in routes where unique[route.endpoint] == nil { unique[route.endpoint] = route }

    var selected: [LookupRoute] = []
    if let preferred {
        selected.append(unique.removeValue(forKey: preferred)
            ?? LookupRoute(endpoint: preferred, source: .authenticated))
    }
    let bySource = Dictionary(grouping: unique.values, by: \.source).mapValues {
        $0.sorted {
            ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port)
        }
    }
    for index in 0..<maxRoutesPerIdentity {
        for source in bySource.keys.sorted()
            where selected.count < maxRoutesPerIdentity {
            let alternatives = bySource[source] ?? []
            if alternatives.indices.contains(index) { selected.append(alternatives[index]) }
        }
    }
    return selected
}
