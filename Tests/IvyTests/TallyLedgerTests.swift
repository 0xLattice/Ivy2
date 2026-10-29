import XCTest
@testable import Ivy
import Tally

final class TallyLedgerTests: XCTestCase {
    // contended sends spend the Tally's prepaid balance, which serving priority includes
    func testContendedSentSpendsBalance() {
        let tally = Tally()
        let ledger = TallyLedger(tally: tally)
        let peer = PeerID(publicKey: "payer")
        tally.creditServingBalance(peer: peer, bytes: 1_000)
        XCTAssertEqual(ledger.servingPriority(for: peer), 1_000)
        ledger.recordContendedSent(peer: peer, bytes: 400)
        XCTAssertEqual(tally.servingBalance(for: peer), 600)
        ledger.recordSent(peer: peer, bytes: 400)
        XCTAssertEqual(tally.servingBalance(for: peer), 600)
    }
}
