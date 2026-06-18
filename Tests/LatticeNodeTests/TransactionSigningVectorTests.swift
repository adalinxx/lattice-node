import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew

private struct TransactionSigningVector: Decodable {
    let name: String
    let domain: String
    let signerPrivateKey: String
    let signerPublicKey: String
    let signerAddress: String
    let recipientAddress: String
    let amount: Int64
    let fee: UInt64
    let nonce: UInt64
    let chainPath: [String]
    let bodyCID: String
    let signingPreimage: String
    let signature: String
    let negativeChainPath: [String]
    let negativeNonce: UInt64
}

final class TransactionSigningVectorTests: XCTestCase {
    func testKnownAnswerVectorsMatchImplementation() throws {
        for vector in try loadVectors() {
            let signer = try XCTUnwrap(Wallet.fromPrivateKey(vector.signerPrivateKey), vector.name)
            XCTAssertEqual(TransactionSigning.domain, vector.domain, vector.name)
            XCTAssertEqual(signer.publicKeyHex, vector.signerPublicKey, vector.name)
            XCTAssertEqual(signer.address, vector.signerAddress, vector.name)

            let body = body(from: vector, chainPath: vector.chainPath, nonce: vector.nonce)
            let header = try HeaderImpl<TransactionBody>(node: body)
            XCTAssertEqual(header.rawCID, vector.bodyCID, vector.name)
            XCTAssertEqual(TransactionSigning.preimage(body: body, bodyCID: header.rawCID), vector.signingPreimage, vector.name)
            let generatedSignature = try XCTUnwrap(TransactionSigning.sign(body: body, bodyCID: header.rawCID, privateKeyHex: vector.signerPrivateKey), vector.name)
            XCTAssertTrue(TransactionSigning.verify(body: body, bodyCID: header.rawCID, signature: generatedSignature, publicKeyHex: vector.signerPublicKey), vector.name)
            XCTAssertTrue(TransactionSigning.verify(body: body, bodyCID: header.rawCID, signature: vector.signature, publicKeyHex: vector.signerPublicKey), vector.name)
        }
    }

    func testCrossDomainVectorSignatureRejectsDifferentChainPath() throws {
        for vector in try loadVectors() {
            let body = body(from: vector, chainPath: vector.negativeChainPath, nonce: vector.nonce)
            let header = try HeaderImpl<TransactionBody>(node: body)
            XCTAssertFalse(TransactionSigning.verify(body: body, bodyCID: header.rawCID, signature: vector.signature, publicKeyHex: vector.signerPublicKey), vector.name)
        }
    }

    func testVectorSignatureRejectsDifferentNonce() throws {
        for vector in try loadVectors() {
            let body = body(from: vector, chainPath: vector.chainPath, nonce: vector.negativeNonce)
            let header = try HeaderImpl<TransactionBody>(node: body)
            XCTAssertFalse(TransactionSigning.verify(body: body, bodyCID: header.rawCID, signature: vector.signature, publicKeyHex: vector.signerPublicKey), vector.name)
        }
    }

    func testVectorSignatureRejectsLegacyRawCIDMessage() throws {
        for vector in try loadVectors() {
            XCTAssertFalse(CryptoUtils.verify(message: vector.bodyCID, signature: vector.signature, publicKeyHex: vector.signerPublicKey), vector.name)
        }
    }

    func testProductionTransactionSigningIsCentralizedInEnvelopeHelper() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = root.appendingPathComponent("Sources/LatticeNode")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) ?? FileManager.default.enumerator(atPath: sources.path)!
        var findings: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative == "Sources/LatticeNode/Network/DNSSeeds.swift" {
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("CryptoUtils.sign(") {
                findings.append(relative)
            }
        }

        XCTAssertEqual(findings, [], "Production transaction signing must go through Lattice.TransactionSigning so the lattice-tx-v1 envelope is applied.")
    }

    private func loadVectors() throws -> [TransactionSigningVector] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/testing/transaction-signing-vectors.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TransactionSigningVector].self, from: data)
    }

    private func body(from vector: TransactionSigningVector, chainPath: [String], nonce: UInt64) -> TransactionBody {
        TransactionBody(
            accountActions: [
                AccountAction(owner: vector.signerAddress, delta: -Int64(vector.fee) - vector.amount),
                AccountAction(owner: vector.recipientAddress, delta: vector.amount)
            ],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [vector.signerAddress],
            fee: vector.fee,
            nonce: nonce,
            chainPath: chainPath
        )
    }
}
