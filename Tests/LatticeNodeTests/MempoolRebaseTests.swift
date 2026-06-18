import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import Tally
import cashew
import VolumeBroker
import UInt256
import Foundation

/// Module 7: Mempool Rebase, Not Weakening.
///
/// The mempool deliberately MIRRORS consensus for DoS/correctness — it is NOT
/// weakened. These are CHARACTERIZATION / REGRESSION tests that pin the criteria
/// the plan calls for, all of which already hold in production:
///
///   a. The block builder trial-evicts a mempool tx that no longer builds
///      against canonical state, and still produces a valid/accepted block
///      (`TemplateAssembly.buildWithFallback` — Mining/TemplateAssembly.swift).
///   b. A reorg that orphans a tx-bearing block re-admits the orphaned tx
///      through the transition-driven `recoverOrphanedTransactions`
///      (LatticeNode+BlockReorg.swift) and resets the confirmed-nonce floor.
///   c. Multi-signer admission enforces per-signer nonce floors AND the
///      cumulative per-signer debit bound at the node admission seam.
///   d. After a canonical commit advances state, a now-unaffordable resident
///      tx is not served into a block (revalidation / trial-inclusion).
///
/// ───────────────────────────────────────────────────────────────────────────
/// DUPLICATE-PATH ASSESSMENT (Deliverable 1) — the two `resetConfirmedNonces`
/// AfterReorg call sites are COMPLEMENTARY, not a redundant duplicate. NOTHING
/// is consolidated. Evidence:
///
///   • Path A — LatticeNode+BlockReorg.swift:409, inside
///     `recoverOrphanedTransactions`, reached ONLY from
///     `publishCanonicalTransition` (LatticeNode+CanonicalPublish.swift:175)
///     and the sync side-effect publisher (LatticeNode+Sync.swift:1264). It
///     handles MULTI-BLOCK transitions: the orphan set is the transition's
///     orphaned blocks, and it resets the floor for EVERY signer of every
///     orphaned tx (BlockReorg.swift:397 iterates `body.signers`).
///
///   • Path B — LatticeNode+BlockSideEffects.swift:334, inside
///     `recoverTransactionsFromReplacedCanonicalBlock`, reached ONLY from the
///     ORDINARY per-block apply path
///     (`applyPreparedAcceptedBlockEffects(recoverReplacedCanonicalBlock:true)`
///     at BlockSideEffects.swift:249). It handles a SINGLE replaced
///     same-height block — a short fork that overwrote `block_index[height]`
///     WITHOUT routing through the multi-block transition publisher.
///
///   The two cover disjoint triggers (multi-block transition vs. single-block
///   replace), derive their orphan sets from different sources, and even differ
///   in multi-signer scope (Path A resets all signers; Path B keys on
///   `signers.first`, BlockSideEffects.swift:321 — a NARROWER scope kept as-is
///   to avoid a behavior change in this characterization pass; see finding 2 in
///   the report). The codebase already proves the paths are meant to be
///   mutually exclusive on the SYNC path: LatticeNode+Sync.swift:1274 passes
///   `recoverReplacedCanonicalBlock: false` precisely BECAUSE it already ran the
///   transition path at :1264. Both reset functions are idempotent
///   (`getNonce` reads canonical state; `admitToMempool` dedups), so the one
///   overlap inside `publishCanonicalTransition`'s promoted loop — where a
///   promoted block can also be a replaced same-height block — is SAFE, not a
///   bug to fix. Consolidation was therefore NOT performed.
/// ───────────────────────────────────────────────────────────────────────────
final class MempoolRebaseTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "MempoolRebaseTests skipped in CI (real nodes / disk)")
    }

    // MARK: - Fixtures

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeNode(
        spec: ChainSpec? = nil,
        fullChainPath: [String]? = nil
    ) async throws -> LatticeNode {
        let kp = CryptoUtils.generateKeyPair()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey,
            privateKey: kp.privateKey,
            listenPort: nextTestPort(),
            storagePath: tempDir(),
            enableLocalDiscovery: false,
            retentionDepth: 100,
            fullChainPath: fullChainPath,
            minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis(spec: spec))
        addTeardownBlock { [node] in await node.stop() }
        return node
    }

    /// Mine a PoW-valid block that includes `transactions` on top of `previous`
    /// (the empty-block `buildRetargetedTestBlock` helper carries no txs).
    private func buildMinedBlock(
        previous: Block,
        transactions: [Transaction],
        timestamp: Int64,
        fetcher: Fetcher,
        startNonce: UInt64 = 1
    ) async throws -> Block {
        var nonce = startNonce
        while true {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                transactions: transactions,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: fetcher
            )
            if block.validateProofOfWork(nexusHash: block.proofOfWorkHash()) {
                return block
            }
            let (next, overflow) = nonce.addingReportingOverflow(1)
            if overflow { throw BlockBuilderError.stateComputationFailed }
            nonce = next
        }
    }

    private func keyedWallet() -> (kp: (privateKey: String, publicKey: String), address: String) {
        let kp = CryptoUtils.generateKeyPair()
        return (kp: kp, address: addr(kp.publicKey))
    }

    private func multiSignerTx(
        signers: [(kp: (privateKey: String, publicKey: String), address: String)],
        nonce: UInt64,
        fee: UInt64
    ) -> Transaction {
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: signers.map { $0.address }, fee: fee, nonce: nonce
        )
        let h = try! HeaderImpl<TransactionBody>(node: body)
        var signatures: [String: String] = [:]
        for signer in signers {
            signatures[signer.kp.publicKey] = TransactionSigning.sign(
                bodyHeader: h, privateKeyHex: signer.kp.privateKey)!
        }
        return Transaction(signatures: signatures, body: h)
    }

    // MARK: - a. builder trial-evicts a stale mempool tx

    /// KEY REGRESSION. A tx that is RESIDENT and SELECTABLE in the mempool but
    /// does NOT build against canonical state (here: an overspend — it claims to
    /// move more than the sender's confirmed balance) must be trial-evicted by
    /// the block builder, and the produced block must still be valid/accepted.
    /// The mempool intentionally holds it (raw residency mirrors the orphan
    /// re-admission / gossip paths where the bound is resolved later); the
    /// BUILDER is the choke point that keeps it out of the canonical block. The
    /// mempool is NOT weakened to pre-drop it.
    func test_builderRejectsStaleMempoolTx() async throws {
        let node = try await makeNode()
        let networkOpt = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkOpt)
        let chainOpt = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainOpt)

        // Fund the node's own address via mining (coinbase credits nodeAddress).
        try await mineBlocks(2, on: node)
        let nodePrivateKey = await node.config.privateKey
        let w = try XCTUnwrap(Wallet.fromPrivateKey(nodePrivateKey))
        let balance = try await node.getBalance(address: w.address, directory: "Nexus")
        let nonce = try await node.getNonce(address: w.address, directory: "Nexus")
        XCTAssertGreaterThan(balance, 0, "mining must have funded the node address")

        // An overspend: transfer FAR more than the confirmed balance. It cannot
        // build against canonical state, but the mempool holds it (injected raw,
        // exactly like an orphan re-admit before the bound is resolved).
        let overspend = w.buildTransfer(
            to: Wallet.create().address, amount: balance &* 100 &+ 1_000,
            fee: 1, nonce: nonce, chainPath: ["Nexus"])!
        // Seed the floor so the tx is selectable at its nonce, then inject raw.
        await network.nodeMempool.seedConfirmedNonceIfUnset(sender: w.address, nonce: nonce)
        guard case .added = await network.nodeMempool.addTransaction(overspend) else {
            return XCTFail("the mempool must hold the raw-injected tx (residency is not weakened)")
        }
        let selected = await network.nodeMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.map { $0.body.rawCID }, [overspend.body.rawCID],
                       "the unbuildable tx must be selectable (mempool is not weakened to pre-drop it)")

        // Producing a block must trial-build, evict the unbuildable tx, and
        // still produce an ACCEPTED block.
        let heightBefore = await chain.getHighestBlockHeight()
        let produced = await node.produceAndSubmitBlock()
        XCTAssertTrue(produced, "the builder must still produce an accepted block around the stale tx")
        let heightAfter = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfter, heightBefore + 1, "an accepted block must extend the chain")

        // The accepted tip must NOT contain the unbuildable tx.
        let fetcher = await network.ivyFetcher
        let tipCID = await chain.getMainChainTip()
        let tipStub = VolumeImpl<Block>(rawCID: tipCID, node: nil, encryptionInfo: nil)
        let resolvedTip = try? await tipStub.resolve(fetcher: fetcher).node
        let tipBlock = try XCTUnwrap(resolvedTip)
        let txDict = try? await tipBlock.transactions.resolve(
            paths: [[""]: ResolutionStrategy.list], fetcher: fetcher).node
        var includedBodyCIDs = Set<String>()
        if let entries = try? txDict?.allKeysAndValues() {
            for header in entries.values {
                if let body = try? await header.resolve(fetcher: fetcher).node?.body.rawCID {
                    includedBodyCIDs.insert(body)
                }
            }
        }
        XCTAssertFalse(includedBodyCIDs.contains(overspend.body.rawCID),
                       "the builder must trial-evict the unbuildable tx from the canonical block")
    }

    /// The pure builder seam: `TemplateAssembly.buildWithFallback` keeps every
    /// tx that builds and drops the one whose `build` throws, returning a block
    /// that contains only the buildable txs. Deterministic core of the
    /// end-to-end regression above — no PoW, no node.
    func test_builderFallback_dropsUnbuildableKeepsBuildable() async throws {
        let good1 = Wallet.create().buildTransfer(to: Wallet.create().address, amount: 1, fee: 1, nonce: 0)!
        let bad = Wallet.create().buildTransfer(to: Wallet.create().address, amount: 2, fee: 1, nonce: 0)!
        let good2 = Wallet.create().buildTransfer(to: Wallet.create().address, amount: 3, fee: 1, nonce: 0)!
        let badCID = bad.body.rawCID

        var evicted: [String] = []
        // `build` succeeds unless the candidate set contains the poisoned tx.
        let assembled = try await TemplateAssembly.buildWithFallback(
            directory: "Nexus",
            context: "test-template",
            transactions: [good1, bad, good2],
            hasCoinbase: false,
            build: { txs in
                if txs.contains(where: { $0.body.rawCID == badCID }) {
                    throw StateErrors.insufficientBalance
                }
                // A trivial sentinel block; identity is irrelevant to this assertion.
                let f = cas()
                let genesis = try await BlockBuilder.buildGenesis(
                    spec: testSpec(premine: 0), timestamp: now() - 10_000, target: UInt256.max, fetcher: f)
                return genesis
            },
            removeFromMempool: { cid in evicted.append(cid) }
        )

        let keptCIDs = assembled.transactions.map { $0.body.rawCID }
        XCTAssertEqual(keptCIDs, [good1.body.rawCID, good2.body.rawCID],
                       "only buildable txs are retained in the assembled set")
        XCTAssertEqual(evicted, [badCID], "the unbuildable tx is evicted from the mempool")
    }

    // MARK: - b. reorg orphan re-admission via the transition-driven path

    /// A reorg orphans a tx-bearing block; the orphaned tx is re-admitted to
    /// the mempool through `recoverOrphanedTransactions` and the confirmed-nonce
    /// floor is reset to the new-canonical value.
    func test_reorgOrphanAdmission_viaTransition() async throws {
        let node = try await makeNode()
        let networkOpt = await node.network(forPath: ["Nexus"])
        let network = try XCTUnwrap(networkOpt)
        let chainOpt = await node.chain(for: "Nexus")
        let chain = try XCTUnwrap(chainOpt)

        let genesis = await node.genesisResult.block
        let fetcher = await network.ivyFetcher

        // Fund a wallet W on Nexus by mining coinbase to the node's own address,
        // then transferring to W in block A. (Mining credits `nodeAddress`.)
        try await mineBlocks(2, on: node)
        let tipBlockHash = await chain.getMainChainTip()
        let tipStub = VolumeImpl<Block>(rawCID: tipBlockHash, node: nil, encryptionInfo: nil)
        let resolvedTip = try? await tipStub.resolve(fetcher: fetcher).node
        let tipBlock = try XCTUnwrap(resolvedTip)

        // The node's coinbase wallet (config keypair).
        let nodePrivateKey = await node.config.privateKey
        let nodeWallet = try XCTUnwrap(Wallet.fromPrivateKey(nodePrivateKey))
        let w = Wallet.create()

        // Block A: a transfer from the node wallet to W (a real user tx).
        let nodeNonce = try await node.getNonce(address: nodeWallet.address, directory: "Nexus")
        let transfer = nodeWallet.buildTransfer(
            to: w.address, amount: 100, fee: 1, nonce: nodeNonce, chainPath: ["Nexus"])!
        let a = try await buildMinedBlock(
            previous: tipBlock, transactions: [transfer],
            timestamp: tipBlock.timestamp + 1_000, fetcher: fetcher)
        let aCID = try VolumeImpl<Block>(node: a).rawCID
        try await storeBlockFixtureVolumes(a, in: network)
        let aData = try XCTUnwrap(a.toData())
        await node.chainNetwork(network, didReceiveBlock: aCID,
                                data: aData, from: PeerID(publicKey: "peer-a"))
        let tipAfterA = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterA, aCID, "block A with the transfer must be canonical")

        // The transfer is confirmed: the node-wallet floor advanced and the tx
        // is no longer resident.
        let confirmedNonce = try await node.getNonce(address: nodeWallet.address, directory: "Nexus")
        XCTAssertEqual(confirmedNonce, nodeNonce + 1, "the transfer advanced the sender's on-chain nonce")
        let residentBeforeReorg = await network.nodeMempool.contains(txCID: transfer.body.rawCID)
        XCTAssertFalse(residentBeforeReorg, "a confirmed tx is not resident in the mempool")

        // Equal-height sibling B (empty) — the tie holds incumbent A.
        let b = try await buildMinedBlock(
            previous: tipBlock, transactions: [],
            timestamp: tipBlock.timestamp + 2_000, fetcher: fetcher)
        let bCID = try VolumeImpl<Block>(node: b).rawCID
        XCTAssertNotEqual(bCID, aCID)
        try await storeBlockFixtureVolumes(b, in: network)
        let bData = try XCTUnwrap(b.toData())
        await node.chainNetwork(network, didReceiveBlock: bCID,
                                data: bData, from: PeerID(publicKey: "peer-b"))
        let tipAfterB = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB, aCID, "tie holds the incumbent A")

        // Fold inherited weight onto B → fork choice promotes B, orphaning A.
        // This routes through publishCanonicalTransition →
        // recoverOrphanedTransactions (the transition-driven path).
        let securing = workForTarget(UInt256.max) &* UInt256(1000)
        let applied = await node.applyInheritedWorkContributions(
            directory: "Nexus", blockHash: bCID,
            contributions: [(id: "securing-parent", work: securing)],
            source: IvyContentSource(fetcher))
        XCTAssertTrue(applied, "inherited-weight fold + publish must succeed")
        let tipAfterPromotion = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterPromotion, bCID, "inherited weight must promote B, orphaning A")

        // The orphaned transfer must be re-admitted (B did not confirm it).
        let residentAfterReorg = await network.nodeMempool.contains(txCID: transfer.body.rawCID)
        XCTAssertTrue(residentAfterReorg,
                      "the orphaned transfer must be re-admitted via recoverOrphanedTransactions")

        // The confirmed-nonce floor must be reset back to the pre-A value (B did
        // not re-confirm the transfer), so the re-admitted tx is selectable.
        let floorAfterReorg = try await node.getNonce(address: nodeWallet.address, directory: "Nexus")
        XCTAssertEqual(floorAfterReorg, nodeNonce,
                       "the confirmed-nonce floor must rebase to the new-canonical value")
        let selected = await network.nodeMempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(selected.contains { $0.body.rawCID == transfer.body.rawCID },
                      "the re-admitted, floor-rebased orphan must be selectable")
    }

    // MARK: - c. multi-signer nonce + cumulative debit at the node seam

    /// Pins the multi-signer nonce invariant at the NODE admission seam (complements the bare-NodeMempool
    /// unit coverage in MempoolMultiSignerTests): a multi-signer entry is indexed
    /// under EVERY signer, so a co-signer's confirmed-nonce floor rejects a stale
    /// shared tx, and the cumulative per-signer debit bound applies to the
    /// co-signer — never only `signers.first`.
    func test_multiSigner_nonceAndCumulativeDebit() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let a = keyedWallet()
        let b = keyedWallet()

        // (i) co-signer confirmed-nonce floor: B's floor is 5, so a shared tx at
        // nonce 0 is consensus-invalid for B even though A is fresh.
        await mempool.refreshConfirmedNonce(sender: b.address, nonce: 5)
        let stale = multiSignerTx(signers: [a, b], nonce: 0, fee: 10)
        switch await mempool.addTransaction(stale) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"),
                          "co-signer floor must reject the stale nonce, got: \(reason)")
        case .added, .replacedExisting:
            XCTFail("co-signer confirmed-nonce floor must apply to multi-signer admission (no secondary-signer gap)")
        }

        // (ii) cumulative per-signer debit bound: two txs each debit co-signer B
        // by 8 against B's balance of 10 — individually fine, cumulatively not.
        let freshMempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let c = keyedWallet()
        let d = keyedWallet()
        let t0 = multiSignerTx(signers: [c, d], nonce: 0, fee: 10)
        let t1 = multiSignerTx(signers: [c, d], nonce: 1, fee: 10)
        guard case .added = await freshMempool.addTransaction(
            t0, confirmedBalances: [d.address: 10], debits: [d.address: 8]) else {
            return XCTFail("first co-signer debit within balance must be admitted")
        }
        switch await freshMempool.addTransaction(
            t1, confirmedBalances: [d.address: 10], debits: [d.address: 8]) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Cumulative sender debit exceeds balance"),
                          "cumulative bound must track the co-signer, got: \(reason)")
        case .added, .replacedExisting:
            XCTFail("cumulative debit bound must track the co-signer, not only signers.first")
        }
    }

    // MARK: - d. revalidation after a canonical commit

    /// After state advances (a confirmed balance arrives), a now-unaffordable
    /// resident tx must not be served into a block. `dropUnaffordable` re-runs
    /// the SAME cumulative bound admission enforces, so a tx that would no
    /// longer be admittable is no longer retained/selectable.
    func test_revalidationAfterCanonicalCommit() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 64, maxNonceGap: 64)
        let w = keyedWallet()

        // Admit two contiguous txs that are affordable against a balance of 20:
        // each debits 8 (total 16 <= 20).
        let t0 = multiSignerTx(signers: [w], nonce: 0, fee: 10)
        let t1 = multiSignerTx(signers: [w], nonce: 1, fee: 10)
        guard case .added = await mempool.addTransaction(
            t0, confirmedBalances: [w.address: 20], debits: [w.address: 8]) else {
            return XCTFail("t0 must be admitted")
        }
        guard case .added = await mempool.addTransaction(
            t1, confirmedBalances: [w.address: 20], debits: [w.address: 8]) else {
            return XCTFail("t1 must be admitted")
        }
        let selectedBefore = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(Set(selectedBefore.map { $0.body.rawCID }),
                       Set([t0.body.rawCID, t1.body.rawCID]),
                       "both txs are selectable while affordable")

        // A canonical commit reveals the sender's balance dropped to 10 (a
        // competing spend confirmed elsewhere). Revalidation drops the now
        // unaffordable contiguous run.
        await mempool.dropUnaffordable(updates: [(sender: w.address, confirmedBalance: 10)])

        // t0 (debit 8) still fits 10; t1 (cumulative 16) does not — it must be
        // evicted and therefore not served into a block.
        let t0Resident = await mempool.contains(txCID: t0.body.rawCID)
        let t1Resident = await mempool.contains(txCID: t1.body.rawCID)
        XCTAssertTrue(t0Resident, "the still-affordable tx remains resident")
        XCTAssertFalse(t1Resident, "the now-unaffordable tx must be revalidated out and not served")
        let selectedAfter = await mempool.selectTransactions(maxCount: 10)
        XCTAssertFalse(selectedAfter.contains { $0.body.rawCID == t1.body.rawCID },
                       "an unaffordable tx must not be served into a block after the commit")
    }
}
