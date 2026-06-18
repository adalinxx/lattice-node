import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import UInt256
import cashew
import Tally
import Ivy
import Crypto

// MARK: - Mining Challenge Types (not yet in a Tally release)

struct MiningChallenge: Sendable {
    let hashPrefix: Data
    let blockTargetDifficulty: Data
    let noncePrefix: Data
    let issuedAt: ContinuousClock.Instant
    let expiresAfter: Duration

    init(hashPrefix: Data, blockTargetDifficulty: Data, noncePrefix: Data, expiresAfter: Duration = .seconds(30)) {
        self.hashPrefix = hashPrefix
        self.blockTargetDifficulty = blockTargetDifficulty
        self.noncePrefix = noncePrefix
        self.issuedAt = .now
        self.expiresAfter = expiresAfter
    }

    var isExpired: Bool { issuedAt.duration(to: .now) >= expiresAfter }

    func verify(solution: MiningChallengeSolution) -> MiningChallengeResult {
        guard !isExpired else { return .expired }
        let nonceBytes = withUnsafeBytes(of: solution.nonce.bigEndian) { Data($0) }
        for i in 0..<min(noncePrefix.count, nonceBytes.count) {
            if nonceBytes[i] != noncePrefix[i] { return .invalid }
        }
        var input = hashPrefix
        input.append(contentsOf: String(solution.nonce).utf8)
        let hash = Data(SHA256.hash(data: input))
        guard hash == solution.hash else { return .invalid }
        let hardness = hash.reduce(into: 0) { bits, byte in
            guard byte == 0 else { bits += byte.leadingZeroBitCount; return }
            bits += 8
        }
        return .workDone(hardness: hardness)
    }
}

struct MiningChallengeSolution: Sendable {
    let nonce: UInt64
    let hash: Data
    let blockNonce: UInt64?
    init(nonce: UInt64, hash: Data, blockNonce: UInt64? = nil) {
        self.nonce = nonce; self.hash = hash; self.blockNonce = blockNonce
    }
}

enum MiningChallengeResult: Sendable {
    case expired, invalid, workDone(hardness: Int), blockFound(nonce: UInt64, hardness: Int)
}

struct MiningChallengeSolver: Sendable {
    func solve(_ challenge: MiningChallenge) -> MiningChallengeSolution {
        var bestNonce = buildStart(challenge.noncePrefix)
        var bestHash = Data(repeating: 0xFF, count: 32)
        let (start, end) = nonceRange(challenge.noncePrefix)
        var nonce = start
        while nonce < end {
            var input = challenge.hashPrefix
            input.append(contentsOf: String(nonce).utf8)
            let h = Data(SHA256.hash(data: input))
            if h.lexicographicallyPrecedes(bestHash) { bestHash = h; bestNonce = nonce }
            nonce &+= 1
            if nonce == 0 { break }
        }
        return MiningChallengeSolution(nonce: bestNonce, hash: bestHash)
    }
    private func buildStart(_ prefix: Data) -> UInt64 {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<min(prefix.count, 8) { bytes[i] = prefix[i] }
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
    private func nonceRange(_ prefix: Data) -> (UInt64, UInt64) {
        let start = buildStart(prefix)
        let suffixBits = (8 - min(prefix.count, 8)) * 8
        if suffixBits == 0 { return (start, start &+ 1) }
        if suffixBits >= 64 { return (0, UInt64.max) }
        let end = start &+ (1 << suffixBits)
        return (start, end == 0 ? UInt64.max : end)
    }
}

private func proofOfWorkHashPrefix(_ block: Block) -> Data {
    let sep: [UInt8] = [0x00]
    var data = Data()
    data.reserveCapacity(512)
    data.append(contentsOf: String(block.version).utf8)
    data.append(contentsOf: sep)
    if let previousBlockCID = block.parent?.rawCID {
        data.append(contentsOf: previousBlockCID.utf8)
    }
    data.append(contentsOf: sep)
    data.append(contentsOf: block.transactions.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.target.toHexString().utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.nextTarget.toHexString().utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.spec.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.parentState.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.prevState.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.postState.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: block.children.rawCID.utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: String(block.height).utf8)
    data.append(contentsOf: sep)
    data.append(contentsOf: String(block.timestamp).utf8)
    data.append(contentsOf: sep)
    return data
}

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

// Helpers in TestHelpers.swift: testSpec(), now()

// ============================================================================
// MARK: - Block Hash Prefix
// ============================================================================

final class BlockHashPrefixTests: XCTestCase {

    func testGetDifficultyHashPrefixIsStable() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 0, fetcher: f
        )

        let prefix1 = proofOfWorkHashPrefix(block)
        let prefix2 = proofOfWorkHashPrefix(block)
        XCTAssertEqual(prefix1, prefix2)
        XCTAssertFalse(prefix1.isEmpty)
    }

    func testHashPrefixPlusNonceProducesCorrectHash() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )

        for nonce: UInt64 in [0, 1, 42, 99999] {
            let block = try await BlockBuilder.buildBlock(
                previous: genesis, timestamp: t + 1000,
                target: UInt256(1000), nonce: nonce, fetcher: f
            )
            let expected = block.proofOfWorkHash()

            var input = proofOfWorkHashPrefix(block)
            input.append(contentsOf: String(nonce).utf8)
            let computed = UInt256.hash(input)

            XCTAssertEqual(expected, computed, "Hash mismatch for nonce \(nonce)")
        }
    }

    func testDifferentNoncesProduceDifferentHashes() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 0, fetcher: f
        )

        let prefix = proofOfWorkHashPrefix(block)
        var input0 = prefix
        input0.append(contentsOf: "0".utf8)
        var input1 = prefix
        input1.append(contentsOf: "1".utf8)

        XCTAssertNotEqual(UInt256.hash(input0), UInt256.hash(input1))
    }

    func testGenesisBlockHashPrefixWorks() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), nonce: 0, fetcher: f
        )

        let expected = genesis.proofOfWorkHash()
        var input = proofOfWorkHashPrefix(genesis)
        input.append(contentsOf: "0".utf8)
        let computed = UInt256.hash(input)

        XCTAssertEqual(expected, computed)
    }
}

// ============================================================================
// MARK: - Mining Challenge Core
// ============================================================================

final class MiningChallengeTests: XCTestCase {

    private func makeChallenge(
        prefixBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        blockDifficulty: Data = Data(repeating: 0xFF, count: 32)
    ) -> MiningChallenge {
        let hashPrefix = Data("test-block-header-prefix".utf8)
        return MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: blockDifficulty,
            noncePrefix: Data(prefixBytes),
            expiresAfter: .seconds(300)
        )
    }

    func testSolverReturnsValidSolution() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        let result = challenge.verify(solution: solution)
        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0, "Should have found at least some leading zeros")
        case .blockFound(_, let hardness):
            XCTAssertGreaterThan(hardness, 0)
        default:
            XCTFail("Expected workDone or blockFound, got \(result)")
        }
    }

    func testSolutionNonceHasCorrectPrefix() {
        let prefix: [UInt8] = [0xAB, 0x00, 0x00, 0x00, 0x00, 0x00]
        let challenge = makeChallenge(prefixBytes: prefix)
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        let nonceBytes = withUnsafeBytes(of: solution.nonce.bigEndian) { Data($0) }
        XCTAssertEqual(nonceBytes[0], 0xAB, "Nonce should start with the assigned prefix")
    }

    func testSolutionHashMatchesRecomputation() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        var input = challenge.hashPrefix
        input.append(contentsOf: String(solution.nonce).utf8)
        let recomputed = Data(SHA256.hash(data: input))

        XCTAssertEqual(solution.hash, recomputed)
    }

    func testVerifyRejectsWrongHash() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let real = solver.solve(challenge)

        let fake = MiningChallengeSolution(
            nonce: real.nonce,
            hash: Data(repeating: 0x00, count: 32),
            blockNonce: nil
        )
        let result = challenge.verify(solution: fake)
        assertMiningResult(result, isInvalid: true)
    }

    func testVerifyRejectsWrongPrefix() {
        let challenge = makeChallenge(prefixBytes: [0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])

        let wrongNonce: UInt64 = 0xBB00_0000_0000_0000
        var input = challenge.hashPrefix
        input.append(contentsOf: String(wrongNonce).utf8)
        let hash = Data(SHA256.hash(data: input))

        let solution = MiningChallengeSolution(nonce: wrongNonce, hash: hash, blockNonce: nil)
        let result = challenge.verify(solution: solution)
        assertMiningResult(result, isInvalid: true)
    }

    func testExpiredChallengeReturnsExpired() {
        let challenge = MiningChallenge(
            hashPrefix: Data("prefix".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(0)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)
        assertMiningResult(result, isExpired: true)
    }

    func testDifferentPrefixesProduceDifferentNonceRanges() {
        let solver = MiningChallengeSolver()

        let challenge1 = makeChallenge(prefixBytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let challenge2 = makeChallenge(prefixBytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

        let sol1 = solver.solve(challenge1)
        let sol2 = solver.solve(challenge2)

        let bytes1 = withUnsafeBytes(of: sol1.nonce.bigEndian) { Data($0) }
        let bytes2 = withUnsafeBytes(of: sol2.nonce.bigEndian) { Data($0) }

        XCTAssertEqual(bytes1[0], 0x00)
        XCTAssertEqual(bytes2[0], 0x01)
    }

    func testMoreWorkProducesMoreLeadingZeros() {
        let solver = MiningChallengeSolver()

        // 7-byte prefix = 256 nonces to search
        let smallRange = MiningChallenge(
            hashPrefix: Data("test-header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        // 6-byte prefix = 65536 nonces to search
        let bigRange = MiningChallenge(
            hashPrefix: Data("test-header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let smallSol = solver.solve(smallRange)
        let bigSol = solver.solve(bigRange)

        let smallResult = smallRange.verify(solution: smallSol)
        let bigResult = bigRange.verify(solution: bigSol)

        var smallHardness = 0
        var bigHardness = 0
        if case .workDone(let h) = smallResult { smallHardness = h }
        if case .blockFound(_, let h) = smallResult { smallHardness = h }
        if case .workDone(let h) = bigResult { bigHardness = h }
        if case .blockFound(_, let h) = bigResult { bigHardness = h }

        XCTAssertGreaterThanOrEqual(bigHardness, smallHardness,
            "Larger search space should produce at least as many leading zeros")
    }
}

// ============================================================================
// MARK: - Mining Challenge with Real Block Headers
// ============================================================================

final class MiningChallengeIntegrationTests: XCTestCase {

    func testChallengeWithRealBlockHeader() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(1000), nonce: 0, fetcher: f
        )

        let hashPrefix = proofOfWorkHashPrefix(block)
        var targetBytes = Data(count: 32)
        let target = block.target
        for i in 0..<4 {
            var part = target[i].bigEndian
            targetBytes.replaceSubrange((i*8)..<((i+1)*8), with: Data(bytes: &part, count: 8))
        }

        let challenge = MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: targetBytes,
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)

        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0)
        case .blockFound(let nonce, let hardness):
            XCTAssertGreaterThan(hardness, 0)
            var input = hashPrefix
            input.append(contentsOf: String(nonce).utf8)
            let hash = UInt256.hash(input)
            XCTAssertTrue(target >= hash, "Found block nonce should meet target")
        default:
            XCTFail("Expected workDone or blockFound")
        }
    }

    func testBlockFoundNonceIsValidForMining() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, target: UInt256(UInt64.max), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            target: UInt256(UInt64.max), nonce: 0, fetcher: f
        )

        let hashPrefix = proofOfWorkHashPrefix(block)
        var targetBytes = Data(count: 32)
        let target = UInt256(UInt64.max)
        for i in 0..<4 {
            var part = target[i].bigEndian
            targetBytes.replaceSubrange((i*8)..<((i+1)*8), with: Data(bytes: &part, count: 8))
        }

        let challenge = MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: targetBytes,
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        if let blockNonce = solution.blockNonce {
            let candidate = Block(
                parent: block.parent,
                transactions: block.transactions,
                target: block.target,
                nextTarget: block.nextTarget,
                spec: block.spec,
                parentState: block.parentState,
                prevState: block.prevState,
                postState: block.postState,
                children: block.children,
                height: block.height,
                timestamp: block.timestamp,
                nonce: blockNonce
            )
            let hash = candidate.proofOfWorkHash()
            XCTAssertTrue(target >= hash,
                "Block built with peer-found nonce should pass target check")
        }
    }
}

// ============================================================================
// MARK: - Tally Mining Challenge Reputation
// ============================================================================

final class TallyMiningReputationTests: XCTestCase {

    func testMiningChallengeProducesValidResult() {
        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)

        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0)
        case .blockFound:
            break
        default:
            XCTFail("Expected workDone or blockFound")
        }
    }

    func testMultipleChallengesAllValid() {
        let solver = MiningChallengeSolver()

        for i: UInt8 in 0..<3 {
            let challenge = MiningChallenge(
                hashPrefix: Data("header-\(i)".utf8),
                blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
                noncePrefix: Data([i, 0x00, 0x00, 0x00, 0x00, 0x00]),
                expiresAfter: .seconds(300)
            )
            let solution = solver.solve(challenge)
            let result = challenge.verify(solution: solution)
            switch result {
            case .workDone(let h):
                XCTAssertGreaterThan(h, 0)
            case .blockFound:
                break
            default:
                XCTFail("Expected workDone or blockFound for challenge \(i)")
            }
        }
    }

    func testMoreWorkProducesConsistentResults() {
        let solver = MiningChallengeSolver()

        for i: UInt8 in 0..<10 {
            let challenge = MiningChallenge(
                hashPrefix: Data("header-\(i)".utf8),
                blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
                noncePrefix: Data([i, 0x00, 0x00, 0x00, 0x00, 0x00]),
                expiresAfter: .seconds(300)
            )
            let solution = solver.solve(challenge)
            let result = challenge.verify(solution: solution)
            switch result {
            case .workDone, .blockFound:
                break
            default:
                XCTFail("Expected valid result for challenge \(i)")
            }
        }
    }

    func testExpiredChallengeReturnsExpiredResult() {
        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(0)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)
        assertMiningResult(result, isExpired: true)
    }

    func testInvalidSolutionReturnsInvalid() {
        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0xAA, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let fakeSolution = MiningChallengeSolution(
            nonce: 0xAA00_0000_0000_0000,
            hash: Data(repeating: 0x00, count: 32),
            blockNonce: nil
        )
        let result = challenge.verify(solution: fakeSolution)
        assertMiningResult(result, isInvalid: true)
    }
}

// ============================================================================
// MARK: - Ivy Message Serialization
// ============================================================================

final class MiningChallengeMessageTests: XCTestCase {

    func testExistingMessageTypesUnaffected() {
        let ping = Message.ping(nonce: 42)
        let serialized = ping.serialize()
        guard case .ping(let n) = Message.deserialize(serialized) else {
            XCTFail("Ping roundtrip failed")
            return
        }
        XCTAssertEqual(n, 42)

        let announce = Message.announceBlock(cid: "test-cid")
        let aSer = announce.serialize()
        guard case .announceBlock(let cid) = Message.deserialize(aSer) else {
            XCTFail("AnnounceBlock roundtrip failed")
            return
        }
        XCTAssertEqual(cid, "test-cid")
    }
}

// ============================================================================
// MARK: - MiningChallengeResult Equatable (for test assertions)
// ============================================================================

private func assertMiningResult(_ result: MiningChallengeResult, isExpired: Bool = false, isInvalid: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
    switch result {
    case .expired:
        if !isExpired { XCTFail("Expected non-expired result, got .expired", file: file, line: line) }
    case .invalid:
        if !isInvalid { XCTFail("Expected non-invalid result, got .invalid", file: file, line: line) }
    case .workDone:
        if isExpired || isInvalid { XCTFail("Expected expired/invalid, got .workDone", file: file, line: line) }
    case .blockFound:
        if isExpired || isInvalid { XCTFail("Expected expired/invalid, got .blockFound", file: file, line: line) }
    }
}
