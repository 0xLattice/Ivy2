import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import Ivy
@testable import IvyWebSocket

/// Collects the datagrams one socket receives.
private final class Datagrams: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let lock = NSLock()
    private var received: [ByteBuffer] = []

    var all: [ByteBuffer] { lock.withLock { received } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        lock.withLock { received.append(envelope.data) }
    }
}

final class STUNResponderTests: XCTestCase {
    private let transaction: [UInt8] = Array(1...12)

    private func request(type: [UInt8] = [0x00, 0x01], attributes: [UInt8] = []) -> [UInt8] {
        type + [UInt8(attributes.count >> 8), UInt8(attributes.count & 0xff)]
            + STUNResponder.magicCookie + transaction + attributes
    }

    /// What Ivy's own STUN client, written apart from the responder, reads.
    private func parsed(_ reply: [UInt8]?) throws -> ObservedAddress? {
        var buffer = ByteBuffer(bytes: try XCTUnwrap(reply))
        return STUNResponseHandler.parseResponse(&buffer, expectedTransactionID: transaction)
    }

    private func socket() async throws -> (Channel, Datagrams) {
        let datagrams = Datagrams()
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(datagrams) }
            .bind(host: "127.0.0.1", port: 0).get()
        return (channel, datagrams)
    }

    private func send(_ bytes: [UInt8], from channel: Channel, toPort port: UInt16) async throws {
        try await channel.writeAndFlush(AddressedEnvelope(
            remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: Int(port)),
            data: ByteBuffer(bytes: bytes))).get()
    }

    func testTheListenerAnswersABindingRequestWithWhereItCameFrom() async throws {
        let node = makeNode()
        let listener = WebSocketTransport(ivy: node)
        try await node.start()
        try await listener.listen(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(listener.boundPort)
        let (client, datagrams) = try await socket()
        let clientPort = try XCTUnwrap(client.localAddress?.port)

        try await send(request(), from: client, toPort: port)
        let answered = await eventually { datagrams.all.count == 1 }
        XCTAssertTrue(answered)
        var reply = try XCTUnwrap(datagrams.all.first)
        XCTAssertEqual(
            STUNResponseHandler.parseResponse(&reply, expectedTransactionID: transaction),
            ObservedAddress(host: "127.0.0.1", port: UInt16(clientPort)))

        // Nothing but a request is answered.
        try await send([0x00], from: client, toPort: port)
        try await send(request(type: [0x01, 0x01]), from: client, toPort: port)
        try await send(request(), from: client, toPort: port)
        let answeredAgain = await eventually { datagrams.all.count >= 2 }
        XCTAssertTrue(answeredAgain)
        XCTAssertEqual(datagrams.all.count, 2)

        await listener.stopListening()
        try await send(request(), from: client, toPort: port)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(datagrams.all.count, 2, "the responder stops with the listener")

        try await client.close().get()
        await node.stop()
    }

    func testAListenerToldNotToLeavesThePortAlone() async throws {
        let node = makeNode()
        let listener = WebSocketTransport(ivy: node)
        try await node.start()
        try await listener.listen(host: "127.0.0.1", port: 0, stun: false)
        let port = try XCTUnwrap(listener.boundPort)

        let other = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: Int(port)).get()
        try await other.close().get()
        await listener.stopListening()
        await node.stop()
    }

    func testAnIPv4AddressIsAnswered() throws {
        let reply = STUNResponder.reply(to: request(), address: [203, 0, 113, 7], port: 54321)
        XCTAssertEqual(reply?.count, 32)
        XCTAssertEqual(try parsed(reply), ObservedAddress(host: "203.0.113.7", port: 54321))
    }

    func testAnIPv6AddressIsAnswered() throws {
        let address: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34]
        let reply = STUNResponder.reply(to: request(), address: address, port: 443)
        XCTAssertEqual(reply?.count, 44)
        XCTAssertEqual(try parsed(reply), ObservedAddress(host: "2001:db8:0:0:0:0:0:1234", port: 443))
    }

    func testAnIPv4AddressOnADualStackSocketIsGivenAsIPv4() throws {
        let mapped = try SocketAddress(ipAddress: "::ffff:203.0.113.7", port: 9)
        let (address, port) = try XCTUnwrap(STUNResponder.address(of: mapped))
        XCTAssertEqual(address, [203, 0, 113, 7])
        XCTAssertEqual(port, 9)
        XCTAssertEqual(
            STUNResponder.address(of: try SocketAddress(ipAddress: "2001:db8::1", port: 9))?.address.count, 16)
    }

    func testARequestWithAttributesIsAnswered() throws {
        // SOFTWARE, which a client may add, padded to four bytes.
        let software: [UInt8] = [0x80, 0x22, 0x00, 0x03, 0x69, 0x76, 0x79, 0x00]
        let reply = STUNResponder.reply(to: request(attributes: software), address: [10, 0, 0, 1], port: 1)
        XCTAssertEqual(try parsed(reply), ObservedAddress(host: "10.0.0.1", port: 1))
    }

    func testWhatIsNotABindingRequestIsNotAnswered() {
        let address: [UInt8] = [10, 0, 0, 1]
        func reply(_ bytes: [UInt8]) -> [UInt8]? { STUNResponder.reply(to: bytes, address: address, port: 1) }

        XCTAssertNil(reply([]))
        XCTAssertNil(reply(Array(request().dropLast())), "short of a header")
        XCTAssertNil(reply(request(type: [0x01, 0x01])), "a success response")
        XCTAssertNil(reply(request(type: [0x01, 0x11])), "an error response")
        XCTAssertNil(reply(request(type: [0x00, 0x11])), "an indication")
        XCTAssertNil(reply(request(type: [0x00, 0x03])), "another method")
        XCTAssertNil(reply(request() + [0, 0, 0, 0]), "longer than it says")
        XCTAssertNil(reply(Array(request(attributes: [0x80, 0x22, 0x00, 0x00]).dropLast())), "shorter than it says")
        XCTAssertNil(reply(request(attributes: [0, 0])), "a length that is not whole words")
        var wrongCookie = request()
        wrongCookie[4] ^= 1
        XCTAssertNil(reply(wrongCookie))
        XCTAssertNil(reply(request(attributes: [UInt8](repeating: 0, count: STUNResponder.maxRequest))))
        XCTAssertNil(STUNResponder.reply(to: request(), address: [1, 2, 3], port: 1))
    }

    func testRepliesToOneAddressAreBounded() {
        var limit = STUNReplyLimit()
        let start = NIODeadline.now()
        let victim: [UInt8] = [203, 0, 113, 7]
        for _ in 0..<STUNReplyLimit.repliesPerAddress { XCTAssertTrue(limit.allows(victim, at: start)) }
        XCTAssertFalse(limit.allows(victim, at: start))
        XCTAssertTrue(limit.allows([203, 0, 113, 8], at: start), "another address is not held back")
        XCTAssertFalse(limit.allows(victim, at: start + .milliseconds(999)))
        XCTAssertTrue(limit.allows(victim, at: start + .seconds(1)))
    }

    func testAnIPv6NetworkIsCountedAsOneAddress() {
        var limit = STUNReplyLimit()
        let now = NIODeadline.now()
        var host = [UInt8](repeating: 0, count: 16)
        host[0] = 0x20
        for index in 0..<STUNReplyLimit.repliesPerAddress {
            host[15] = UInt8(index)
            XCTAssertTrue(limit.allows(host, at: now))
        }
        host[15] = 0xff
        XCTAssertFalse(limit.allows(host, at: now))
        host[7] = 1
        XCTAssertTrue(limit.allows(host, at: now), "another /64")
    }

    func testAddressesAnsweredAtOnceAreBounded() {
        var limit = STUNReplyLimit()
        let now = NIODeadline.now()
        for index in 0..<STUNReplyLimit.addresses {
            XCTAssertTrue(limit.allows([10, 0, UInt8(index >> 8), UInt8(index & 0xff)], at: now))
        }
        XCTAssertFalse(limit.allows([11, 0, 0, 0], at: now))
        XCTAssertTrue(limit.allows([10, 0, 0, 0], at: now), "an address already counted still is")
        XCTAssertTrue(limit.allows([11, 0, 0, 0], at: now + .seconds(1)))
    }
}
