import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import Foundation

/// MEM-A1 : fail-closed state resolution at admission.
///
/// The mempool admission validator (`TransactionValidator.validate`, the unit
/// `admitToMempool` funnels every submit/gossip through) resolves the frontier
/// state header and the account / deposit sub-tries while checking the nonce,
/// the withdrawal-corresponding-deposit pre-filter, and balances. If ANY of
/// those resolutions fails — a missing CID, an unreachable peer, a corrupt
/// volume — admission MUST fail CLOSED (reject), never fail OPEN (treat the
/// unresolved account as nonce 0 / balance 0 and admit). A `try?->(nil,nil)`
/// fail-open here would let an attacker bypass nonce/balance checks by simply
/// withholding the state nodes the validator needs.
///
/// Harness: an injectable resolution-FAILING Fetcher behind a ChainState that
/// carries a perfectly valid `tipSnapshot`. The snapshot makes the validator
/// BELIEVE state is available and attempt resolution; the fetcher then refuses
/// to serve the nodes, exercising every fail-closed guard. This is the shared
/// harness MEM-A2/A3 reuse.
final class MempoolStateResolutionFailClosedTests: XCTestCase {

    /// A Fetcher that throws on every fetch — simulates a state node that the
    /// content-addressed store cannot resolve (missing/corrupt/unreachable).
    struct FailingFetcher: Fetcher {
        struct ResolutionUnavailable: Error {}
        func fetch(rawCid: String) async throws -> Data {
            throw ResolutionUnavailable()
        }
    }

    /// A Fetcher that serves a fixed allowlist of CID→Data and throws on
    /// everything else. Lets a test admit the frontier-state HEADER while still
    /// failing the deeper account/deposit SUB-TRIE resolution — isolating the
    /// account-trie fail-closed path from the frontier-header path.
    actor PartialFetcher: Fetcher {
        struct ResolutionUnavailable: Error {}
        private let allowed: [String: Data]
        init(allowed: [String: Data]) { self.allowed = allowed }
        func fetch(rawCid: String) async throws -> Data {
            guard let data = allowed[rawCid] else { throw ResolutionUnavailable() }
            return data
        }
    }

    /// Sign a body with a Wallet, producing a Transaction (mirrors the global
    /// `sign(_:_:)` helper which takes a raw key-pair tuple).
    private func signWith(_ body: TransactionBody, _ w: Wallet) -> Transaction {
        // known-valid local node; CID cannot fail
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = w.sign(body: body, bodyCID: h.rawCID)!
        return Transaction(signatures: [w.publicKeyHex: sig], body: h)
    }

    // Premined sender so the genesis post-state has a populated account trie
    // (a non-trivial trie the deeper resolution actually has to walk).
    private func premineGenesis() async throws -> (genesis: Block, sender: Wallet) {
        let f = cas()
        let sender = Wallet.create()
        let spec = testSpec("Nexus", premine: 1_000_000)
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: sender.address, delta: Int64(spec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [sender.address], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [signWith(premineBody, sender)],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        return (genesis, sender)
    }

    private func chainStateWithValidTip(_ genesis: Block) -> ChainState {
        // fromGenesis installs a tipSnapshot whose postStateCID is the genesis
        // post-state — the validator will believe state is available and try to
        // resolve it through the injected (failing) fetcher.
        ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
    }

    // MARK: - Frontier-header resolution failure

    /// validateNonce resolves the frontier state HEADER first. With a fetcher
    /// that throws and NO frontier cache, that resolve fails. Fail-closed =>
    /// `.stateResolutionFailed`, NOT `.success` (which would be the fail-open
    /// bug: nonce treated as 0 and the tx admitted).
    func testNonceFailsClosedOnFrontierHeaderResolutionFailure() async throws {
        let (genesis, sender) = try await premineGenesis()
        let chain = chainStateWithValidTip(genesis)
        // A normal debit transfer — passes every cheap gate and the signature
        // check, so the FIRST thing that can fail is the nonce-state resolution.
        let tx = sender.buildTransfer(to: Wallet.create().address, amount: 100, fee: 10, nonce: 1, chainPath: ["Nexus"])!

        let validator = TransactionValidator(
            fetcher: FailingFetcher(),
            chainState: chain,
            frontierCache: nil,            // force a real resolve through the fetcher
            expectedChainPath: ["Nexus"]
        )
        let result = await validator.validate(tx).result
        switch result {
        case .failure(.stateResolutionFailed):
            break // fail-closed: correct
        case .success:
            XCTFail("FAIL-OPEN: admission succeeded despite unresolvable frontier state")
        default:
            XCTFail("expected .stateResolutionFailed, got \(result)")
        }
    }

    /// A debit-bearing tx whose owner balance cannot be confirmed (the frontier
    /// state the balance check walks is unresolvable) MUST reject. The dangerous
    /// fail-open is treating an unresolved account as balance 0 / sufficient and
    /// admitting an overspend. With NO cache and a throwing fetcher, the balance
    /// gate cannot confirm funds, so admission must fail closed. The debit here
    /// EXCEEDS the premine, so a fail-open that resolved an empty balance (0)
    /// would still reject — only a fail-open that ADMITTED would surface; the
    /// assertion forbids `.success` for an unconfirmable overspend.
    func testBalancesFailClosedWhenFrontierUnresolvable() async throws {
        let (genesis, sender) = try await premineGenesis()
        let chain = chainStateWithValidTip(genesis)

        // Debit far above any plausible balance; nonce is in-window. Every cheap
        // gate + signature pass, so the validator reaches the state-dependent
        // nonce/balance checks, both of which resolve the unreachable frontier.
        let tx = sender.buildTransfer(to: Wallet.create().address, amount: 999_999_999, fee: 10, nonce: 1, chainPath: ["Nexus"])!

        let validator = TransactionValidator(
            fetcher: FailingFetcher(),
            chainState: chain,
            frontierCache: nil,            // force a real resolve through the fetcher
            expectedChainPath: ["Nexus"]
        )
        let result = await validator.validate(tx).result
        switch result {
        case .success:
            XCTFail("FAIL-OPEN: balance-bearing tx admitted despite unconfirmable frontier state")
        case .failure:
            break // any rejection is fail-closed; .stateResolutionFailed in practice
        }
    }

    // MARK: - End-to-end through the real admission entry point

    /// Drive the NAMED production entry point `submitTransactionWithReason`
    /// (which funnels through `admitToMempool`) on a REAL node whose chain tip
    /// snapshot has been re-pointed to a `postStateCID` that no broker holds and
    /// no peer can serve. The validator gets a non-nil snapshot (so it attempts
    /// resolution, not the `.noStateAvailable` short-circuit) and resolves the
    /// missing frontier state through the node's live `IvyFetcher`, which fails.
    ///
    /// Fail-closed contract at the production funnel:
    ///   1. the submit is REJECTED (`.failure`), never admitted on a `(nil,nil)`
    ///      fail-open that would treat the sender as nonce 0 / balance 0; and
    ///   2. NO gossip is emitted — `submitTransactionWithReason` only stores and
    ///      gossips on `.added/.replacedExisting`, so a reject must leave the
    ///      mempool empty (the gossip branch is never reached).
    ///
    /// The `validate()`-level cases above isolate the individual
    /// nonce/balance/withdrawal-deposit sub-paths (a per-sub-trie failing fetcher
    /// cannot be injected at the named entry without a production seam); this
    /// case proves the SAME fail-closed guards fire when reached through the real
    /// node + live fetcher + gossip-suppression path.
    func testSubmitFailsClosedAndDoesNotGossipWhenFrontierUnresolvable() async throws {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let genesis = testGenesis()
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: port, storagePath: tmpDir,
                enableLocalDiscovery: false, persistInterval: 1, minPeerKeyBits: 0
            ),
            genesisConfig: genesis
        )
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(2, on: node)

        // Build a fresh transfer that passes every cheap gate + signature so the
        // FIRST thing that can fail is the state-dependent nonce/balance resolve.
        let nonce = (try? await node.getNonce(address: minerAddr)) ?? 0
        let tx = Wallet(privateKeyHex: kp.privateKey, publicKeyHex: kp.publicKey)
            .buildTransfer(to: Wallet.create().address, amount: 1, fee: 1, nonce: nonce + 1, chainPath: ["Nexus"])!

        // Re-point the live chain tip's postStateCID to an unresolvable CID:
        // clone the real tip block but swap its postState header for one whose
        // rawCID no broker holds and (with discovery off, zero peers) no peer can
        // serve, so IvyFetcher resolution throws .notFound -> fail-closed.
        let maybeChain = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(maybeChain)
        let tipHash = await chain.getMainChainTip()
        let maybeTip = try await node.getBlock(hash: tipHash, directory: "Nexus")
        let tip = try XCTUnwrap(maybeTip)
        let bogusPostState = LatticeStateHeader(
            rawCID: "bafyunresolvablepoststate000000000000000000000",
            node: nil,
            encryptionInfo: nil
        )
        let tamperedTip = Block(
            version: tip.version,
            parent: tip.parent,
            transactions: tip.transactions,
            target: tip.target,
            nextTarget: tip.nextTarget,
            spec: tip.spec,
            parentState: tip.parentState,
            prevState: tip.prevState,
            postState: bogusPostState,
            children: tip.children,
            height: tip.height,
            timestamp: tip.timestamp,
            nonce: tip.nonce
        )
        await chain.updateTipSnapshot(block: tamperedTip)
        // No cache invalidation needed: the warm PostStateCache is keyed by the
        // REAL postStateCIDs from mining; the bogus CID is a guaranteed cache
        // miss, so the validator must hit the (failing) live fetcher.

        let result = await node.submitTransactionWithReason(directory: "Nexus", transaction: tx)
        switch result {
        case .failure(let reason):
            // Fail-closed at the production funnel. The rejection MUST be the
            // state-resolution guard, not an incidental "chain unavailable" /
            // capacity reject — otherwise the test would be vacuous.
            XCTAssertTrue(
                reason.contains("resolve chain state"),
                "expected a state-resolution fail-closed reject, got: \(reason)"
            )
        case .success:
            XCTFail("FAIL-OPEN: submit admitted despite an unresolvable frontier state")
        }

        // No gossip: the mempool stays empty (submit only stores+gossips on
        // admit). A non-empty mempool would mean the tx was admitted and thus
        // gossiped — the fail-open we forbid.
        let resident = await node.network(for: "Nexus")?.nodeMempool.count ?? -1
        XCTAssertEqual(resident, 0, "rejected tx must not be admitted (and therefore must not be gossiped)")

        await node.stop()
    }

    /// validateWithdrawalDeposits resolves the deposit sub-trie to confirm a
    /// withdrawal's corresponding deposit exists. With the deposit trie
    /// unresolvable, the withdrawal must be rejected (fail-closed), never
    /// admitted on the assumption the deposit is present.
    func testWithdrawalDepositsFailClosedOnDepositTrieResolutionFailure() async throws {
        let (genesis, sender) = try await premineGenesis()
        let chain = chainStateWithValidTip(genesis)

        let postState = try XCTUnwrap(genesis.postState.node)
        let cache = PostStateCache()
        cache.set(frontierCID: genesis.postState.rawCID, state: postState)

        // A conservation-valid withdrawal: withdrawn funds (inflow) are credited
        // to the withdrawer, paying the fee. debits + withdrawn == credits + fee
        // => 0 + 50 == 40 + 10. validateWithdrawals' shape gate passes
        // (nonzero amounts, withdrawer in signers); the deposit-existence
        // pre-filter then resolves the deposit trie through the failing fetcher.
        let withdrawn: UInt64 = 50
        let fee: UInt64 = 10
        let body = TransactionBody(
            accountActions: [AccountAction(owner: sender.address, delta: Int64(withdrawn - fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: sender.address,
                nonce: 0,
                demander: sender.address,
                amountDemanded: withdrawn,
                amountWithdrawn: withdrawn
            )],
            signers: [sender.address], fee: fee, nonce: 1, chainPath: ["Nexus"]
        )
        let tx = signWith(body, sender)

        let validator = TransactionValidator(
            fetcher: PartialFetcher(allowed: [:]),
            chainState: chain,
            frontierCache: cache,
            expectedChainPath: ["Nexus"]
        )
        let result = await validator.validate(tx).result
        switch result {
        case .failure(.stateResolutionFailed):
            break // fail-closed on deposit-trie resolution: correct
        case .failure(.withdrawalWithoutDeposit):
            // Also acceptable fail-closed outcome IF the resolve surfaced an
            // empty trie rather than throwing; still a rejection, never admit.
            break
        case .success:
            XCTFail("FAIL-OPEN: withdrawal admitted despite unresolvable deposit trie")
        default:
            XCTFail("expected a fail-closed rejection, got \(result)")
        }
    }
}
