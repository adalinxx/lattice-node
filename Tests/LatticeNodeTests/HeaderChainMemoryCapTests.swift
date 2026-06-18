import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import LatticeNodeWire
import Ivy
import Tally
import cashew
import UInt256

// SYN-A1 : the multi-batch / sequential header walk accumulates every
// accepted header into `headers` with no global ceiling. A peer that keeps
// serving valid blocks (an endless stream within the 600s sync timeout) grows
// node memory without bound. `downloadHeaders` now caps the accumulated walk at
// `maxAccumulatedHeaders` and fails closed with `headerWalkTooLarge` rather than
// growing unbounded. Driven through the real `downloadHeaders` entry point: a
// Fetcher serves a chain longer than a small injected cap, and the walk must
// abort once it exceeds the cap instead of collecting the whole chain.

private struct HeaderDataFetcher: Fetcher {
    let dataByCID: [String: Data]
    func fetch(rawCid: String) async throws -> Data {
        guard let data = dataByCID[rawCid] else {
            throw NSError(domain: "HeaderDataFetcher", code: 1)
        }
        return data
    }
}

// A `HeaderBatchSource` that serves a precomputed child chain newest-first from any
// requested CID, bundling each block with its valid root→Mid proof. It deliberately
// caps each served batch at `batchSize` (regardless of the requested count) and never
// includes genesis in a returned batch — so the multi-batch walk keeps looping and the
// accumulated-headers ceiling at the child-path choke point is what must stop it.
private struct ChildProofBatchSource: HeaderBatchSource {
    let blockByCID: [String: Data]
    let proofByCID: [String: Data]
    let parentByCID: [String: String?]
    let genesisCID: String
    let batchSize: Int

    func requestHeaderBatch(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data)] { [] }

    func requestHeaderBatchWithProofs(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data, proof: Data?)] {
        var out: [(cid: String, data: Data, proof: Data?)] = []
        var cid: String? = fromCID
        while let c = cid, c != genesisCID, out.count < batchSize {
            guard let data = blockByCID[c] else { break }
            out.append((c, data, proofByCID[c]))
            cid = parentByCID[c] ?? nil
        }
        return out
    }

    func storeBlock(cid: String, data: Data) async {}
}

final class HeaderChainMemoryCapTests: XCTestCase {
    /// Build an honest chain of `length` blocks (genesis + length-1 children),
    /// returning (tipCID, genesisCID, fetcher serving each block by CID).
    private func buildChain(length: Int) async throws -> (tip: String, genesis: String, fetcher: HeaderDataFetcher) {
        let f = cas()
        let base = now() - 1_000_000
        var dataByCID: [String: Data] = [:]

        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: base, target: UInt256.max, fetcher: f
        )
        let genesisCID = try VolumeImpl<Block>(node: genesis).rawCID
        dataByCID[genesisCID] = genesis.toData()!

        var previous = genesis
        var tipCID = genesisCID
        for i in 1..<length {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: base + Int64(i) * 1_000,
                target: UInt256.max,
                nonce: UInt64(i),
                fetcher: f
            )
            let cid = try VolumeImpl<Block>(node: block).rawCID
            dataByCID[cid] = block.toData()!
            previous = block
            tipCID = cid
        }
        return (tipCID, genesisCID, HeaderDataFetcher(dataByCID: dataByCID))
    }

    func testSequentialWalkBoundsAccumulatedHeaders() async throws {
        // 6-block chain, cap at 3: the walk must abort once it exceeds the cap
        // rather than collecting all 6.
        let chain = try await buildChain(length: 6)
        let headerChain = HeaderChain(maxAccumulatedHeaders: 3)

        do {
            _ = try await headerChain.downloadHeaders(
                peerTipCID: chain.tip,
                fetcher: chain.fetcher,
                genesisBlockHash: chain.genesis,
                localWork: .zero
            )
            XCTFail("an over-cap header walk must fail closed, not accumulate unbounded")
        } catch HeaderChain.HeaderChainError.headerWalkTooLarge(let count) {
            XCTAssertGreaterThan(count, 3, "cap is enforced once accumulation exceeds the ceiling")
            XCTAssertLessThanOrEqual(count, 6, "the walk aborts near the cap, not after draining the whole chain")
        }
    }

    func testUnderCapWalkStillCompletes() async throws {
        // Same chain, cap comfortably above the chain length: the walk completes
        // and returns every header. Proves the cap only trips on over-long walks.
        let chain = try await buildChain(length: 6)
        let headerChain = HeaderChain(maxAccumulatedHeaders: 1_000)
        let headers = try await headerChain.downloadHeaders(
            peerTipCID: chain.tip,
            fetcher: chain.fetcher,
            genesisBlockHash: chain.genesis,
            localWork: .zero
        )
        // The sequential walk stops at the genesis boundary (genesis is the local
        // base, not part of the downloaded delta), so a 6-block chain yields the
        // 5 non-genesis headers. The point is the walk completes without tripping
        // the cap. Headers are returned oldest-first after the internal reverse.
        XCTAssertEqual(headers.count, 5, "a within-cap walk collects the full non-genesis delta")
        XCTAssertEqual(headers.last?.cid, chain.tip)
    }

    /// Build a Mid (child) chain of `length` blocks and, for each non-genesis block,
    /// a real root→Mid proof envelope (a Nexus root that embeds that exact Mid
    /// block). Returns the tip/genesis CIDs and a `HeaderBatchSource` serving
    /// proof-carrying batches.
    private func buildChildChainWithProofs(length: Int, batchSize: Int) async throws
        -> (tip: String, genesis: String, source: ChildProofBatchSource) {
        let f = cas()
        let base = now() - 1_000_000

        let midGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Mid"), timestamp: base, target: UInt256.max, fetcher: f
        )
        let genesisCID = try VolumeImpl<Block>(node: midGenesis).rawCID

        var blockByCID: [String: Data] = [genesisCID: midGenesis.toData()!]
        var proofByCID: [String: Data] = [:]
        var parentByCID: [String: String?] = [genesisCID: nil]

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: base, target: UInt256.max, fetcher: f
        )

        var previous = midGenesis
        var previousCID = genesisCID
        var tipCID = genesisCID
        for i in 1..<length {
            // Mid blocks don't mine independently (nonce 0); difficulty max so PoW is trivial.
            let midBlock = try await BlockBuilder.buildBlock(
                previous: previous, timestamp: base + Int64(i) * 1_000,
                target: UInt256.max, nonce: 0, fetcher: f
            )
            let midCID = try VolumeImpl<Block>(node: midBlock).rawCID
            await f.store(rawCid: midCID, data: midBlock.toData()!)

            // A real Nexus root that embeds this exact Mid block — the PoW anchor
            // a relayer would prove against.
            let nexusBlock = try await BlockBuilder.buildBlock(
                previous: nexusGenesis, children: ["Mid": midBlock],
                timestamp: base + Int64(i) * 1_000, target: UInt256.max,
                nonce: UInt64(i), fetcher: f
            )
            let nexusHeader = try VolumeImpl<Block>(node: nexusBlock)
            let storer = _CollectingStorer()
            try nexusHeader.storeRecursively(storer: storer)
            for (cid, data) in storer.entries { await f.store(rawCid: cid, data: data) }

            let proof = try await ChildBlockProof.generate(
                rootHeader: nexusHeader, childDirectory: "Mid", fetcher: f
            )
            blockByCID[midCID] = midBlock.toData()!
            proofByCID[midCID] = ChildBlockProofEnvelope.serialize([proof])
            parentByCID[midCID] = previousCID

            previous = midBlock
            previousCID = midCID
            tipCID = midCID
        }

        let source = ChildProofBatchSource(
            blockByCID: blockByCID, proofByCID: proofByCID, parentByCID: parentByCID,
            genesisCID: genesisCID, batchSize: batchSize
        )
        return (tipCID, genesisCID, source)
    }

    // SYN-A1, child path: the proof-carrying child-chain walk
    // (`downloadChildHeadersWithProofs`) accumulates a header AND a verified proof per
    // accepted block into `headers`/`proofs` with no global ceiling. A peer feeding an
    // endless proof-carrying batch stream grows BOTH dicts without bound. Driven through
    // the real `downloadHeaders` entry point with `expectedChildPath` + a ChainNetwork
    // stand-in serving full, never-reaching-genesis batches: the walk must fail closed
    // with `headerWalkTooLarge` once accumulation crosses an injected small cap.
    func testChildProofWalkBoundsAccumulatedHeaders() async throws {
        // 6-block child chain. Serve batches of 4 (over the cap of 3) that never include
        // genesis, so the first batch leaves the walk un-stopped and the cap trips.
        let chain = try await buildChildChainWithProofs(length: 6, batchSize: 4)
        let headerChain = HeaderChain(maxAccumulatedHeaders: 3)
        let peer = PeerID(publicKey: "syn-a1-child-peer")

        do {
            _ = try await headerChain.downloadHeaders(
                peerTipCID: chain.tip,
                fetcher: HeaderDataFetcher(dataByCID: [:]),
                genesisBlockHash: chain.genesis,
                localWork: .zero,
                network: chain.source,
                sourcePeer: peer,
                expectedChildPath: ["Mid"]
            )
            XCTFail("an over-cap child-proof walk must fail closed, not accumulate unbounded")
        } catch HeaderChain.HeaderChainError.headerWalkTooLarge(let count) {
            XCTAssertGreaterThan(count, 3, "child-path cap is enforced once accumulation exceeds the ceiling")
        }
    }

    /// Same child chain, cap comfortably above its length: the proof-carrying walk
    /// completes and collects every non-genesis header (with its proof retained).
    /// Proves the child-path cap trips only on over-long walks, not honest ones.
    func testChildProofWalkUnderCapCompletes() async throws {
        let chain = try await buildChildChainWithProofs(length: 6, batchSize: 1_000)
        let headerChain = HeaderChain(maxAccumulatedHeaders: 1_000)
        let peer = PeerID(publicKey: "syn-a1-child-peer-undercap")

        let headers = try await headerChain.downloadHeaders(
            peerTipCID: chain.tip,
            fetcher: HeaderDataFetcher(dataByCID: [:]),
            genesisBlockHash: chain.genesis,
            localWork: .zero,
            network: chain.source,
            sourcePeer: peer,
            expectedChildPath: ["Mid"]
        )
        XCTAssertEqual(headers.count, 5, "a within-cap child walk collects the full non-genesis delta")
        XCTAssertEqual(headers.last?.cid, chain.tip)
        let proofs = await headerChain.acceptedProofs
        XCTAssertEqual(proofs.count, 5, "each accepted child header retains its verified proof")
    }
}
