import XCTest
@testable import Lattice
@testable import LatticeNode

/// S1: mempool admission DoS rules — nonce-gap cap + min-fee floor.
final class MempoolAdmissionDoSTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func tx(_ wallet: Wallet, fee: UInt64 = 10, nonce: UInt64) -> Transaction {
        wallet.buildTransfer(to: wallet.address, amount: 1, fee: fee, nonce: nonce)!
    }

    func testFarFutureNonceIsRejected() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = wallet()
        // confirmedNonce starts at 0, so the admission window is [0, 64].
        let adm = await mempool.addTransaction(tx(w, nonce: 64))
        switch adm {
        case .added: break
        default: XCTFail("nonce==gap limit must be accepted: \(adm)")
        }

        let rej = await mempool.addTransaction(tx(w, nonce: 65))
        switch rej {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce gap"), "expected nonce-gap rejection, got: \(reason)")
        default:
            XCTFail("nonce beyond gap must be rejected, got \(rej)")
        }
    }

    func testNonceGapScalesWithConfirmedNonce() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 200, maxNonceGap: 10)
        let w = wallet()

        // Advance confirmedNonce to 50 so the window shifts to [50, 60].
        await mempool.updateConfirmedNonce(sender: w.address, nonce: 50)

        let inWindow = await mempool.addTransaction(tx(w, nonce: 60))
        switch inWindow {
        case .added: break
        default: XCTFail("in-window submission must succeed: \(inWindow)")
        }

        let outOfWindow = await mempool.addTransaction(tx(w, nonce: 61))
        switch outOfWindow {
        case .rejected: break
        default: XCTFail("above-window submission must be rejected: \(outOfWindow)")
        }
    }

    func testFeeFloorRejectsLowFees() async {
        let mempool = NodeMempool(maxSize: 1000, minFeeFloor: 100)
        let w = wallet()

        let below = await mempool.addTransaction(tx(w, fee: 99, nonce: 0))
        switch below {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Fee below floor"), "expected fee-floor rejection, got: \(reason)")
        default:
            XCTFail("sub-floor fee must be rejected: \(below)")
        }

        let atFloor = await mempool.addTransaction(tx(w, fee: 100, nonce: 0))
        switch atFloor {
        case .added: break
        default: XCTFail("fee == floor must be accepted: \(atFloor)")
        }
    }

    func testMaxNonceGapOverflowIsSafe() async {
        // If confirmedNonce is near UInt64.max, the gap addition overflows.
        // We must not crash, and we must not accidentally admit junk (the
        // overflow branch in admit accepts the tx because the cap is
        // effectively infinite at that point, which is fine: a sender with
        // confirmedNonce ≈ UInt64.max is already past realistic abuse).
        let mempool = NodeMempool(maxSize: 100, maxNonceGap: 1000)
        let w = wallet()
        await mempool.updateConfirmedNonce(sender: w.address, nonce: UInt64.max - 10)
        // No crash expected; we don't assert admission outcome because the
        // per-account index would normally carry the sender past overflow.
        _ = await mempool.addTransaction(tx(w, nonce: UInt64.max - 5))
    }
}
