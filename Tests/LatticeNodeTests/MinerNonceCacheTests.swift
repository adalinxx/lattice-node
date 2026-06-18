import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

/// UNSTOPPABLE_LATTICE P1 #8: the miner re-resolves the frontier + walks
/// the account trie every iteration just to look up its own nonce/balance.
/// On a large chain each resolve is a fetcher round trip per trie level,
/// which dominates iteration cost and pins state subtrees in memory. The
/// cache slice must (a) skip the resolve when the caller supplies a cached
/// value, and (b) expose an explicit invalidation hook so the reorg
/// handler can drop paths resolved against a no-longer-canonical ancestor
/// before they cause every subsequent coinbase to `nonceGap`.
final class MinerNonceCacheTests: XCTestCase {

    /// Fetcher that always throws. If the cache short-circuit works, the
    /// coinbase build must complete without ever touching the fetcher for
    /// nonce lookup.
    struct FailingFetcher: Fetcher {
        struct Unavailable: Error {}
        func fetch(rawCid: String) async throws -> Data { throw Unavailable() }
    }

    func testCachedLatestNonceSkipsFrontierResolve() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)
        let spec = testSpec()

        // Build a genesis block with a real fetcher so its frontier has a
        // populated .node. We'll then pass a FailingFetcher to
        // buildCoinbaseTransaction — if the cache path works, it never
        // needs to go to the fetcher for nonce resolution.
        let realFetcher = cas()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 10_000,
            target: UInt256.max, fetcher: realFetcher
        )

        // Cache path: caller reports the on-chain nonce is 41. With no
        // miner-signed mempool txs in the block, coinbase nonce must be 42.
        let failing = FailingFetcher()
        let coinbase = try await BlockProducer.buildCoinbaseTransaction(
            spec: spec,
            identity: identity,
            chainPath: ["Nexus"],
            previousBlock: genesis,
            mempoolTransactions: [],
            fetcher: failing,
            cachedLatestNonce: 41
        )

        XCTAssertNotNil(coinbase, "Cache hit must produce a coinbase without hitting the fetcher")
        XCTAssertEqual(coinbase?.body.node?.nonce, 42,
                       "Cached nonce 41 + 1 coinbase slot = 42")
    }

    func testUncachedPathStillWorksOnGenesis() async throws {
        // Sanity check: without a cached nonce, the static builder falls
        // through to resolveLatestMinerNonce, which on genesis's empty
        // state returns nil, and coinbase nonce becomes 0. Proves the
        // short-circuit in buildCoinbaseTransaction only triggers on the
        // cache path.
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)
        let spec = testSpec()
        let fetcher = cas()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 10_000,
            target: UInt256.max, fetcher: fetcher
        )

        let coinbase = try await BlockProducer.buildCoinbaseTransaction(
            spec: spec,
            identity: identity,
            chainPath: ["Nexus"],
            previousBlock: genesis,
            mempoolTransactions: [],
            fetcher: fetcher,
            cachedLatestNonce: nil
        )
        XCTAssertEqual(coinbase?.body.node?.nonce, 0,
                       "Genesis has no miner nonce yet — uncached coinbase nonce must be 0")
    }
}
