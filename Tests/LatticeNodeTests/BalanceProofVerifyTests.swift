import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Lattice
@testable import LatticeLightClient
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew
import VolumeBroker

// H6 (PR #234 review follow-up): a balance proof must carry a self-contained,
// verifiable witness for BOTH balance and nonce. The hard case is a zero-nonce
// account (credited, never signed): its "_nonce_<address>" key does not exist, so
// the witness must include a `.insertion` (non-existence) proof and `verify()` must
// require that evidence rather than defaulting a missing nonce to 0.
//
// This drives the real path: mine block 1 (the coinbase address is credited with
// nonce 0), fetch the node's balance proof, and confirm `LightClientProtocol.verify`
// accepts the genuine proof and rejects balance/nonce tampering.
final class BalanceProofVerifyTests: XCTestCase {
    private struct TemplateResponse: Decodable { let workId: String; let blockHex: String }
    private struct SubmitResponse: Decodable { let accepted: Bool; let height: UInt64? }

    func testZeroNonceBalanceProofIsSelfContainedAndTamperEvident() async throws {
        let payoutKP = CryptoUtils.generateKeyPair()
        let coinbaseAddress = CryptoUtils.createAddress(from: payoutKP.publicKey)

        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey, privateKey: kp.privateKey,
                listenPort: nextTestPort(), storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0, coinbaseAddress: coinbaseAddress
            ),
            genesisConfig: testGenesis()
        )
        try await node.start()
        let port = nextTestPort()
        let (server, token) = try makeAdminRPCServer(node: node, port: port)
        let serverTask = Task { try await server.run() }
        try await waitForRPCServer(port: port)
        addTeardownBlock { [node] in
            serverTask.cancel()
            await node.stop()
            try? FileManager.default.removeItem(at: tmp)
        }

        func post(_ path: String, _ body: [String: Any]) async throws -> Data {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await URLSession.shared.data(for: req).0
        }

        // Mine block 1: the coinbase address is credited (nonce stays 0 — it never signs).
        let template = try JSONDecoder().decode(TemplateResponse.self, from: try await post("/api/chain/template", [:]))
        let submit = try JSONDecoder().decode(SubmitResponse.self, from: try await post("/api/chain/submit-work", ["workId": template.workId, "nonce": 0]))
        XCTAssertTrue(submit.accepted, "nonce=0 meets the max test target; block 1 must seal")

        // Fetch the node's balance proof for the zero-nonce coinbase account.
        guard let proofData = try await node.getBalanceProof(address: coinbaseAddress) else {
            return XCTFail("getBalanceProof returned nil")
        }
        let proof = try JSONDecoder().decode(LightClientProof.self, from: proofData)
        XCTAssertEqual(proof.nonce, 0, "a never-signed coinbase account has nonce 0")
        XCTAssertGreaterThan(proof.balance, 0, "coinbase credited a reward")
        XCTAssertEqual(proof.header.hash, proof.blockHash)
        XCTAssertEqual(proof.header.height, proof.blockHeight)
        XCTAssertEqual(proof.header.stateRoot, proof.stateRoot)
        XCTAssertEqual(proof.header.timestamp, proof.timestamp)

        // (1) The genuine proof verifies end-to-end — incl. the zero-nonce absence witness.
        let ok = await LightClientProtocol.verify(proof)
        XCTAssertTrue(ok, "a genuine zero-nonce balance proof must verify from its own witness")

        // (2) Tampering the balance must be rejected (witness binds the real value).
        let tamperedBalance = LightClientProof(
            blockHash: proof.blockHash, blockHeight: proof.blockHeight, header: proof.header, stateRoot: proof.stateRoot,
            address: proof.address, balance: proof.balance &+ 1, nonce: proof.nonce,
            accountRoot: proof.accountRoot, witness: proof.witness, timestamp: proof.timestamp
        )
        let balanceLie = await LightClientProtocol.verify(tamperedBalance)
        XCTAssertFalse(balanceLie, "a balance-tampered proof must NOT verify")

        // (3) Claiming a non-zero nonce against the absence witness must be rejected
        // (this is the regression the review caught: nonce must not default to 0/be forgeable).
        let tamperedNonce = LightClientProof(
            blockHash: proof.blockHash, blockHeight: proof.blockHeight, header: proof.header, stateRoot: proof.stateRoot,
            address: proof.address, balance: proof.balance, nonce: 5,
            accountRoot: proof.accountRoot, witness: proof.witness, timestamp: proof.timestamp
        )
        let nonceLie = await LightClientProtocol.verify(tamperedNonce)
        XCTAssertFalse(nonceLie, "a nonce-tampered proof must NOT verify against the absence witness")

        // (4) Block metadata is part of the proof envelope. The account witness is
        // checked against a header state root; a proof that lies about the block
        // hash/height/timestamp while keeping the real witness must fail closed.
        let tamperedBlockHash = LightClientProof(
            blockHash: proof.blockHash + "-lie", blockHeight: proof.blockHeight, header: proof.header, stateRoot: proof.stateRoot,
            address: proof.address, balance: proof.balance, nonce: proof.nonce,
            accountRoot: proof.accountRoot, witness: proof.witness, timestamp: proof.timestamp
        )
        let blockHashLie = await LightClientProtocol.verify(tamperedBlockHash)
        XCTAssertFalse(blockHashLie, "a blockHash-tampered proof must NOT verify against the embedded header")

        let tamperedTimestamp = LightClientProof(
            blockHash: proof.blockHash, blockHeight: proof.blockHeight, header: proof.header, stateRoot: proof.stateRoot,
            address: proof.address, balance: proof.balance, nonce: proof.nonce,
            accountRoot: proof.accountRoot, witness: proof.witness, timestamp: proof.timestamp + 1
        )
        let timestampLie = await LightClientProtocol.verify(tamperedTimestamp)
        XCTAssertFalse(timestampLie, "a timestamp-tampered proof must NOT verify against the embedded header")

        // (5) PRESENT-but-zero nonce: the account signs ONE nonce-0 tx, which INSERTS
        // `_nonce_<address>` with stored value 0. Existence must be decided by presence,
        // not value>0 — otherwise the proof requests a `.insertion` (absence) proof for a
        // key that exists and cashew rejects it, 500-ing /api/light/proof. (Regression the
        // review caught.)
        let nexusDir = "Nexus"
        let receiver = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let spendBody = TransactionBody(
            accountActions: [AccountAction(owner: coinbaseAddress, delta: -11), AccountAction(owner: receiver, delta: 10)],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [coinbaseAddress], fee: 1, nonce: 0, chainPath: [nexusDir]
        )
        let submitResult = await node.submitTransactionWithReason(directory: nexusDir, transaction: sign(spendBody, payoutKP))
        if case .failure(let reason) = submitResult {
            return XCTFail("nonce-0 tx from the funded coinbase account was rejected: \(reason)")
        }

        let t2 = try JSONDecoder().decode(TemplateResponse.self, from: try await post("/api/chain/template", [:]))
        let s2 = try JSONDecoder().decode(SubmitResponse.self, from: try await post("/api/chain/submit-work", ["workId": t2.workId, "nonce": 0]))
        XCTAssertTrue(s2.accepted, "block 2 carrying the nonce-0 tx must seal")

        guard let proof2Data = try await node.getBalanceProof(address: coinbaseAddress) else {
            return XCTFail("getBalanceProof returned nil after the nonce-0 tx")
        }
        let proof2 = try JSONDecoder().decode(LightClientProof.self, from: proof2Data)
        XCTAssertEqual(proof2.nonce, 0, "stored nonce after one nonce-0 tx is 0 (key present, value 0)")
        let ok2 = await LightClientProtocol.verify(proof2)
        XCTAssertTrue(ok2, "a present-but-zero nonce proof must verify via .existence (not .insertion)")
    }
}
