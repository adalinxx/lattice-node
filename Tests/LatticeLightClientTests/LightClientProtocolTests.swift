import Foundation
import Lattice
import LatticeLightClient
import XCTest
import cashew

@MainActor
final class LightClientProtocolTests: XCTestCase {
    func testValidAccountProof() async throws {
        let proof = try await makeProof(balance: 42, nonce: 7)
        let blockCID = await LightClientProtocol.verify(proof)

        XCTAssertEqual(blockCID, try BlockHeader(node: proof.block).rawCID)
    }

    func testTamperedWitnessIsRejected() async throws {
        let proof = try await makeProof(balance: 42, nonce: 7)
        var witness = proof.witness
        let stateRoot = proof.block.postState.rawCID
        let index = try XCTUnwrap(witness.firstIndex { $0.cid != stateRoot })
        var data = try XCTUnwrap(witness[index].rawData)
        data[data.startIndex] ^= 1
        witness[index] = .init(cid: witness[index].cid, data: data)
        let valid = await LightClientProtocol.verify(copy(proof, witness: witness))

        XCTAssertNil(valid)
    }

    func testWitnessCannotBeReboundToAnotherBlockState() async throws {
        let proof = try await makeProof(balance: 42, nonce: 7)
        let original = proof.block
        let rebound = Block(
            version: original.version,
            parent: original.parent,
            transactions: original.transactions,
            target: original.target,
            nextTarget: original.nextTarget,
            spec: original.spec,
            parentState: original.parentState,
            prevState: original.prevState,
            postState: LatticeState.emptyHeader,
            children: original.children,
            height: original.height,
            timestamp: original.timestamp,
            nonce: original.nonce
        )
        let valid = await LightClientProtocol.verify(copy(proof, block: rebound))

        XCTAssertNil(valid)
    }

    func testMissingWitnessNodeIsRejected() async throws {
        let proof = try await makeProof(balance: 42, nonce: 7)
        let witness = proof.witness.filter {
            $0.cid == proof.block.postState.rawCID
        }
        let valid = await LightClientProtocol.verify(copy(proof, witness: witness))

        XCTAssertNil(valid)
    }

    func testDuplicateWitnessCIDIsRejected() async throws {
        let proof = try await makeProof(balance: 42, nonce: 7)
        let duplicate = try XCTUnwrap(proof.witness.first)
        let valid = await LightClientProtocol.verify(copy(
            proof,
            witness: proof.witness + [duplicate]
        ))

        XCTAssertNil(valid)
    }

    func testAbsentBalanceAndNonceProofIsValid() async throws {
        let proof = try await makeProof(balance: nil, nonce: nil)
        let valid = await LightClientProtocol.verify(proof)

        XCTAssertNotNil(valid)
    }

    func testAbsentNonceProofIsValidAndCannotHideExistingNonce() async throws {
        let absent = try await makeProof(balance: 42, nonce: nil)
        let absentValid = await LightClientProtocol.verify(absent)
        XCTAssertNotNil(absentValid)

        let present = try await makeProof(balance: 42, nonce: 7)
        let hiddenNonceValid = await LightClientProtocol.verify(copy(present, nonce: 0))
        XCTAssertNil(hiddenNonceValid)
    }

    func testCLIStdinFileAndExitCodes() async throws {
        let proof = try await makeProof(balance: 42, nonce: nil)
        let encoded = try JSONEncoder().encode(proof)
        let blockCID = try BlockHeader(node: proof.block).rawCID

        let stdin = try runVerifier(stdin: encoded)
        XCTAssertEqual(stdin.status, 0)
        XCTAssertEqual(stdin.stdout, "valid \(blockCID)\n")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("proof.json")
        try encoded.write(to: file)
        let fromFile = try runVerifier(arguments: ["--file", file.path])
        XCTAssertEqual(fromFile.status, 0)
        XCTAssertEqual(fromFile.stdout, "valid \(blockCID)\n")

        let invalid = try runVerifier(stdin: try JSONEncoder().encode(copy(proof, balance: 43)))
        XCTAssertEqual(invalid.status, 2)
        XCTAssertEqual(invalid.stderr, "invalid\n")

        let malformed = try runVerifier(stdin: Data("{".utf8))
        XCTAssertEqual(malformed.status, 1)
        XCTAssertTrue(malformed.stderr.hasPrefix("error: "))

        let usage = try runVerifier(arguments: ["--unknown"])
        XCTAssertEqual(usage.status, 64)
        XCTAssertEqual(usage.stderr, "usage: lattice-proof-verifier [--file proof.json]\n")

        let help = try runVerifier(arguments: ["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertEqual(help.stdout, "usage: lattice-proof-verifier [--file proof.json]\n")
    }

    private func makeProof(balance: UInt64?, nonce: UInt64?) async throws -> LightClientProof {
        var accounts = AccountState()
        if let balance {
            accounts = try accounts.inserting(key: "alice", value: balance)
        }
        if let nonce {
            accounts = try accounts.inserting(
                key: AccountStateHeader.nonceTrackingKey("alice"),
                value: nonce
            )
        }
        let accountHeader = try AccountStateHeader(node: accounts)
        let empty = try XCTUnwrap(LatticeState.emptyHeader.node)
        let state = empty.set(properties: ["accountState": accountHeader])
        let stateHeader = try LatticeStateHeader(node: state)
        let store = ProofStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: store)
        try await accountHeader.storeRecursively(storer: store as any Storer)
        try await store.store(entries: [stateHeader.rawCID: try XCTUnwrap(state.toData())])
        let witness = try await LightClientProtocol.collectAccountWitness(
            state: state,
            stateRoot: stateHeader.rawCID,
            address: "alice",
            balanceExists: balance != nil,
            nonceExists: nonce != nil,
            fetcher: store
        )
        let base = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1,
                halvingInterval: 10_000
            ),
            timestamp: 1_000,
            target: .max,
            fetcher: store
        )
        let block = Block(
            version: base.version,
            parent: base.parent,
            transactions: base.transactions,
            target: base.target,
            nextTarget: base.nextTarget,
            spec: base.spec,
            parentState: base.parentState,
            prevState: base.prevState,
            postState: stateHeader,
            children: base.children,
            height: base.height,
            timestamp: base.timestamp,
            nonce: base.nonce
        )
        return LightClientProof(
            block: block,
            address: "alice",
            balance: balance ?? 0,
            nonce: nonce ?? 0,
            accountRoot: witness.accountRoot,
            witness: witness.witness
        )
    }

    private func copy(
        _ proof: LightClientProof,
        block: Block? = nil,
        balance: UInt64? = nil,
        nonce: UInt64? = nil,
        witness: [LightClientProof.WitnessNode]? = nil
    ) -> LightClientProof {
        LightClientProof(
            block: block ?? proof.block,
            address: proof.address,
            balance: balance ?? proof.balance,
            nonce: nonce ?? proof.nonce,
            accountRoot: proof.accountRoot,
            witness: witness ?? proof.witness
        )
    }

    private func runVerifier(
        arguments: [String] = [],
        stdin: Data? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let binary = repository.appendingPathComponent(
            ".build/\(configuration)/lattice-proof-verifier"
        )
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        if let stdin {
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private actor ProofStore: Fetcher, Storer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries newEntries: [String: Data]) async throws {
        entries.merge(newEntries) { _, new in new }
    }
}
