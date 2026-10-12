import XCTest
@testable import IvyCore

/// NetGroup bucketing
final class NetGroupTests: XCTestCase {

    /// IPv4 buckets by /16 (first two octets)
    func testIpv4Grouping() {
        XCTAssert(NetGroup.group("192.168.1.1") == "v4:192.168")
        XCTAssert(NetGroup.group("192.168.250.7") == "v4:192.168")
        XCTAssert(NetGroup.group("10.0.0.1") == "v4:10.0")
        XCTAssert(NetGroup.group("10.1.0.1") != NetGroup.group("10.0.0.1"))
    }

    /// two IPv6 addresses in one /32 collapse to one group
    func testIpv6Collapses() {
        let a = NetGroup.group("2001:db8::1")
        let b = NetGroup.group("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff")
        XCTAssert(a == b)
        XCTAssert(a == "v6:2001.0db8")
        // A different /32 must not collide.
        XCTAssert(NetGroup.group("2001:db9::1") != a)
    }

    /// IPv6 forms (brackets, zone, full, ::) normalize consistently
    func testIpv6Forms() {
        let canonical = NetGroup.group("2001:db8::1")
        XCTAssert(NetGroup.group("[2001:db8::1]") == canonical)
        XCTAssert(NetGroup.group("2001:db8::1%en0") == canonical)
        XCTAssert(NetGroup.group("2001:0db8:0000:0000:0000:0000:0000:0001") == canonical)
        XCTAssert(NetGroup.group("::1") == "v6:0000.0000")
    }

    /// IPv4-mapped IPv6 (::ffff:) groups by the embedded IPv4 /16
    func testIpv4MappedIPv6() {
        // A dual-stack socket reports an inbound IPv4 peer as ::ffff:a.b.c.d — it
        // must collapse onto the SAME group as the bare IPv4, else it bypasses
        // the netgroup cap.
        XCTAssert(NetGroup.group("::ffff:1.2.3.4") == "v4:1.2")
        XCTAssert(NetGroup.group("::ffff:1.2.3.4") == NetGroup.group("1.2.3.4"))
        XCTAssert(NetGroup.group("::ffff:1.2.99.4") == "v4:1.2")      // same /16 collapses
        XCTAssert(NetGroup.group("::FFFF:1.2.3.4") == "v4:1.2")        // case-insensitive
        XCTAssert(NetGroup.group("[::ffff:1.2.3.4]") == "v4:1.2")      // bracketed
        XCTAssert(NetGroup.group("::ffff:0102:0304") == "v4:1.2")
        XCTAssert(NetGroup.group("::ffff:0102:0304") == NetGroup.group("1.2.3.4"))
        // A genuine IPv6 with a trailing embedded IPv4 still groups by its /32.
        XCTAssert(NetGroup.group("2001:db8::1.2.3.4") == "v6:2001.0db8")
    }

    /// IPv4 and IPv6 groups never collide
    func testFamiliesDoNotCollide() {
        // No v4 group can equal a v6 group due to tag prefixes.
        let v4 = NetGroup.group("0.0.0.1")
        let v6 = NetGroup.group("::1")
        XCTAssert(v4.hasPrefix("v4:"))
        XCTAssert(v6.hasPrefix("v6:"))
        XCTAssert(v4 != v6)
    }

    /// malformed hosts fall back to their own raw group
    func testMalformedFallsBack() {
        XCTAssert(NetGroup.group("not-an-ip") == "raw:not-an-ip")
        XCTAssert(NetGroup.group("999.1.1.1") == "raw:999.1.1.1")   // octet out of range
        XCTAssert(NetGroup.group("1.2.3") == "raw:1.2.3")            // too few octets
        XCTAssert(NetGroup.group("2001:db8::xyz") == "raw:2001:db8::xyz") // bad hex
        XCTAssert(NetGroup.group("2606::4700:1:2:3:4:5:6")
            == "raw:2606::4700:1:2:3:4:5:6") // :: must compress at least one group
        // Two distinct malformed hosts get distinct groups (no merge).
        XCTAssert(NetGroup.group("foo") != NetGroup.group("bar"))
    }
}
