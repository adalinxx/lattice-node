import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import Foundation

/// M11-class admission gates: the mempool must reject account actions that
/// block validation rejects deterministically, so it never holds an
/// admit-but-unbuildable tx (template-build churn).
///   • zero-delta account action — consensus `AccountAction.verify()` requires
///     `delta != 0`;
///   • reserved `_nonce_`-prefixed owner — `proveAndUpdateState` throws
///     `conflictingActions`.
/// Both reproduce on pre-fix code (admitted, then evicted at trial-build);
/// the gate rejects them at admission with a deterministic consensus class.
final class AccountActionAdmissionGateTests: XCTestCase {

    private func signWith(_ body: TransactionBody, _ w: Wallet) -> Transaction {
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = w.sign(body: body, bodyCID: h.rawCID)!
        return Transaction(signatures: [w.publicKeyHex: sig], body: h)
    }

    private func makeValidator() async throws -> TransactionValidator {
        let f = cas()
        let spec = testSpec("Nexus", premine: 1_000)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [],
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
        return TransactionValidator(fetcher: f, chainState: chain, frontierCache: cache, expectedChainPath: ["Nexus"])
    }

    /// A zero-delta account action passes balance/conservation (it moves nothing)
    /// but consensus `verify()` rejects it. Must fail at admission with a
    /// consensus-invalid class, not be admitted.
    func testZeroDeltaAccountActionRejected() async throws {
        let validator = try await makeValidator()
        let w = Wallet.create()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: w.address, delta: 0)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = signWith(body, w)
        let result = await validator.validate(tx).result
        switch result {
        case .failure(let err) where err.consensusClass == .consensusInvalid:
            if case .invalidAccountAction = err { break }
            XCTFail("expected .invalidAccountAction, got \(err)")
        default:
            XCTFail("zero-delta account action must be rejected consensus-invalid, got \(result)")
        }
    }

    /// An account action whose owner is the reserved `_nonce_` keyspace burns a
    /// consensus rule (`conflictingActions`); the mempool must not admit it.
    func testReservedNonceOwnerAccountActionRejected() async throws {
        let validator = try await makeValidator()
        let w = Wallet.create()
        let reservedOwner = AccountStateHeader.nonceTrackingKey(w.address)
        let body = TransactionBody(
            // Credit a reserved-keyspace owner: passes conservation (signer debits,
            // reserved owner credits) but consensus rejects the reserved write.
            accountActions: [
                AccountAction(owner: w.address, delta: -5),
                AccountAction(owner: reservedOwner, delta: 5),
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = signWith(body, w)
        let result = await validator.validate(tx).result
        switch result {
        case .failure(let err) where err.consensusClass == .consensusInvalid:
            if case .reservedAccountOwner = err { break }
            XCTFail("expected .reservedAccountOwner, got \(err)")
        default:
            XCTFail("reserved-owner account action must be rejected consensus-invalid, got \(result)")
        }
    }

    /// Control: an ordinary non-zero, non-reserved transfer is NOT rejected by
    /// this gate (it proceeds to balance/signature checks).
    func testOrdinaryTransferPassesTheGate() async throws {
        let validator = try await makeValidator()
        let w = Wallet.create()
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: w.address, delta: -10),
                AccountAction(owner: Wallet.create().address, delta: 10),
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = signWith(body, w)
        let result = await validator.validate(tx).result
        // It must NOT fail with either new gate error (it may fail later on
        // balance — the signer has only premine 0 here — but never these).
        if case .failure(.invalidAccountAction) = result {
            XCTFail("ordinary transfer wrongly rejected as invalid account action")
        }
        if case .failure(.reservedAccountOwner) = result {
            XCTFail("ordinary transfer wrongly rejected as reserved owner")
        }
    }
}
