import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew
import VolumeBroker

// (Mechanism A): the NODE builds the coinbase to its own
// configured `--coinbase-address`. The miner NEVER sends or holds a signing key;
// it only searches the nonce over the returned, immutable work.
//
// These tests are the CI-UNCONDITIONAL security-regression gate the AC demands.
// They drive the REAL RPC entry points end-to-end:
//
//   POST /api/chain/template     — fetch immutable work (NO key in the body)
//   POST /api/chain/submit-work  — submit only { workId, nonce }
//   GET  /api/balance/{address}  — observe where the sealed coinbase paid
//
// Every read goes through the node's OWN serialized RPC pipeline (balance query),
// so there is no concurrent SQLite access against the shared DiskBroker — the
// flake the prior durable-broker-resolve version hit. The test genesis target
// is `UInt256.max` (target = max), so nonce=0 is a valid solution: submit-work
// seals block 1 through the node's normal acceptance path, and the coinbase credit
// lands in account state, observable via the balance endpoint.
//
// The tests assert:
//  1. A template request carrying attacker key material is NOT rejected and NOT
//     honored: the work builds, and the sealed block's coinbase pays the node's
//     configured `--coinbase-address` — never the request-supplied address.
//  2. The node-local coinbase authority is NOT the recipient unless explicitly
//     configured as the payout (Mechanism A: the credit is authorization-free,
//     so signer != recipient; the node never holds the payout key).
//  3. submit-work consumes only workId/nonce; a key field in its body cannot buy
//     acceptance nor redirect the payout.
//
// A regression that re-introduced request-key usage (renamed field, raw-JSON
// read, or a second endpoint) would redirect the coinbase or seal under a
// supplied key, and one of these balance assertions would fail on every runner.
final class CoinbaseAddressTemplateTests: XCTestCase {
    private struct TemplateResponse: Decodable {
        let workId: String
        let blockHex: String
        let staleToken: String?
    }
    private struct SubmitResponse: Decodable {
        let accepted: Bool
        let status: String
        let blockHash: String?
        let height: UInt64?
    }
    private struct BalanceResponse: Decodable {
        let address: String
        let balance: UInt64
    }
    private struct NonceResponse: Decodable {
        let address: String
        let nonce: UInt64
    }

    /// Build a started node configured with `--coinbase-address`, plus a single
    /// admin RPCServer bound to loopback with a cookie credential. The caller is
    /// responsible for teardown via `defer` (mirrors the CI-stable SecurityTests
    /// pattern: cancel the server task, stop the node, remove the temp dir).
    private func makeNodeAndServer(
        coinbaseAddress: String,
        nodeKeyPair: (privateKey: String, publicKey: String)? = nil
    ) async throws -> (node: LatticeNode, serverTask: Task<Void, Error>, token: String, port: UInt16, dir: URL) {
        let kp = nodeKeyPair ?? CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                minPeerKeyBits: 0, coinbaseAddress: coinbaseAddress
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()

        let port = nextTestPort()
        let (server, token) = try makeAdminRPCServer(node: node, port: port)
        let serverTask = Task { try await server.run() }
        try await waitForRPCServer(port: port)
        return (node, serverTask, token, port, tmp)
    }

    private func post(port: UInt16, token: String, path: String, body: [String: Any]) async throws -> (status: Int, data: Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func balance(port: UInt16, token: String, address: String) async throws -> UInt64 {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/balance/\(address)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(BalanceResponse.self, from: data).balance
    }

    private func nonce(port: UInt16, token: String, address: String) async throws -> UInt64 {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/nonce/\(address)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(NonceResponse.self, from: data).nonce
    }

    /// Mechanism A end-to-end: a template request that *tries* to supply miner key
    /// material is neither rejected nor honored. The work builds, submit-work seals
    /// block 1 from the nonce alone, and the coinbase pays the configured
    /// `--coinbase-address`, never the request-supplied address, never the node's
    /// own signing identity.
    func testSealedCoinbasePaysConfiguredAddressAndIgnoresRequestKey() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)
        let attackerKP = CryptoUtils.generateKeyPair()
        let attackerAddress = CryptoUtils.createAddress(from: attackerKP.publicKey)

        let (node, serverTask, token, port, dir) = try await makeNodeAndServer(coinbaseAddress: coinbaseAddress)
        defer {
            serverTask.cancel()
            Task { await node.stop() }
            try? FileManager.default.removeItem(at: dir)
        }
        let nodeAddress = CryptoUtils.createAddress(from: await node.config.publicKey)

        // 1) Template — the body carries attacker key material that the node MUST
        //    ignore. It is not rejected (200) and it does not redirect anything.
        let (templateStatus, templateData) = try await post(
            port: port, token: token, path: "/api/chain/template",
            body: [
                "minerPublicKey": attackerKP.publicKey,
                "minerPrivateKey": attackerKP.privateKey,
            ]
        )
        XCTAssertEqual(templateStatus, 200, String(data: templateData, encoding: .utf8) ?? "")
        let template = try JSONDecoder().decode(TemplateResponse.self, from: templateData)

        // 2) submit-work — only workId + nonce are load-bearing. nonce=0 satisfies
        //    the max target, so the node seals block 1 through its acceptance path.
        //    Attacker key fields are present but must not be decoded/honored.
        let (submitStatus, submitData) = try await post(
            port: port, token: token, path: "/api/chain/submit-work",
            body: [
                "workId": template.workId,
                "nonce": 0,
                "minerPublicKey": attackerKP.publicKey,
                "minerPrivateKey": attackerKP.privateKey,
            ]
        )
        let submit = try JSONDecoder().decode(SubmitResponse.self, from: submitData)
        XCTAssertEqual(submitStatus, 200, String(data: submitData, encoding: .utf8) ?? "")
        XCTAssertTrue(submit.accepted, "nonce=0 meets the max target; block must seal")
        XCTAssertEqual(submit.height, 1, "the sealed block is height 1 atop genesis")

        // 3) Balances — the sealed coinbase paid the configured --coinbase-address
        //    with exactly the block reward; the request-supplied attacker address
        //    and the node identity (when not configured as payout) received nothing.
        let spec = testSpec()
        let expectedReward = spec.rewardAtBlock(1)
        let coinbaseBalance = try await balance(port: port, token: token, address: coinbaseAddress)
        XCTAssertEqual(coinbaseBalance, expectedReward,
                       "the sealed coinbase must pay reward to the configured --coinbase-address")
        let attackerBalance = try await balance(port: port, token: token, address: attackerAddress)
        XCTAssertEqual(attackerBalance, 0,
                       "a request-supplied miner key must NOT redirect the coinbase payout")
        let nodeBalance = try await balance(port: port, token: token, address: nodeAddress)
        XCTAssertEqual(nodeBalance, 0,
                       "Mechanism A: the node identity is not implicitly the coinbase recipient")
    }

    /// Rewards credit the configured payout account but are signed by a separate
    /// node-local authority. When the smoke harness uses the node identity as the
    /// payout address, reward blocks must not advance that account's user-spend
    /// nonce. A side-forked nonce-0 user spend must remain valid until it is
    /// actually confirmed, regardless of intervening coinbase rewards.
    func testCoinbaseRewardsDoNotConsumePayoutNonce() async throws {
        let nodeKP = CryptoUtils.generateKeyPair()
        let nodeAddress = CryptoUtils.createAddress(from: nodeKP.publicKey)

        let (node, serverTask, token, port, dir) = try await makeNodeAndServer(
            coinbaseAddress: nodeAddress,
            nodeKeyPair: nodeKP
        )
        defer {
            serverTask.cancel()
            Task { await node.stop() }
            try? FileManager.default.removeItem(at: dir)
        }
        let authorityAddress = await node.coinbaseAuthority.address
        XCTAssertNotEqual(authorityAddress, nodeAddress)

        let template = try JSONDecoder().decode(
            TemplateResponse.self,
            from: try await post(port: port, token: token, path: "/api/chain/template", body: [:]).data
        )
        let submit = try JSONDecoder().decode(
            SubmitResponse.self,
            from: try await post(port: port, token: token, path: "/api/chain/submit-work", body: ["workId": template.workId, "nonce": 0]).data
        )
        XCTAssertTrue(submit.accepted, "block 1 coinbase should seal")
        XCTAssertEqual(submit.height, 1)

        let spec = testSpec()
        let nodeBalanceAfterReward = try await balance(port: port, token: token, address: nodeAddress)
        let nodeNonceAfterReward = try await nonce(port: port, token: token, address: nodeAddress)
        let authorityNonceAfterReward = try await nonce(port: port, token: token, address: authorityAddress)
        XCTAssertEqual(nodeBalanceAfterReward, spec.rewardAtBlock(1))
        XCTAssertEqual(nodeNonceAfterReward, 0,
                       "coinbase rewards must not consume the payout account's spend nonce")
        XCTAssertEqual(authorityNonceAfterReward, 1,
                       "the signer nonce advances on the node-local coinbase authority")

        let receiver = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let spendBody = TransactionBody(
            accountActions: [
                AccountAction(owner: nodeAddress, delta: -11),
                AccountAction(owner: receiver, delta: 10),
            ],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [nodeAddress],
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let addResult = await node.submitTransactionWithReason(directory: "Nexus", transaction: sign(spendBody, nodeKP))
        if case .failure(let reason) = addResult {
            return XCTFail("nonce-0 payout spend should remain valid after coinbase reward: \(reason)")
        }

        let template2 = try JSONDecoder().decode(
            TemplateResponse.self,
            from: try await post(port: port, token: token, path: "/api/chain/template", body: [:]).data
        )
        let submit2 = try JSONDecoder().decode(
            SubmitResponse.self,
            from: try await post(port: port, token: token, path: "/api/chain/submit-work", body: ["workId": template2.workId, "nonce": 0]).data
        )
        XCTAssertTrue(submit2.accepted, "block 2 should seal the payout spend")
        XCTAssertEqual(submit2.height, 2)
        let nodeNonceAfterSpend = try await nonce(port: port, token: token, address: nodeAddress)
        let authorityNonceAfterSecondReward = try await nonce(port: port, token: token, address: authorityAddress)
        let receiverBalance = try await balance(port: port, token: token, address: receiver)
        XCTAssertEqual(nodeNonceAfterSpend, 1,
                       "only the explicit payout spend consumes the payout nonce")
        XCTAssertEqual(authorityNonceAfterSecondReward, 2)
        XCTAssertEqual(receiverBalance, 10)
    }

    /// The template request needs NO key material at all to produce buildable,
    /// sealable work whose coinbase pays the configured address. Proves the node
    /// builds the coinbase purely from `--coinbase-address`.
    func testTemplateNeedsNoPrivateKeyToBuildPayingCoinbase() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)

        let (node, serverTask, token, port, dir) = try await makeNodeAndServer(coinbaseAddress: coinbaseAddress)
        defer {
            serverTask.cancel()
            Task { await node.stop() }
            try? FileManager.default.removeItem(at: dir)
        }

        // Empty body: no minerPrivateKey, no minerPublicKey — nothing.
        let (templateStatus, templateData) = try await post(
            port: port, token: token, path: "/api/chain/template", body: [:]
        )
        XCTAssertEqual(templateStatus, 200, String(data: templateData, encoding: .utf8) ?? "")
        let template = try JSONDecoder().decode(TemplateResponse.self, from: templateData)

        let (submitStatus, submitData) = try await post(
            port: port, token: token, path: "/api/chain/submit-work",
            body: ["workId": template.workId, "nonce": 0]
        )
        let submit = try JSONDecoder().decode(SubmitResponse.self, from: submitData)
        XCTAssertEqual(submitStatus, 200, String(data: submitData, encoding: .utf8) ?? "")
        XCTAssertTrue(submit.accepted, "key-free work must still seal")
        XCTAssertEqual(submit.height, 1)

        let spec = testSpec()
        let coinbaseBalance = try await balance(port: port, token: token, address: coinbaseAddress)
        XCTAssertEqual(coinbaseBalance, spec.rewardAtBlock(1),
                       "key-free template must still pay the configured --coinbase-address")
    }

    func testTemplateCacheReusesWorkUntilTipOrMempoolGenerationChanges() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)

        let (node, serverTask, token, port, dir) = try await makeNodeAndServer(coinbaseAddress: coinbaseAddress)
        defer {
            serverTask.cancel()
            Task { await node.stop() }
            try? FileManager.default.removeItem(at: dir)
        }

        let (firstStatus, firstData) = try await post(
            port: port, token: token, path: "/api/chain/template", body: [:]
        )
        XCTAssertEqual(firstStatus, 200, String(data: firstData, encoding: .utf8) ?? "")
        let first = try JSONDecoder().decode(TemplateResponse.self, from: firstData)

        guard let cached = await node.cachedTemplate(forKey: "Nexus") else {
            return XCTFail("first template poll should populate cache")
        }
        XCTAssertFalse(cached.storedCandidateVolumeRoots.isEmpty)

        try await Task.sleep(for: .milliseconds(25))
        let (secondStatus, secondData) = try await post(
            port: port, token: token, path: "/api/chain/template", body: [:]
        )
        XCTAssertEqual(secondStatus, 200, String(data: secondData, encoding: .utf8) ?? "")
        let second = try JSONDecoder().decode(TemplateResponse.self, from: secondData)
        XCTAssertEqual(second.workId, first.workId)
        XCTAssertEqual(second.blockHex, first.blockHex)

        let (submitStatus, submitData) = try await post(
            port: port, token: token, path: "/api/chain/submit-work",
            body: ["workId": first.workId, "nonce": 0]
        )
        let submit = try JSONDecoder().decode(SubmitResponse.self, from: submitData)
        XCTAssertEqual(submitStatus, 200, String(data: submitData, encoding: .utf8) ?? "")
        XCTAssertTrue(submit.accepted)

        try await Task.sleep(for: .milliseconds(25))
        let (afterTipStatus, afterTipData) = try await post(
            port: port, token: token, path: "/api/chain/template", body: [:]
        )
        XCTAssertEqual(afterTipStatus, 200, String(data: afterTipData, encoding: .utf8) ?? "")
        let afterTipMove = try JSONDecoder().decode(TemplateResponse.self, from: afterTipData)
        XCTAssertNotEqual(afterTipMove.workId, first.workId)
        XCTAssertNotEqual(afterTipMove.staleToken, first.staleToken)

        guard let network = await node.network(for: "Nexus") else {
            return XCTFail("Nexus network should exist")
        }
        let generationBefore = await network.nodeMempool.currentGeneration
        let txKP = CryptoUtils.generateKeyPair()
        let txAddress = CryptoUtils.createAddress(from: txKP.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: txAddress, delta: -10_000)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [txAddress],
            fee: 10_000,
            nonce: 0
        )
        let mempoolAdd = await network.nodeMempool.add(transaction: sign(body, txKP))
        XCTAssertTrue(mempoolAdd)
        let generationAfter = await network.nodeMempool.currentGeneration
        XCTAssertGreaterThan(generationAfter, generationBefore)

        try await Task.sleep(for: .milliseconds(25))
        let (afterMempoolStatus, afterMempoolData) = try await post(
            port: port, token: token, path: "/api/chain/template", body: [:]
        )
        XCTAssertEqual(afterMempoolStatus, 200, String(data: afterMempoolData, encoding: .utf8) ?? "")
        let afterMempoolChange = try JSONDecoder().decode(TemplateResponse.self, from: afterMempoolData)
        XCTAssertNotEqual(afterMempoolChange.workId, afterTipMove.workId)
    }
}
