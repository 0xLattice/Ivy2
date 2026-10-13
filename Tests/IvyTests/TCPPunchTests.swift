import Foundation
import XCTest
@testable import Ivy

private final class Bytes: TransportConnectionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var closed = false

    var data: Data { lock.withLock { received } }
    var isClosed: Bool { lock.withLock { closed } }

    func transportDidReceive(_ bytes: Data) { lock.withLock { received.append(bytes) } }
    func transportWritabilityChanged(isWritable: Bool) {}
    func transportDidClose() { lock.withLock { closed = true } }
}

/// The transport alone, on loopback: two sockets that connect to each other.
final class TCPPunchTests: XCTestCase {
    /// Whether what one end sends is what the other receives, both ways.
    private func carries(_ left: any TransportConnection, _ right: any TransportConnection) async -> Bool {
        let (leftSink, rightSink) = (Bytes(), Bytes())
        left.attach(leftSink)
        right.attach(rightSink)
        left.send(Data("from the left".utf8))
        right.send(Data("from the right".utf8))
        left.requestBytes()
        right.requestBytes()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if leftSink.data == Data("from the right".utf8), rightSink.data == Data("from the left".utf8) {
                return true
            }
            if leftSink.isClosed || rightSink.isClosed { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    /// Each round both ends start at once, or one a little after the other.
    func testBothEndsHoldTheSameConnectionHoweverTheyStart() async throws {
        let transport = TCPPunch()
        var failures: [String] = []
        for round in 0..<(Int(ProcessInfo.processInfo.environment["IVY_PUNCH_ROUNDS"] ?? "") ?? 300) {
            guard let left = await transport.prepare(), let right = await transport.prepare() else {
                return XCTFail("round \(round): no socket")
            }
            let toLeft = [PunchCandidate(transport: PunchCandidate.tcp, host: "127.0.0.1", port: left.port)]
            let toRight = [PunchCandidate(transport: PunchCandidate.tcp, host: "127.0.0.1", port: right.port)]
            let deadline = ContinuousClock.now + .seconds(5)
            // The stagger covers one end's first packet arriving before, as,
            // and after the other end starts.
            let stagger = UInt64(round % 6) * 150_000
            async let first = left.connect(to: toRight, initiator: true, deadline: deadline)
            async let second: (any TransportConnection)? = {
                try? await Task.sleep(nanoseconds: stagger)
                return await right.connect(to: toLeft, initiator: false, deadline: deadline)
            }()
            let (a, b) = await (first, second)
            if let a, let b {
                if await !carries(a, b) { failures.append("round \(round): the ends hold different connections") }
            } else {
                failures.append("round \(round): \(a == nil ? "left" : "right") made no connection")
            }
            a?.close()
            b?.close()
            left.close()
            right.close()
        }
        XCTAssertEqual(failures, [])
    }
}
