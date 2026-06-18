import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import Foundation

/// node-local min-fee-RATE floor (units per serialized-body byte).
///
/// This is mempool admission / relay POLICY only — NOT a consensus rule.
/// A tx whose `fee < minFeeRate * body.bytes` is rejected from THIS node's
/// mempool and not relayed, but Block+Validate / per-tx consensus validation
/// is untouched: a below-floor tx in a received block is still consensus-valid
/// (another miner may run a lower floor).
final class MinFeeRateTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func tx(_ wallet: Wallet, fee: UInt64, nonce: UInt64 = 0) -> Transaction {
        wallet.buildTransfer(to: wallet.address, amount: 1, fee: fee, nonce: nonce)!
    }

    /// Serialized body length — the SAME primitive validateSize() measures.
    private func bodyBytes(_ transaction: Transaction) -> UInt64 {
        UInt64(transaction.body.node!.toData()!.count)
    }

    // RED before the floor existed: a sub-floor fee was admitted regardless.
    // GREEN after: fee < minFeeRate * bytes is rejected; fee >= it is admitted.
    func testMempoolRejectsBelowMinFeeRate() async {
        let rate: UInt64 = 1
        let mempool = NodeMempool(maxSize: 1000, minFeeRate: rate)
        let w = wallet()

        // fee = 1 is far below rate * bytes (body is > 1 byte).
        let below = tx(w, fee: 1)
        let bytes = bodyBytes(below)
        XCTAssertLessThan(1, rate * bytes, "test premise: fee 1 must be below the rate floor")

        let rejected = await mempool.addTransaction(below)
        switch rejected {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("rate floor"), "expected rate-floor rejection, got: \(reason)")
        default:
            XCTFail("sub-rate-floor tx must be rejected: \(rejected)")
        }
        let present = await mempool.contains(txCID: below.body.rawCID)
        XCTAssertFalse(present, "rejected tx must not be present in mempool")

        // A fee comfortably at/above rate * bytes is admitted. (Bumping the fee
        // changes the varint-encoded body length, so we assert against the
        // SUBMITTED tx's own byte count rather than the probe tx's.)
        let aboveTx = tx(w, fee: 100_000)
        XCTAssertGreaterThanOrEqual(100_000, rate * bodyBytes(aboveTx), "test premise: fee must meet the floor")
        let admitted = await mempool.addTransaction(aboveTx)
        switch admitted {
        case .added: break
        default: XCTFail("at/above-rate-floor tx must be admitted: \(admitted)")
        }
    }

    // Proves the floor is RELAY POLICY, not consensus: the SAME below-floor tx
    // passes the per-tx consensus validation path (TransactionValidator.validate,
    // which Block+Validate relies on for tx-level fee checks). The only consensus
    // fee rule is the absolute MINIMUM_TRANSACTION_FEE; there is no per-byte rate
    // floor in consensus, so a fee=1 tx remains consensus-valid.
    func testMinFeeRateIsNodeLocalNotConsensus() async throws {
        let f = cas()
        let sender = CryptoUtils.generateKeyPair()
        let senderAddress = CryptoUtils.createAddress(from: sender.publicKey)
        let receiverAddress = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let spec = testSpec("Nexus", premine: 1_000)
        let premineAmount = spec.premineAmount()
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: senderAddress, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [senderAddress], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [sign(premineBody, sender)],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: storer)
        await storer.flush(to: f)

        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let cache = PostStateCache()
        cache.set(frontierCID: genesis.postState.rawCID, state: try XCTUnwrap(genesis.postState.node))

        // fee = 1: above MINIMUM_TRANSACTION_FEE (consensus) but below a rate floor of 1/byte.
        let fee: UInt64 = MINIMUM_TRANSACTION_FEE
        let transfer: UInt64 = 100
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddress, delta: -Int64(transfer + fee)),
                AccountAction(owner: receiverAddress, delta: Int64(transfer))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [senderAddress], fee: fee, nonce: 1, chainPath: ["Nexus"]
        )
        let belowFloorTx = sign(body, sender)
        let bytes = UInt64(body.toData()!.count)
        XCTAssertLessThan(fee, 1 * bytes, "test premise: fee must be below a 1/byte rate floor")

        // Consensus path: must NOT reject this tx.
        let validator = TransactionValidator(
            fetcher: f,
            chainState: chain,
            frontierCache: cache,
            expectedChainPath: ["Nexus"]
        )
        let result = await validator.validate(belowFloorTx)
        guard case .success = result.result else {
            return XCTFail("below-rate-floor tx must remain consensus-valid (relay policy only), got \(result.result)")
        }

        // Node mempool with the same floor rejects the exact same tx.
        let mempool = NodeMempool(maxSize: 1000, minFeeRate: 1)
        let admission = await mempool.addTransaction(belowFloorTx)
        switch admission {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("rate floor"), "expected rate-floor rejection, got: \(reason)")
        default:
            XCTFail("node mempool must reject the consensus-valid sub-floor tx: \(admission)")
        }
    }

    // Programmatic config preserves existing no-floor behavior; operators can
    // still configure a Bitcoin-style local relay floor.
    func testMinFeeRateIsConfigurablePolicy() async {
        let w = wallet()

        // Programmatic nodes/tests keep the legacy default of no local rate
        // floor; NodeCommand wires the daemon CLI default separately.
        XCTAssertEqual(
            LatticeNodeConfig(publicKey: "k", privateKey: "k", storagePath: URL(fileURLWithPath: "/tmp"), minPeerKeyBits: 0).minFeeRate,
            0
        )

        // Choose a fee in [bytes, 2*bytes): admitted by a configured 1/byte
        // floor, rejected by a raised 2/byte floor. body bytes ~340, so 400
        // fits the window. Assert the actual submitted tx satisfies it.
        let okTx = tx(w, fee: 400)
        let bytes = bodyBytes(okTx)
        XCTAssertGreaterThanOrEqual(400, 1 * bytes, "test premise: fee >= 1/byte floor")
        XCTAssertLessThan(400, 2 * bytes, "test premise: fee < 2/byte floor")

        let noFloorMempool = NodeMempool(maxSize: 1000)
        switch await noFloorMempool.addTransaction(tx(w, fee: 1, nonce: 1)) {
        case .added: break
        default: XCTFail("default programmatic mempool should admit consensus-valid low-fee txs")
        }

        let configuredMempool = NodeMempool(maxSize: 1000, minFeeRate: 1)
        switch await configuredMempool.addTransaction(okTx) {
        case .added: break
        default: XCTFail("configured 1/byte floor should admit fee 400 for a ~340-byte body")
        }

        let raisedMempool = NodeMempool(maxSize: 1000, minFeeRate: 2)
        switch await raisedMempool.addTransaction(okTx) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("rate floor"), "expected rate-floor rejection, got: \(reason)")
        default:
            XCTFail("raised 2/byte floor must reject a fee the 1/byte floor admits")
        }
    }
}
