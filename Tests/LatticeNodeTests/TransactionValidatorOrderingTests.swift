import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import Foundation

/// cheap-before-signature validation ordering. All pure
/// in-memory gates (size, fees, chain-path, deposit/receipt/withdrawal shape,
/// unique owners, conservation) must run BEFORE the expensive signature
/// verification (up to 16 Ed25519 verifies) and before any state/trie I/O.
///
/// Observable discriminator: a tx with INVALID signatures that ALSO fails a
/// cheap gate must return the CHEAP error, not `.invalidSignatures`. On the
/// pre-fix order (signatures first) the same tx returns `.invalidSignatures`;
/// only the reordered code returns the cheap error.
final class TransactionValidatorOrderingTests: XCTestCase {

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
        // Validator expects chainPath == ["Nexus"]; a tx whose chainPath differs
        // fails the cheap validateChainPath gate.
        return TransactionValidator(fetcher: f, chainState: chain, frontierCache: cache, expectedChainPath: ["Nexus"])
    }

    /// Junk signature AND a cheap-gate failure (chain-path mismatch). The
    /// reordered validator returns `.chainPathMismatch` — proving the cheap gate
    /// ran first and short-circuited before any Ed25519 verify or trie hop.
    func testCheapChecksRejectBeforeSignatureVerify() async throws {
        let validator = try await makeValidator()
        let w = Wallet.create()

        // chainPath [] != expected ["Nexus"]; fee is valid; signature is junk.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: w.address, delta: -101),
                AccountAction(owner: Wallet.create().address, delta: 100)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 1, nonce: 0, chainPath: []
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        // Junk (well-formed-hex but invalid) signature value — same trick as
        // FixedVulnerabilityTests / EndToEndTests.
        let junkTx = Transaction(signatures: [w.publicKeyHex: "deadbeef"], body: header)

        let result = await validator.validate(junkTx).result
        switch result {
        case .failure(.chainPathMismatch):
            break   // cheap gate won the race — correct post-reorder behavior
        case .failure(.invalidSignatures):
            XCTFail("signatures ran before the cheap chain-path gate (pre-fix order)")
        default:
            XCTFail("expected .chainPathMismatch, got \(result)")
        }
    }

    /// Second cheap discriminator: a below-minimum fee with junk signatures
    /// returns `.feeTooLow`, again proving fee validation precedes signatures.
    func testFeeTooLowReturnsBeforeSignatureVerify() async throws {
        let validator = try await makeValidator()
        let w = Wallet.create()

        // fee=0 < MINIMUM_TRANSACTION_FEE; chainPath correct so the fee gate is
        // the discriminating cheap check; signature junk.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: w.address, delta: -100),
                AccountAction(owner: Wallet.create().address, delta: 100)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [w.address], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        let junkTx = Transaction(signatures: [w.publicKeyHex: "deadbeef"], body: header)

        let result = await validator.validate(junkTx).result
        switch result {
        case .failure(.feeTooLow):
            break
        case .failure(.invalidSignatures):
            XCTFail("signatures ran before the cheap fee gate (pre-fix order)")
        default:
            XCTFail("expected .feeTooLow, got \(result)")
        }
    }
}
