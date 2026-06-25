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

// Item 4: an integrated adversarial harness for the cross-chain-swap safety contracts.
// Each prior review round patched one of these in isolation; this suite exercises them
// together with the failure case, not just the happy path, so a regression in any one
// dimension is caught here rather than discovered review-by-review:
//
//   Contract 1  canonical txCID vs bodyCID (receipt-index identity)
//   Contract 2  parent visibility: receipt visible at carrier > receiptHeight, NOT at ==
//   Contract 3/4 registration liveness: auth-check gates the supervised control plane
//   Contract 6  fee policy surfaced in chain/info for pre-payment sizing
//   chain-path identity: a receipt binds to a specific child directory
final class CrossChainSwapInvariantsTests: XCTestCase {

    // Build a swap up to the receipt block and resolve the three states the
    // withdrawal validity check keys off. Returns:
    //   childPrev      = C1.postState (deposit present)
    //   parentPreReceipt  = P1.postState  = postState(receiptHeight-1)  (receipt NOT visible)
    //   parentWithReceipt = P2.postState  = postState(receiptHeight)    (receipt visible)
    //   withdrawal     = Bob's withdrawal body on "Payments"
    private func buildSwapStates(receiptDirectory: String = "Payments")
        async throws -> (childPrev: LatticeState, parentPreReceipt: LatticeState,
                         parentWithReceipt: LatticeState, withdrawal: TransactionBody, fetcher: Fetcher) {
        let f = cas()
        let t = now() - 10_000
        let swapNonce = UInt128(7)
        let demanded: UInt64 = 50, deposited: UInt64 = 100
        let alice = CryptoUtils.generateKeyPair(), bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey), bobAddr = addr(bob.publicKey)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: bobAddr, delta: 300)],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [], signers: [bobAddr], fee: 0, nonce: 0), bob)],
            timestamp: t, target: UInt256.max, fetcher: f)
        try await storeBlockFixture(nexusGenesis, to: f)
        let paymentsGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Payments"), transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: aliceAddr, delta: 300)],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0), alice)],
            timestamp: t, target: UInt256.max, fetcher: f)
        try await storeBlockFixture(paymentsGenesis, to: f)

        // C1: Alice deposits 100 Payments.
        let C1 = try await BlockBuilder.buildBlock(
            previous: paymentsGenesis, transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(deposited))],
                actions: [], depositActions: [DepositAction(nonce: swapNonce, demander: aliceAddr, amountDemanded: demanded, amountDeposited: deposited)],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [aliceAddr], fee: 0, nonce: 1), alice)],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f)
        try await storeBlockFixture(C1, to: f)
        // P1 (height 1, no receipt): embeds C1.
        let P1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Payments": C1],
            timestamp: t + 1_000, target: UInt256.max, nonce: 1, fetcher: f)
        try await storeBlockFixture(P1, to: f)
        // P2 (height 2 = receipt block): Bob's receipt for `receiptDirectory`.
        let P2 = try await BlockBuilder.buildBlock(
            previous: P1, transactions: [sign(TransactionBody(
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                receiptActions: [ReceiptAction(withdrawer: bobAddr, nonce: swapNonce, demander: aliceAddr, amountDemanded: demanded, directory: receiptDirectory)],
                withdrawalActions: [], signers: [bobAddr], fee: 0, nonce: 1), bob)],
            timestamp: t + 2_000, target: UInt256.max, nonce: 2, fetcher: f)
        try await storeBlockFixture(P2, to: f)

        func state(_ b: Block) async throws -> LatticeState {
            let resolved = try await LatticeStateHeader(rawCID: b.postState.rawCID).resolve(fetcher: f)
            return try XCTUnwrap(resolved.node)
        }
        let withdrawal = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(deposited))],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: swapNonce, demander: aliceAddr, amountDemanded: demanded, amountWithdrawn: deposited)],
            signers: [bobAddr], fee: 0, nonce: 0)
        return (try await state(C1), try await state(P1), try await state(P2), withdrawal, f)
    }

    // -------------------------------------------------------------------------
    // Contract 2 — parent-visibility boundary (the off-by-one), at the true
    // enforcement point: TransactionBody.withdrawalsAreValid checks the receipt
    // against `parentState.receiptState`. A child carried by parent block H sees
    // parentState = postState(H-1), so a receipt in block R is INVISIBLE at carrier
    // == R (postState(R-1)) and visible only at carrier >= R+1 (postState(R)).
    // -------------------------------------------------------------------------
    func test_parentVisibility_receiptInvisibleAtCarrierMinusOne_visibleAtReceiptHeight() async throws {
        let s = try await buildSwapStates()

        // carrier == receipt height ⇒ parentState = postState(receiptHeight-1): receipt
        // not yet present ⇒ validation MUST throw.
        var threw = false
        do {
            _ = try await s.withdrawal.withdrawalsAreValid(
                directory: "Payments", prevState: s.childPrev,
                parentState: s.parentPreReceipt, fetcher: s.fetcher)
        } catch { threw = true }
        XCTAssertTrue(threw, "withdrawal must be invalid when parentState is postState(receiptHeight-1) — receipt not visible (Contract 2 boundary)")

        // carrier == receipt+1 ⇒ parentState = postState(receiptHeight): receipt visible.
        let ok = try await s.withdrawal.withdrawalsAreValid(
            directory: "Payments", prevState: s.childPrev,
            parentState: s.parentWithReceipt, fetcher: s.fetcher)
        XCTAssertTrue(ok, "withdrawal must be valid once parentState includes the receipt block")
    }

    // -------------------------------------------------------------------------
    // Chain-path identity — the receipt binds to the child directory. A receipt
    // recorded for "Payments" must not authorize a withdrawal validated under a
    // different directory (the ReceiptKey embeds the directory).
    // -------------------------------------------------------------------------
    func test_chainPathIdentity_receiptDoesNotCrossDirectories() async throws {
        let s = try await buildSwapStates(receiptDirectory: "Payments")
        // Same receipt + deposit, but validated under the WRONG directory ⇒ key miss ⇒ throw.
        var threw = false
        do {
            _ = try await s.withdrawal.withdrawalsAreValid(
                directory: "Other", prevState: s.childPrev,
                parentState: s.parentWithReceipt, fetcher: s.fetcher)
        } catch { threw = true }
        XCTAssertTrue(threw, "a receipt bound to 'Payments' must not authorize a withdrawal validated under 'Other' (chain-path identity)")
    }

    // -------------------------------------------------------------------------
    // Contract 1 — the value returned as `txCID` is the canonical transaction CID
    // (the receipt-index key), distinct from `bodyCID`. A swap that polled the body
    // CID would never find its mined receipt.
    // -------------------------------------------------------------------------
    func test_transaction_returnsCanonicalTxCID_distinctFromBodyCID() async throws {
        let fx = try await startNodeWithRPC()
        defer { fx.shutdown() }

        let signer = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr(signer.publicKey), delta: 0)],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [], signers: [addr(signer.publicKey)], fee: 1, nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY])
        let tx = sign(body, signer)
        let expectedBodyCID = try HeaderImpl<TransactionBody>(node: body).rawCID
        let expectedTxCID = try VolumeImpl<Transaction>(node: tx).rawCID
        XCTAssertNotEqual(expectedTxCID, expectedBodyCID, "precondition: tx CID and body CID differ")

        let payload: [String: Any] = [
            "signatures": [signer.publicKey: tx.signatures[signer.publicKey] ?? ""],
            "bodyCID": expectedBodyCID,
            "bodyData": (body.toData() ?? Data()).map { String(format: "%02x", $0) }.joined(),
            "chainPath": [DEFAULT_ROOT_DIRECTORY],
        ]
        let resp = try await postJSON(fx.apiBaseURL.appendingPathComponent("transaction"), body: payload, auth: fx.authToken)

        XCTAssertEqual(resp["txCID"] as? String, expectedTxCID,
                       "POST /api/transaction must return the canonical VolumeImpl<Transaction> CID as txCID (the receipt-index key)")
        XCTAssertEqual(resp["bodyCID"] as? String, expectedBodyCID,
                       "the body CID must be returned separately as bodyCID")
        XCTAssertNotEqual(resp["txCID"] as? String, resp["bodyCID"] as? String)
    }

    // -------------------------------------------------------------------------
    // Contract 6 — chain/info surfaces the node's effective per-byte fee floor so a
    // swap buyer can size the child withdrawal fee before the irreversible payment.
    // -------------------------------------------------------------------------
    func test_chainInfo_surfacesMinFeeRate() async throws {
        let fx = try await startNodeWithRPC(minFeeRate: 7)
        defer { fx.shutdown() }
        let info = try await getJSON(fx.apiBaseURL.appendingPathComponent("chain/info"))
        let chains = try XCTUnwrap(info["chains"] as? [[String: Any]])
        let root = try XCTUnwrap(chains.first)
        XCTAssertEqual(root["minFeeRate"] as? Int, 7,
                       "chain/info must report the node's configured minFeeRate for pre-payment fee sizing")
    }

    // -------------------------------------------------------------------------
    // Contract 3/4 — registration liveness. The supervised control plane registers a
    // child only after an authenticated probe succeeds; auth-check is that probe. It
    // must return 401 without the cookie and 200 with it.
    // -------------------------------------------------------------------------
    func test_authCheck_gatesRegistrationLiveness() async throws {
        let fx = try await startNodeWithRPC()
        defer { fx.shutdown() }
        let url = fx.apiBaseURL.appendingPathComponent("chain/auth-check")

        func status(auth: String?) async throws -> Int {
            var req = URLRequest(url: url)
            if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let unauth = try await status(auth: nil)
        XCTAssertEqual(unauth, 401, "auth-check must fail closed without a valid cookie")
        let authed = try await status(auth: fx.authToken)
        XCTAssertEqual(authed, 200, "auth-check must return 200 to the holder of the current cookie")
    }

    // -------------------------------------------------------------------------
    // Serialization cap — a swap nonce is a UInt128 field, but cashew's DAG-CBOR
    // encoder caps integers at UInt64.max (throws integerOverflow above it). A
    // deposit body whose nonce exceeds UInt64.max is therefore UNSERIALIZABLE, so
    // `swap sell` must generate nonces within UInt64 range. (Regression: the sell
    // command previously generated a full 128-bit nonce → every deposit body failed
    // to serialize; the swap CLI was unusable until exercised end-to-end.)
    // -------------------------------------------------------------------------
    func test_swapDepositNonce_aboveUInt64Max_isUnserializable() {
        let kp = CryptoUtils.generateKeyPair()
        let owner = addr(kp.publicKey)
        func depositBody(nonce: UInt128) -> TransactionBody {
            TransactionBody(
                accountActions: [AccountAction(owner: owner, delta: -1)],
                actions: [], depositActions: [DepositAction(nonce: nonce, demander: owner, amountDemanded: 1, amountDeposited: 1)],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 1, nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"])
        }
        XCTAssertNotNil(depositBody(nonce: UInt128(UInt64.max)).toData(),
                        "a swap nonce at UInt64.max must serialize")
        XCTAssertNil(depositBody(nonce: UInt128(UInt64.max) + 1).toData(),
                     "a swap nonce above UInt64.max must NOT serialize — swap sell must stay within UInt64 range")
    }

    // `swap buy`/`status` accept a caller-supplied swap-id; a hand-crafted nonce above
    // UInt64.max must be rejected up front (before any network/probe) rather than failing
    // later with an opaque serialization error.
    func test_swapBuy_rejectsNonceAboveUInt64Max() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("buyer-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["publicKey": kp.publicKey, "privateKey": kp.privateKey])
            .write(to: keyFile)
        defer { try? FileManager.default.removeItem(at: keyFile) }

        // nonce = UInt64.max + 1 (18446744073709551616); valid in every other respect.
        let swapId = "FastTest:18446744073709551616:\(addr(kp.publicKey)):100:500"
        let cmd = try SwapBuyCommand.parse([
            "--child-rpc", "http://127.0.0.1:1",   // never reached — the guard fires first
            "--key", keyFile.path,
            "--swap-id", swapId, "--yes",
        ])
        var threw = false
        do { try await cmd.run() } catch { threw = true }
        XCTAssertTrue(threw, "swap buy must reject a swap-id nonce above UInt64.max before doing any work")
    }

    // =========================================================================
    // MARK: - Node + RPC fixture
    // =========================================================================

    private typealias NodeFixture = (node: LatticeNode, apiBaseURL: URL, authToken: String, shutdown: () -> Void)

    private func startNodeWithRPC(minFeeRate: UInt64 = 0) async throws -> NodeFixture {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: tmp,
                enableLocalDiscovery: false, minFeeRate: minFeeRate, minPeerKeyBits: 0),
            genesisConfig: testGenesis())
        try await node.start()

        let rpcPort = nextTestPort()
        let cookie = try CookieAuth.generate(at: tmp.appendingPathComponent(".cookie"))
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*", auth: cookie)
        let task = Task { try await server.run() }
        try await waitForRPCServer(port: rpcPort)
        return (node, URL(string: "http://127.0.0.1:\(rpcPort)/api")!, cookie.token, {
            task.cancel()
            let sem = DispatchSemaphore(value: 0)
            Task { await node.stop(); sem.signal() }
            sem.wait()
            try? FileManager.default.removeItem(at: tmp)
        })
    }

    private func getJSON(_ url: URL, auth: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ url: URL, body: [String: Any], auth: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
