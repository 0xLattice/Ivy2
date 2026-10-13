import Foundation
import XCTest
@testable import IvyCore

/// The core's text helpers stand in for Foundation calls, so each must give
/// what the call it replaced gave.
final class TextTests: XCTestCase {
    func testTrimmingMatchesFoundation() {
        let samples = [
            "", " ", "8.8.8.8", "  8.8.8.8\n", "\t\r\n host \u{0B}\u{0C}", "a b", " a  b ",
            "\u{00A0}nbsp\u{00A0}", "\u{2003}em\u{2003}", "\u{3000}ideographic\u{3000}",
            "\u{2028}line\u{2029}", "\u{0085}nel\u{0085}", "\u{FEFF}bom", "\u{200B}zero-width",
            " \u{0301}combining", "é ", " 🙂 ", "::1 ", "\u{1680}ogham\u{202F}\u{205F}",
        ]
        for sample in samples {
            XCTAssertEqual(
                sample.trimmingWhitespace(),
                sample.trimmingCharacters(in: .whitespacesAndNewlines),
                "\(Array(sample.unicodeScalars))")
        }
    }

    func testEveryScalarIsClassifiedAsFoundationClassifiesIt() {
        let set = CharacterSet.whitespacesAndNewlines
        for value in UInt32(0)...0x10_FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            XCTAssertEqual(
                isWhitespaceOrNewline(scalar), set.contains(scalar), "U+\(String(value, radix: 16))")
        }
    }

    func testHexMatchesFoundation() {
        for value in UInt8.min...UInt8.max {
            XCTAssertEqual(hexByte(value), String(format: "%02x", value))
        }
        for value: UInt16 in [0, 1, 0x0f, 0x10, 0xff, 0x100, 0x2001, 0xdb8, 0xfffe, 0xffff] {
            XCTAssertEqual(hexWord(value), String(format: "%04x", value))
        }
        XCTAssertEqual(hexByte(0x1ab), "ab")
    }

    func testSplittingMatchesFoundation() {
        for sample in ["", "::", "::1", "1::", "2001:db8::1", "a::b::c", ":::", "::::", "a:b:c", ":", "fe80::1%en0"] {
            XCTAssertEqual(splitOnDoubleColon(sample), sample.components(separatedBy: "::"), sample)
        }
    }

    func testUTF8ValidationMatchesFoundation() {
        let samples: [[UInt8]] = [
            [], Array("plain ascii".utf8), Array("naïve 🙂 字".utf8),
            [0xff], [0xc0, 0x80], [0xe2, 0x82], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
            [0x61, 0x80, 0x62], [0xef, 0xbb, 0xbf, 0x61], [0x00, 0x61], [0xf0, 0x9f, 0x99, 0x82],
            [0xc3], [0xe2, 0x28, 0xa1], [0xf8, 0x88, 0x80, 0x80, 0x80],
            [0xef, 0xbb, 0xbf], [0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x61], [0x61, 0xef, 0xbb, 0xbf],
        ]
        for bytes in samples {
            XCTAssertEqual(
                validUTF8String(bytes), String(data: Data(bytes), encoding: .utf8), "\(bytes)")
        }
    }
}
