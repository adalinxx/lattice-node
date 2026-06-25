import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew

// Smoke tests for the full cross-chain swap lifecycle:
//
//   1. testChainLifecycleRPCEndpoints — exercises the HTTP endpoints
//      chain/deploy → register-rpc → chain/map → unregister-rpc → chain/map
//
//   2. testCrossChainSwapDepositReceiptWithdrawal — exercises the 3-step
//      atomic swap (deposit on child → receipt on parent → withdrawal on child)
//      directly against ChainState so every intermediate assertion is visible.

final class CrossChainSwapFlowTests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: 1. Chain lifecycle RPC endpoints
    // -------------------------------------------------------------------------

    func testChainLifecycleRPCEndpoints() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let auth = fixture.authToken
        let base = fixture.apiBaseURL

        // ── deploy child chain ───────────────────────────────────────────────
        let deployPayload: [String: Any] = [
            "directory": "Swap",
            "parentDirectory": DEFAULT_ROOT_DIRECTORY,
            "targetBlockTime": 30_000,
            "initialReward": 1_000_000,
            "halvingInterval": 1_000_000,
            "premine": 0,
            "maxTransactionsPerBlock": 5_000,
            "maxStateGrowth": 3_000_000,
            "maxBlockSize": 1_000_000,
            "retargetWindow": 120,
        ]
        let deployResp = try await postJSON(base.appendingPathComponent("chain/deploy"), body: deployPayload, auth: auth)
        XCTAssertNil(deployResp["error"], "chain/deploy should succeed")
        let genesisHash = try XCTUnwrap(deployResp["genesisHash"] as? String, "deploy must return genesisHash")
        XCTAssertFalse(genesisHash.isEmpty, "genesisHash must be non-empty")
        XCTAssertNotNil(deployResp["genesisHex"] as? String, "deploy must return genesisHex")

        // ── register-rpc ─────────────────────────────────────────────────────
        let registerPayload: [String: Any] = [
            "chainPath": [DEFAULT_ROOT_DIRECTORY, "Swap"],
            "endpoint": "http://127.0.0.1:18765/api",
        ]
        let registerResp = try await postJSON(base.appendingPathComponent("chain/register-rpc"), body: registerPayload, auth: auth)
        XCTAssertNil(registerResp["error"], "register-rpc should succeed: \(registerResp)")
        XCTAssertEqual(registerResp["ok"] as? Bool, true)

        // ── chain/map shows the registration ─────────────────────────────────
        // chain/map returns a flat [String: String] dict keyed by "Dir/Sub" paths.
        let swapKey = "\(DEFAULT_ROOT_DIRECTORY)/Swap"
        let mapBefore = try await getJSON(base.appendingPathComponent("chain/map"))
        XCTAssertEqual(mapBefore[swapKey] as? String, "http://127.0.0.1:18765/api",
                       "chain/map must include registered endpoint")

        // ── unregister-rpc (new endpoint) ─────────────────────────────────────
        let unregisterPayload: [String: Any] = [
            "chainPath": [DEFAULT_ROOT_DIRECTORY, "Swap"],
        ]
        let unregisterResp = try await postJSON(base.appendingPathComponent("chain/unregister-rpc"), body: unregisterPayload, auth: auth)
        XCTAssertNil(unregisterResp["error"], "unregister-rpc should succeed: \(unregisterResp)")
        XCTAssertEqual(unregisterResp["ok"] as? Bool, true)

        // ── chain/map no longer shows the entry ────────────────────────────────
        let mapAfter = try await getJSON(base.appendingPathComponent("chain/map"))
        XCTAssertNil(mapAfter[swapKey], "chain/map must not include unregistered endpoint")
    }

    // -------------------------------------------------------------------------
    // MARK: 2. Full 3-step atomic swap via in-process ChainState
    // -------------------------------------------------------------------------
    //
    // Actors:
    //   Alice (seller): holds 300 Payments tokens, wants 50 Nexus tokens
    //   Bob  (buyer):   holds 300 Nexus tokens,    wants 100 Payments tokens
    //
    // Flow:
    //   Step 1 — Alice deposits 100 Payments, demands 50 Nexus (nonce=7)
    //   Step 2 — Bob creates a receipt on Nexus paying 50 Nexus to Alice
    //   Step 3 — Bob withdraws 100 Payments from Alice's deposit
    //
    // Block sequence:
    //   C1  (child): Alice's deposit tx
    //   P1  (parent): embeds C1
    //   P2  (parent): Bob's receipt tx
    //   P2s (shell):  P2.nextBlock placeholder — gives C3 a parentState = P2.postState
    //   C3  (child):  Bob's withdrawal tx (parentState → P2.postState ✓)
    //   P3  (parent): embeds C3

    func testCrossChainSwapDepositReceiptWithdrawal() async throws {
        let f = cas()
        let t = now() - 10_000
        let swapNonce = UInt128(7)
        let demandedNexus: UInt64 = 50
        let depositedPayments: UInt64 = 100

        // ── keys ─────────────────────────────────────────────────────────────
        let alice = CryptoUtils.generateKeyPair()
        let bob   = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr   = addr(bob.publicKey)

        // ── genesis blocks ────────────────────────────────────────────────────
        // Nexus: premine 300 to Bob
        let nexusPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: 300)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), transactions: [sign(nexusPremineBody, bob)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(nexusGenesis, to: f)

        // Payments: premine 300 to Alice
        let paymentsPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: 300)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let paymentsGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Payments"), transactions: [sign(paymentsPremineBody, alice)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(paymentsGenesis, to: f)

        // Chain states
        let nexusChain    = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let paymentsChain = ChainState.fromGenesis(block: paymentsGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // ── Step 1: Alice deposits ─────────────────────────────────────────────
        let aliceDepositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(depositedPayments))],
            actions: [],
            depositActions: [DepositAction(
                nonce: swapNonce,
                demander: aliceAddr,
                amountDemanded: demandedNexus,
                amountDeposited: depositedPayments
            )],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let C1 = try await BlockBuilder.buildBlock(
            previous: paymentsGenesis, transactions: [sign(aliceDepositBody, alice)],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(C1, to: f)
        let c1Result = await paymentsChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: C1), block: C1
        )
        XCTAssertTrue(c1Result.extendsMainChain, "C1 (deposit) must extend Payments chain")

        // Mine parent P1 embedding C1 (establishes the child-in-parent link)
        let P1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Payments": C1],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(P1, to: f)
        let p1Result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: P1), block: P1
        )
        XCTAssertTrue(p1Result.extendsMainChain, "P1 must extend Nexus chain")

        // ── Step 2: Bob creates a receipt on Nexus ─────────────────────────────
        // netAccountDeltas (TransactionBody.swift:169-170) auto-appends both the
        // withdrawer debit (-amountDemanded from Bob) and the demander credit
        // (+amountDemanded to Alice).  No explicit AccountAction needed.
        let bobReceiptBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(
                withdrawer: bobAddr,
                nonce: swapNonce,
                demander: aliceAddr,
                amountDemanded: demandedNexus,
                directory: "Payments"
            )],
            withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1
        )
        let P2 = try await BlockBuilder.buildBlock(
            previous: P1, transactions: [sign(bobReceiptBody, bob)],
            timestamp: t + 2_000, target: UInt256.max, nonce: 2, fetcher: f
        )
        try await storeBlockFixture(P2, to: f)
        let p2Result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: P2), block: P2
        )
        XCTAssertTrue(p2Result.extendsMainChain, "P2 (receipt) must extend Nexus chain")

        // ── Step 3: Bob withdraws 100 Payments ────────────────────────────────
        // Build a shell P3 (based on P2, no transactions) so that
        //   P3_shell.prevState = P2.postState
        // Then C3 with parentChainBlock = P3_shell gets
        //   C3.parentState = P3_shell.prevState = P2.postState
        // which contains the receipt Bob created in P2.
        let P3_shell = try await BlockBuilder.buildBlock(
            previous: P2, timestamp: t + 3_000, target: UInt256.max, nonce: 99, fetcher: f
        )

        let bobWithdrawalBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(depositedPayments))],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: bobAddr,
                nonce: swapNonce,
                demander: aliceAddr,
                amountDemanded: demandedNexus,
                amountWithdrawn: depositedPayments
            )],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let C3 = try await BlockBuilder.buildBlock(
            previous: C1, transactions: [sign(bobWithdrawalBody, bob)],
            parentChainBlock: P3_shell,     // C3.parentState = P2.postState (receipt visible)
            timestamp: t + 3_000, target: UInt256.max, nonce: 3, fetcher: f
        )
        try await storeBlockFixture(C3, to: f)
        let c3Result = await paymentsChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: C3), block: C3
        )
        XCTAssertTrue(c3Result.extendsMainChain, "C3 (withdrawal) must extend Payments chain")

        // Mine P3 embedding C3
        let P3 = try await BlockBuilder.buildBlock(
            previous: P2, children: ["Payments": C3],
            timestamp: t + 3_000, target: UInt256.max, nonce: 3, fetcher: f
        )
        try await storeBlockFixture(P3, to: f)
        let p3Result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try VolumeImpl<Block>(node: P3), block: P3
        )
        XCTAssertTrue(p3Result.extendsMainChain, "P3 must extend Nexus chain")

        // ── Verify final state ─────────────────────────────────────────────────
        // Height checks (extract before XCTAssert to satisfy async autoclosure rule)
        let nexusHeight    = await nexusChain.getHighestBlockHeight()
        let paymentsHeight = await paymentsChain.getHighestBlockHeight()
        XCTAssertEqual(nexusHeight,    3, "Nexus at height 3 (genesis + P1 + P2 + P3)")
        XCTAssertEqual(paymentsHeight, 2, "Payments at height 2 (genesis + C1 + C3)")

        // Balance checks: resolve each chain's tip postState and read the trie.
        // C3 accepted (extendsMainChain) already proves cross-chain receipt
        // validation passed; these balance checks confirm the exact amounts.
        guard let nexusSnap    = await nexusChain.tipSnapshot,
              let paymentsSnap = await paymentsChain.tipSnapshot else {
            return XCTFail("Could not read tip snapshots")
        }
        let nexusStateHeader    = try await LatticeStateHeader(rawCID: nexusSnap.postStateCID).resolve(fetcher: f)
        let paymentsStateHeader = try await LatticeStateHeader(rawCID: paymentsSnap.postStateCID).resolve(fetcher: f)
        guard let nexusState    = nexusStateHeader.node,
              let paymentsState = paymentsStateHeader.node else {
            return XCTFail("Could not resolve tip states from fetcher")
        }

        // Read balances: AccountState is a merkle-dict[address → UInt64].
        func balance(_ state: LatticeState, _ address: String) async throws -> UInt64 {
            let resolved = try await state.accountState.resolve(
                paths: [[address]: .targeted], fetcher: f
            )
            return resolved.node.flatMap { try? $0.get(key: address) } ?? 0
        }

        let bobNexus      = try await balance(nexusState,    bobAddr)
        let aliceNexus    = try await balance(nexusState,    aliceAddr)
        let bobPayments   = try await balance(paymentsState, bobAddr)
        let alicePayments = try await balance(paymentsState, aliceAddr)

        // Bob:   300 Nexus − 50 (receipt) = 250 Nexus;  0 + 100 Payments (withdrawal)
        // Alice: 0 Nexus   + 50 (receipt) =  50 Nexus;  300 − 100 (deposit) = 200 Payments
        XCTAssertEqual(bobNexus,      250, "Bob Nexus: 300 − 50")
        XCTAssertEqual(aliceNexus,     50, "Alice Nexus: 0 + 50")
        XCTAssertEqual(bobPayments,   100, "Bob Payments: 0 + 100")
        XCTAssertEqual(alicePayments, 200, "Alice Payments: 300 − 100")
    }

    // =========================================================================
    // MARK: 3. Deposit / receipt state queries (in-process)
    // =========================================================================
    // These exercise the same lookup logic used by GET /api/deposit and
    // GET /api/receipt-state — resolving specific keys out of the merkle tries.

    func testDepositStateLookupAfterDeposit() async throws {
        let f = cas()
        let t = now() - 5_000

        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: 500)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Payments"), transactions: [sign(premineBody, alice)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // Deposit: Alice locks 100, demands 50
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -100)],
            actions: [], depositActions: [DepositAction(nonce: UInt128(42), demander: aliceAddr, amountDemanded: 50, amountDeposited: 100)],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let C1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(depositBody, alice)],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(C1, to: f)
        let result = await chain.submitBlock(parentBlockHeaderAndIndex: nil,
                                              blockHeader: try VolumeImpl<Block>(node: C1), block: C1)
        XCTAssertTrue(result.extendsMainChain)

        // Read deposit key directly from tip state
        let snap = await chain.tipSnapshot!
        let stateHeader = LatticeStateHeader(rawCID: snap.postStateCID)
        let resolved = try await stateHeader.resolve(fetcher: f)
        let state = try XCTUnwrap(resolved.node)

        let depositKey = DepositKey(nonce: UInt128(42), demander: aliceAddr, amountDemanded: 50).description
        let depositResolved = try await state.depositState.resolve(paths: [[depositKey]: .targeted], fetcher: f)
        let deposited: UInt64? = depositResolved.node.flatMap { try? $0.get(key: depositKey) }
        XCTAssertEqual(deposited, 100, "Deposit of 100 must be findable by key after C1")
    }

    func testReceiptStateAppliedAfterReceipt() async throws {
        // Verifies that a ReceiptAction is accepted by consensus and that
        // netAccountDeltas correctly transfers amountDemanded from the withdrawer (Bob)
        // to the demander (Alice). Block acceptance proves receipt state was computed
        // correctly; balance changes confirm the transfer semantics.
        let f = cas()
        let t = now() - 5_000

        let bob  = CryptoUtils.generateKeyPair()
        let alice = CryptoUtils.generateKeyPair()
        let bobAddr   = addr(bob.publicKey)
        let aliceAddr = addr(alice.publicKey)

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: 300)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), transactions: [sign(premineBody, bob)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // Bob creates a receipt: pays 50 to Alice, authorising Bob to claim 100 Payments
        let receiptBody = TransactionBody(
            accountActions: [],         // netAccountDeltas auto-debits Bob + credits Alice
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: bobAddr, nonce: UInt128(42), demander: aliceAddr, amountDemanded: 50, directory: "Payments")],
            withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1
        )
        let P1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(receiptBody, bob)],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(P1, to: f)
        let result = await chain.submitBlock(parentBlockHeaderAndIndex: nil,
                                              blockHeader: try VolumeImpl<Block>(node: P1), block: P1)
        XCTAssertTrue(result.extendsMainChain, "Receipt block must be accepted")

        // Verify balances to confirm netAccountDeltas transfer was applied
        guard let snap = await chain.tipSnapshot else { return XCTFail("No tip snapshot") }
        let stateHeader = LatticeStateHeader(rawCID: snap.postStateCID)
        let resolved = try await stateHeader.resolve(fetcher: f)
        let state = try XCTUnwrap(resolved.node)

        func readBalance(_ address: String) async throws -> UInt64 {
            let r = try await state.accountState.resolve(paths: [[address]: .targeted], fetcher: f)
            return r.node.flatMap { try? $0.get(key: address) } ?? 0
        }
        let bobBalance   = try await readBalance(bobAddr)
        let aliceBalance = try await readBalance(aliceAddr)
        // Bob:   300 − 50 (receipt auto-debit) = 250
        // Alice: 0   + 50 (receipt auto-credit) = 50
        XCTAssertEqual(bobBalance,   250, "Bob Nexus balance after receipt: 300 − 50")
        XCTAssertEqual(aliceBalance,  50, "Alice Nexus balance after receipt: 0 + 50")
    }

    func testDepositGoneAfterWithdrawal() async throws {
        let f = cas()
        let t = now() - 10_000

        let alice = CryptoUtils.generateKeyPair()
        let bob   = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr   = addr(bob.publicKey)

        // Payments genesis (Alice)
        let alicePremine = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: 300)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let paymentsGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Payments"), transactions: [sign(alicePremine, alice)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(paymentsGenesis, to: f)

        // Nexus genesis (Bob)
        let bobPremine = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: 300)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), transactions: [sign(bobPremine, bob)],
            timestamp: t, target: UInt256.max, fetcher: f
        )
        try await storeBlockFixture(nexusGenesis, to: f)

        let nexus    = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let payments = ChainState.fromGenesis(block: paymentsGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // C1: Alice deposits
        let C1 = try await BlockBuilder.buildBlock(
            previous: paymentsGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: aliceAddr, delta: -100)],
                actions: [], depositActions: [DepositAction(nonce: UInt128(9), demander: aliceAddr, amountDemanded: 50, amountDeposited: 100)],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [aliceAddr], fee: 0, nonce: 1), alice)],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(C1, to: f)
        _ = await payments.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl<Block>(node: C1), block: C1)

        // P1: root parent embeds C1
        let P1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Payments": C1],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f
        )
        try await storeBlockFixture(P1, to: f)
        _ = await nexus.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl<Block>(node: P1), block: P1)

        // P2: Bob's receipt
        let P2 = try await BlockBuilder.buildBlock(
            previous: P1,
            transactions: [sign(TransactionBody(
                accountActions: [],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [ReceiptAction(withdrawer: bobAddr, nonce: UInt128(9), demander: aliceAddr, amountDemanded: 50, directory: "Payments")],
                withdrawalActions: [],
                signers: [bobAddr], fee: 0, nonce: 1), bob)],
            timestamp: t + 2_000, target: UInt256.max, nonce: 2, fetcher: f
        )
        try await storeBlockFixture(P2, to: f)
        _ = await nexus.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl<Block>(node: P2), block: P2)

        // P3_shell: derive P2.postState for C3's parentState
        let P3_shell = try await BlockBuilder.buildBlock(
            previous: P2, timestamp: t + 3_000, target: UInt256.max, nonce: 99, fetcher: f
        )

        // C3: Bob withdraws
        let C3 = try await BlockBuilder.buildBlock(
            previous: C1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: bobAddr, delta: 100)],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: UInt128(9), demander: aliceAddr, amountDemanded: 50, amountWithdrawn: 100)],
                signers: [bobAddr], fee: 0, nonce: 0), bob)],
            parentChainBlock: P3_shell,
            timestamp: t + 3_000, target: UInt256.max, nonce: 3, fetcher: f
        )
        try await storeBlockFixture(C3, to: f)
        let c3r = await payments.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try VolumeImpl<Block>(node: C3), block: C3)
        XCTAssertTrue(c3r.extendsMainChain, "Withdrawal block must be accepted")

        // Deposit key must be gone from tip state after withdrawal
        let snap = await payments.tipSnapshot!
        let stateHeader = LatticeStateHeader(rawCID: snap.postStateCID)
        let resolved = try await stateHeader.resolve(fetcher: f)
        let state = try XCTUnwrap(resolved.node)

        let depositKey = DepositKey(nonce: UInt128(9), demander: aliceAddr, amountDemanded: 50).description
        let depositResolved = try await state.depositState.resolve(paths: [[depositKey]: .targeted], fetcher: f)
        let deposited: UInt64? = depositResolved.node.flatMap { try? $0.get(key: depositKey) }
        XCTAssertNil(deposited, "Deposit entry must be deleted after withdrawal")
    }

    // =========================================================================
    // MARK: 4. chain/parent-height HTTP endpoint
    // =========================================================================

    func testParentChainHeightEndpoint() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        // Root chain has no parent — parentHeight must be nil
        let resp = try await getJSON(fixture.apiBaseURL.appendingPathComponent("chain/parent-height"))
        XCTAssertTrue(resp["parentHeight"] is NSNull || resp["parentHeight"] == nil,
                      "Root chain parent height must be null, got: \(resp)")
    }

    // =========================================================================
    // MARK: 5. Existing deposit / receipt-state HTTP endpoints (smoke)
    // =========================================================================
    // Verify the endpoints return the right shape even when the swap doesn't exist.

    func testDepositEndpointReturnsMissingForUnknownSwap() async throws {
        let fixture = try await startNodeWithRPC()
        defer { fixture.shutdown() }

        let base = fixture.apiBaseURL
        let nonceHex = String(UInt64(42), radix: 16)
        let fakeAddr = addr(CryptoUtils.generateKeyPair().publicKey)
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+")
        let pathEnc = "Nexus".addingPercentEncoding(withAllowedCharacters: allowed) ?? "Nexus"
        let resp = try await getJSON(
            base.appendingPathComponent("deposit")
                .appendingQueryItems([
                    "demander": fakeAddr, "amount": "50",
                    "nonce": nonceHex, "chainPath": pathEnc
                ])
        )
        XCTAssertEqual(resp["exists"] as? Bool, false, "Non-existent deposit must return exists=false")
    }

    // =========================================================================
    // MARK: - HTTP helpers
    // =========================================================================

    private typealias NodeFixture = (
        node: LatticeNode,
        apiBaseURL: URL,
        authToken: String,
        cookieFile: URL,
        shutdown: () -> Void
    )

    private func startNodeWithRPC() async throws -> NodeFixture {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()

        let rpcPort = nextTestPort()
        let cookieFile = tmp.appendingPathComponent(".cookie")
        let cookie = try CookieAuth.generate(at: cookieFile)
        let server = RPCServer(
            node: node, port: rpcPort, bindAddress: "127.0.0.1",
            allowedOrigin: "*", auth: cookie
        )
        let task = Task { try await server.run() }
        try await waitForRPCServer(port: rpcPort)

        return (
            node,
            URL(string: "http://127.0.0.1:\(rpcPort)/api")!,
            cookie.token,
            cookieFile,
            {
                task.cancel()
                let sem = DispatchSemaphore(value: 0)
                Task { await node.stop(); sem.signal() }
                sem.wait()
                try? FileManager.default.removeItem(at: tmp)
            }
        )
    }

    private func getJSON(_ url: URL, auth: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        #if canImport(FoundationNetworking)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        #endif
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ url: URL, body: [String: Any], auth: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        #if canImport(FoundationNetworking)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        #endif
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - URL convenience

private extension URL {
    func appendingQueryItems(_ items: [String: String]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url ?? self
    }
}
