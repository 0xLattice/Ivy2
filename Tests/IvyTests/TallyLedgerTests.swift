import XCTest
@testable import Ivy
import Tally

final class TallyLedgerTests: XCTestCase {
    // served bytes debit the Tally's standing, which is the serving priority
    func testServedDebitsStanding() {
        let tally = Tally()
        let ledger = TallyLedger(tally: tally)
        let peer = PeerID(publicKey: "payer")
        tally.creditStanding(peer: peer, bytes: 1_000)
        XCTAssertEqual(ledger.servingPriority(for: peer), 1_000)
        ledger.recordServed(peer: peer, bytes: 400)
        XCTAssertEqual(tally.standing(for: peer), 600)
        ledger.recordSent(peer: peer, bytes: 400)
        XCTAssertEqual(tally.standing(for: peer), 600)
    }
}
