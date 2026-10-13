import Foundation
import NIOCore

/// Answers STUN Binding requests (RFC 8489) with the address each came from.
/// A browser asks the node it is connected to, and so learns the address its
/// own peers can reach it at without asking anyone else.
final class STUNResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    // Touched only on the channel's event loop.
    private var limit = STUNReplyLimit()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let (address, port) = Self.address(of: envelope.remoteAddress),
              let reply = Self.reply(to: envelope.data.readableBytesView, address: address, port: port),
              limit.allows(address, at: .now()) else { return }
        var buffer = context.channel.allocator.buffer(capacity: reply.count)
        buffer.writeBytes(reply)
        context.writeAndFlush(
            wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)),
            promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // One datagram that could not be read or sent is no reason to stop.
    }

    /// The bytes of an address, 4 or 16 of them, and its port. An IPv4
    /// address a dual-stack socket reports as IPv6 is given as IPv4.
    static func address(of remote: SocketAddress) -> (address: [UInt8], port: UInt16)? {
        guard let port = remote.port.flatMap(UInt16.init(exactly:)) else { return nil }
        switch remote {
        case .v4(let v4):
            return (withUnsafeBytes(of: v4.address.sin_addr) { Array($0) }, port)
        case .v6(let v6):
            let bytes = withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            return (mapped ? Array(bytes[12...]) : bytes, port)
        case .unixDomainSocket:
            return nil
        }
    }

    /// The success response to `request`, or nil when it is not a Binding
    /// request. Only a request is answered, so two responders cannot be set
    /// answering each other. Its attributes are not read: none changes what
    /// a Binding request without credentials is answered with.
    static func reply<Request: Collection>(
        to request: Request, address: [UInt8], port: UInt16
    ) -> [UInt8]? where Request.Element == UInt8 {
        let request = Array(request.prefix(maxRequest + 1))
        guard request.count >= 20, request.count <= maxRequest,
              request[0] == 0x00, request[1] == 0x01,
              Array(request[4..<8]) == magicCookie else { return nil }
        let length = Int(request[2]) << 8 | Int(request[3])
        guard length.isMultiple(of: 4), request.count == 20 + length,
              address.count == 4 || address.count == 16 else { return nil }
        let mask = Array(request[4..<20])

        // Success response, then one attribute: XOR-MAPPED-ADDRESS.
        var reply: [UInt8] = [0x01, 0x01, 0x00, UInt8(8 + address.count)]
        reply += mask
        reply += [0x00, 0x20, 0x00, UInt8(4 + address.count)]
        reply += [0x00, address.count == 4 ? 0x01 : 0x02]
        reply += [UInt8(port >> 8) ^ mask[0], UInt8(port & 0xff) ^ mask[1]]
        reply += zip(address, mask).map { $0 ^ $1 }
        return reply
    }

    static let magicCookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
    /// A request that gathers an address is its 20-byte header and little else.
    static let maxRequest = 512
}

/// A request's source address is not verified, so whatever is answered can
/// be aimed at someone who never asked. This bounds what one node sends to
/// one address, and how many addresses it sends to.
struct STUNReplyLimit {
    static let repliesPerAddress = 20
    static let addresses = 4096
    static let window = TimeAmount.seconds(1)

    private var windowStart: NIODeadline?
    private var replies: [[UInt8]: Int] = [:]

    /// Whether one more reply may go to `address` now. An IPv6 address is
    /// counted with the rest of its /64, which one host has all of.
    mutating func allows(_ address: [UInt8], at now: NIODeadline) -> Bool {
        if windowStart.map({ now - $0 >= Self.window }) ?? true {
            windowStart = now
            replies.removeAll(keepingCapacity: true)
        }
        let key = address.count == 16 ? Array(address.prefix(8)) : address
        let sent = replies[key, default: 0]
        guard sent < Self.repliesPerAddress, sent > 0 || replies.count < Self.addresses else { return false }
        replies[key] = sent + 1
        return true
    }
}
