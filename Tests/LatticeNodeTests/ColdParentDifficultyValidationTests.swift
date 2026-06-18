import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker

/// MIN-A1: a forged low-difficulty block on a COLD parent path must still be
/// rejected by full validation.
///
/// `isBlockPoWValid` only compares `block.target` against the parent's cached
/// `nextDifficulty` when the parent is in `nextDifficultyByBlockCID`. On a cold
/// parent (never accepted by this process, or pruned from the in-memory cache),
/// that comparison is skipped — the cheap O(1) check passes any block whose own
/// hash clears its CLAIMED difficulty. The defense-in-depth obligation is that
/// `processBlockAndRecoverReorg` -> `lattice.processBlockHeader` ->
/// `validateNextDifficulty` still rejects the forged difficulty once ancestor
/// timestamps resolve.
final class ColdParentDifficultyValidationTests: XCTestCase {

    private func makeNode() async throws -> (node: LatticeNode, tmp: URL) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Genesis difficulty below the trivial `UInt256.max` floor so the
        // rules-required next difficulty retargets to a value that is NOT max —
        // letting the forged candidate claim `max` (trivially clears its own hash)
        // while genuinely violating `parent.nextTarget`. A large-but-non-max
        // target still mines in one hash, so the real producer stays fast.
        // Genesis ~1 target-block-time in the past so B1's solve time lands near
        // the target and the LWMA retarget keeps difficulty near genesis's value
        // (a far-past genesis would inflate the solve time and saturate the
        // difficulty value up to max, collapsing the forgery margin).
        let genesisConfig = GenesisConfig(
            spec: testSpec(),
            timestamp: now() - 1_000,
            target: UInt256.max / UInt256(2)
        )
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false, minPeerKeyBits: 0
            ),
            genesisConfig: genesisConfig
        )
        try await node.start()
        return (node, tmp)
    }

    /// A block that claims a difficulty far easier than the rules require
    /// (`difficulty = UInt256.max`, so any hash trivially clears it) must be
    /// rejected by full validation even when its parent is NOT in the node's
    /// difficulty cache — i.e. the cheap PoW short-circuit cannot catch it.
    func testForgedLowDifficultyOnColdParentRejectedByFullValidation() async throws {
        let (node, tmp) = try await makeNode()
        defer {
            Task { await node.stop() }
            try? FileManager.default.removeItem(at: tmp)
        }

        let nexusDir = "Nexus"
        let networkMaybe = await node.network(for: nexusDir)
        let network = try XCTUnwrap(networkMaybe)
        let fetcher = await network.ivyFetcher
        let chainMaybe = await node.chain(for: nexusDir)
        let chain = try XCTUnwrap(chainMaybe)

        // Parent is the genesis tip: its `nextDifficulty` (= genesis difficulty,
        // max/2) is the rules-required difficulty for the next block.
        let parentCID = await chain.getMainChainTip()
        let parentResolved = try await VolumeImpl<Block>(rawCID: parentCID, node: nil, encryptionInfo: nil)
            .resolve(fetcher: fetcher).node
        let parentBlock = try XCTUnwrap(parentResolved)

        // Sanity: the rules-required difficulty for the next block is the parent's
        // nextDifficulty, and the forged value differs from it.
        let requiredDifficulty = max(parentBlock.nextTarget, ChainSpec.minimumTarget)
        XCTAssertNotEqual(requiredDifficulty, UInt256.max,
                          "fixture precondition: required difficulty must differ from the forged max")

        // Forge a candidate that claims difficulty = max (its hash trivially clears
        // it, so the cheap PoW hash check passes) but whose claimed difficulty
        // violates the chain rules (!= parent.nextTarget).
        let forged = try await BlockBuilder.buildBlock(
            previous: parentBlock,
            timestamp: parentBlock.timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )
        let header = try VolumeImpl<Block>(node: forged)

        // Durably store the forged block's content so validation reaches the
        // difficulty check rather than short-circuiting on a missing root — the
        // rejection under test must be `validateNextDifficulty`, not a fetch miss.
        let storedRoots = await node.storeBlockData(forged, network: network)
        XCTAssertNotNil(storedRoots, "forged block content must be stored so it resolves during validation")

        // COLD PARENT: evict the parent's cached nextDifficulty so the cheap
        // `isBlockPoWValid` comparison is bypassed (simulates a process that never
        // warmed the cache for this ancestor — cold start / pruned window).
        await node.pruneNextTargetCache(keepingCIDs: [])
        XCTAssertNil(node.cachedNextTarget(for: parentCID),
                     "parent must be COLD: not in the difficulty cache")

        // The cheap O(1) check passes on a cold parent (no cache comparison).
        XCTAssertTrue(node.isBlockPoWValid(forged),
                      "cheap PoW check must PASS on a cold parent — that is precisely the gap full validation must close")

        let heightBefore = await chain.getHighestBlockHeight()
        let outcome = await node.processBlockAndRecoverReorg(
            header: header,
            directory: nexusDir,
            fetcher: fetcher,
            resolvedBlock: forged,
            requireDurableResolvedBlock: true
        )

        XCTAssertEqual(outcome, .rejected,
                       "full validateNextDifficulty must reject the forged difficulty on a cold parent")
        let heightAfter = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfter, heightBefore, "rejected forgery must not advance the chain")
        let contains = await chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(contains, "rejected forgery must not be recorded")

        // Control: an otherwise-identical block carrying the RULES-REQUIRED
        // difficulty (with a real PoW nonce) IS accepted on the same cold parent —
        // proving the rejection above was specifically the difficulty value, not a
        // structural/timestamp/fetch artifact of this fixture.
        let honest = try await buildRetargetedTestBlock(
            previous: parentBlock,
            timestamp: parentBlock.timestamp + 1_000,
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertEqual(honest.target, requiredDifficulty,
                       "control block must claim the rules-required difficulty")
        let honestHeader = try VolumeImpl<Block>(node: honest)
        let honestStored = await node.storeBlockData(honest, network: network)
        XCTAssertNotNil(honestStored)
        let honestOutcome = await node.processBlockAndRecoverReorg(
            header: honestHeader,
            directory: nexusDir,
            fetcher: fetcher,
            resolvedBlock: honest,
            requireDurableResolvedBlock: true
        )
        XCTAssertEqual(honestOutcome, .accepted,
                       "the correctly-difficultied block on the same cold parent must be accepted")
    }
}
