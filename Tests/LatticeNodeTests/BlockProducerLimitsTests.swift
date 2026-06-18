import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticeMinerCore
@testable import LatticeNode

/// producer-side limits:
///  - C1: the coinbase caps at Int64.max instead of being dropped when
///        reward + fees overflows the Int64 account-action delta.
///  - C2: block assembly respects spec.maxBlockSize / spec.maxStateGrowth, so the
///        producer never burns PoW on a block the validator would reject for size.
final class BlockProducerLimitsTests: XCTestCase {
    private func store(_ block: Block, to fetcher: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        await storer.flush(to: fetcher)
    }

    private func limitsSpec(maxBlockSize: Int, maxStateGrowth: Int, initialReward: UInt64 = 1024) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: maxStateGrowth,
            maxBlockSize: maxBlockSize,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: initialReward,
            halvingInterval: 210_000,
            retargetWindow: 1_000
        )
    }

    // MARK: - C1

    /// reward + fees exceeds Int64.max ⇒ the coinbase must CAP the payout at
    /// Int64.max and still emit a coinbase, not forfeit the whole reward.
    func testCoinbaseCapsAtMaxInsteadOfDropping() async throws {
        let fetcher = cas()
        // initialReward > Int64.max so rewardAtBlock(1) alone overflows the Int64 delta.
        let spec = limitsSpec(maxBlockSize: 1_000_000, maxStateGrowth: 1_000_000, initialReward: UInt64.max)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 10_000, target: .max, fetcher: fetcher
        )
        try await store(genesis, to: fetcher)

        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let coinbaseOptional = try await BlockProducer.buildCoinbaseTransaction(
            spec: spec,
            identity: identity,
            chainPath: ["Nexus"],
            previousBlock: genesis,
            mempoolTransactions: [],
            fetcher: fetcher
        )
        let coinbase = try XCTUnwrap(
            coinbaseOptional,
            "coinbase must be produced (capped), not dropped, when reward exceeds Int64.max"
        )
        let body = try XCTUnwrap(coinbase.body.node, "coinbase body must resolve")
        let credit = try XCTUnwrap(body.accountActions.first, "coinbase must carry the payout credit")
        XCTAssertEqual(
            credit.delta, Int64.max,
            "coinbase payout must cap at Int64.max, not forfeit the whole reward+fees"
        )
    }

    // MARK: - C2

    /// A mempool whose transactions far exceed spec.maxBlockSize must yield a
    /// produced block that still fits the cap — the producer trims user txs down
    /// to (at most) coinbase-only rather than sealing an oversize, doomed block.
    func testAssemblyRespectsMaxBlockSize() async throws {
        let ts = now() - 10_000

        // 1) Measure the coinbase-only block size for this chain shape (huge cap).
        let fetcher0 = cas()
        let baseSpec = limitsSpec(maxBlockSize: 50_000_000, maxStateGrowth: 50_000_000)
        let baseGenesis = try await BlockBuilder.buildGenesis(
            spec: baseSpec, timestamp: ts, target: .max, fetcher: fetcher0
        )
        try await store(baseGenesis, to: fetcher0)
        let baseProducer = BlockProducer(
            chainState: ChainState.fromGenesis(block: baseGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH),
            mempool: NodeMempool(maxSize: 100),
            fetcher: fetcher0,
            spec: baseSpec,
            chainPath: ["Nexus"],
            batchSize: 10_000,
            timestampOverride: ts
        )
        let baseProduced = try await baseProducer.produceBlock()
        let coinbaseOnly = try XCTUnwrap(baseProduced).block
        let coinbaseOnlySize = try XCTUnwrap(coinbaseOnly.toData()).count

        // 2) Cap that admits the coinbase-only block plus a little headroom.
        let cap = coinbaseOnlySize + 3_000

        // 3) Build many large KV-insert txs whose combined size far exceeds the cap.
        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let bigValue = String(repeating: "x", count: 5_000)
        var txs: [Transaction] = []
        var totalBodyBytes = 0
        for i in 0..<12 {
            let body = TransactionBody(
                accountActions: [],
                actions: [Action(key: "k\(i)", oldValue: nil, newValue: bigValue)],
                depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [address], fee: 0, nonce: UInt64(i)
            )
            totalBodyBytes += body.toData()?.count ?? 0
            txs.append(sign(body, kp))
        }
        XCTAssertGreaterThan(
            totalBodyBytes, cap,
            "test setup: the submitted transactions must together exceed the block cap"
        )

        let fetcher = cas()
        let spec = limitsSpec(maxBlockSize: cap, maxStateGrowth: 50_000_000)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: ts, target: .max, fetcher: fetcher
        )
        try await store(genesis, to: fetcher)
        let mempool = NodeMempool(maxSize: 100)
        for tx in txs { _ = await mempool.add(transaction: tx) }

        let producer = BlockProducer(
            chainState: ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH),
            mempool: mempool,
            fetcher: fetcher,
            spec: spec,
            chainPath: ["Nexus"],
            batchSize: 10_000,
            timestampOverride: ts
        )
        let producedOptional = try await producer.produceBlock()
        let produced = try XCTUnwrap(
            producedOptional,
            "producer must still produce a block (trimmed to fit), not fail"
        )
        let block = produced.block
        let size = try XCTUnwrap(block.toData()).count

        XCTAssertLessThanOrEqual(
            size, spec.maxBlockSize,
            "produced block (\(size) B) must respect maxBlockSize (\(spec.maxBlockSize) B) — assembly must trim to fit"
        )
        let txCount = try await block.transactions.resolve(fetcher: fetcher).node?.allKeys().count ?? 0
        XCTAssertLessThan(
            txCount, 13,
            "producer must trim the 12 oversized user txs to fit (block carried \(txCount) incl. coinbase)"
        )
    }
}
