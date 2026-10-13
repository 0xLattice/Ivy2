import Foundation
import XCTest
@testable import IvyCore

/// The core must behave the same where `Int` is 32 bits, as on WebAssembly.
/// These pin the two places where it once did not: seeded draws and sizes.
final class WordSizeTests: XCTestCase {
    /// The standard library's ranged draws go through `Int`, so they differ
    /// between word sizes. These values were recorded on a 64-bit build and
    /// must also hold when this suite runs as 32-bit WebAssembly.
    func testSeededDrawsArePinned() {
        var random = CoreRandom.seeded(42)
        XCTAssertEqual((0..<6).map { _ in random.below(1_000) }, [413, 291, 858, 764, 250, 62])
        XCTAssertEqual(random.shuffled(Array(0..<10)), [3, 0, 4, 2, 1, 6, 7, 8, 9, 5])
        XCTAssertEqual(
            random.bytes32().prefix(8).map { $0 },
            [242, 117, 29, 7, 96, 232, 153, 213])
    }

    func testBelowStaysInRangeAndCoversIt() {
        var random = CoreRandom.seeded(7)
        var seen = Set<UInt64>()
        for _ in 0..<2_000 {
            let value = random.below(7)
            XCTAssertLessThan(value, 7)
            seen.insert(value)
        }
        XCTAssertEqual(seen.count, 7)
        XCTAssertEqual(random.below(1), 0)
    }

    func testShuffleKeepsEveryElement() {
        var random = CoreRandom.seeded(11)
        let shuffled = random.shuffled(Array(0..<100))
        XCTAssertEqual(shuffled.sorted(), Array(0..<100))
        XCTAssertNotEqual(shuffled, Array(0..<100))
        XCTAssertEqual(random.shuffled([Int]()), [])
        XCTAssertEqual(random.shuffled([3]), [3])
    }

    /// A limit of `UInt32.max` is "no limit", not a trap, on any word size.
    func testTheLargestSizeLimitsAreUsable() throws {
        let key = try PeerKey(rawRepresentation: IvyConfig(
            signingKey: .init(rawRepresentation: Data(repeating: 1, count: 32))).peerKey.rawRepresentation)
        let scheme = Ed25519Scheme(signingKey: try .init(rawRepresentation: Data(repeating: 1, count: 32)))
        let record = try SessionDataRecord.sign(
            sessionID: SessionID(bytes: Data(repeating: 2, count: 32)),
            sender: key,
            receiver: key,
            sequence: 1,
            payload: Message.ping(nonce: 9).serialize(maxFrameSize: .max),
            with: scheme)
        let bytes = SessionWireRecord.data(record).serialize(maxPayload: .max)
        XCTAssertFalse(bytes.isEmpty)
        guard case .data(let decoded) = try SessionWireRecord.deserialize(bytes, maxPayload: .max) else {
            return XCTFail("not a data record")
        }
        guard case .ping(let nonce)? = Message.deserialize(decoded.payload, maxDataPayload: .max) else {
            return XCTFail("not a ping")
        }
        XCTAssertEqual(nonce, 9)
    }

    func testAFrameSizeThePlatformCannotAccountForIsRefused() throws {
        // Every UInt32 fits where Int is 64 bits; where it is 32, about 1 GiB does.
        XCTAssertEqual(IvyConfig.largestFrameSize, UInt32(clamping: (Int.max - 4) / 2))
        let config = IvyConfig(
            signingKey: try .init(rawRepresentation: Data(repeating: 1, count: 32)),
            stunServers: [],
            maxInboundBufferedBytes: .max,
            protocolMaxFrameSize: IvyConfig.largestFrameSize)
        XCTAssertNoThrow(try config.validate())
    }
}
