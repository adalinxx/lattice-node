import Foundation
import Lattice
import LatticeNodeWire
import Ivy
import Tally
import cashew
import UInt256

/// The narrow slice of `ChainNetwork` the multi-batch download walk depends on:
/// request a batch (with or without proofs) from a peer and store each accepted
/// block to CAS. Extracted as a seam so the walk's memory cap can be driven through
/// the real `downloadHeaders` entry point with an over-cap batch stream, without a
/// live Ivy stack. `ChainNetwork` conforms with its existing methods unchanged.
public protocol HeaderBatchSource: Sendable {
    func requestHeaderBatch(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data)]
    func requestHeaderBatchWithProofs(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data, proof: Data?)]
    func storeBlock(cid: String, data: Data) async
    func storeSyncedBlock(cid: String, data: Data) async
}

public extension HeaderBatchSource {
    func storeSyncedBlock(cid: String, data: Data) async {
        await storeBlock(cid: cid, data: data)
    }
}

public actor HeaderChain {
    private var headers: [SyncBlockHeader] = []
    private var cumulativeWork: UInt256 = .zero
    /// Verified ChildBlockProof (serialized) per accepted child header CID. Populated
    /// only on the proof-carrying (child-chain) path; consumed after the synced blocks
    /// are applied to fold each block's inherited (securing) work into fork choice.
    private var proofs: [String: Data] = [:]
    private let fetchTimeout: Duration

    /// Global ceiling on headers accumulated across the entire multi-batch walk.
    /// A peer can feed an endless stream of full (`maxHeaderBatchSize`) batches —
    /// or an endless sequential block stream — within the 600s sync timeout;
    /// without a cap, `headers` (and, on the child path, `proofs`) grow unbounded
    /// in memory. We bound the walk to a generous multiple of one batch — far
    /// beyond any realistic chain delta yet finite — and fail closed
    /// (`headerWalkTooLarge`) rather than OOM. Single choke point for all three
    /// download paths.
    public static let defaultMaxAccumulatedHeaders = ChainNetwork.maxHeaderBatchSize * 1_000
    /// Max candidate peers tried per batch on the source-agnostic child walk. Bounds
    /// the per-batch timeout cost so a Sybil-filled peer set can't burn the sync
    /// window (audit M2) while keeping enough redundancy that one flaky peer is fine.
    static let maxSyncCandidatePeers = 5
    let maxAccumulatedHeaders: Int

    public init(
        fetchTimeout: Duration = .seconds(30),
        maxAccumulatedHeaders: Int = HeaderChain.defaultMaxAccumulatedHeaders
    ) {
        self.fetchTimeout = fetchTimeout
        self.maxAccumulatedHeaders = maxAccumulatedHeaders
    }

    /// Serialized, already-verified proof envelopes keyed by block CID
    /// (child-chain sync only).
    public var acceptedProofs: [String: Data] { proofs }

    static func headersByInheritingMissingSpecCIDs(
        _ headers: [SyncBlockHeader],
        initialSpecCID: String?
    ) -> [SyncBlockHeader] {
        var inheritedSpecCID = initialSpecCID?.isEmpty == true ? nil : initialSpecCID
        return headers.map { header in
            let headerSpecCID = header.specCID?.isEmpty == true ? nil : header.specCID
            let effectiveSpecCID = headerSpecCID ?? inheritedSpecCID
            if let effectiveSpecCID {
                inheritedSpecCID = effectiveSpecCID
            }
            guard headerSpecCID == nil, effectiveSpecCID != nil else {
                return header
            }
            return SyncBlockHeader(
                cid: header.cid,
                height: header.height,
                previousBlockCID: header.previousBlockCID,
                target: header.target,
                nextTarget: header.nextTarget,
                timestamp: header.timestamp,
                specCID: effectiveSpecCID,
                spec: header.spec
            )
        }
    }

    public enum HeaderChainError: Error {
        case fetchFailed(String)
        case invalidPoW(String)
        case cidMismatch(expected: String, actual: String)
        case chainContinuityBroken(expected: String, got: String?)
        case insufficientWork
        case cancelled
        /// The accumulated header walk exceeded `maxAccumulatedHeaders` — a peer
        /// fed more headers than any plausible chain delta. Fail closed instead
        /// of growing memory without bound.
        case headerWalkTooLarge(Int)
    }

    static func acceptedHeader(expectedCID: String, receivedCID: String, data: Data) throws -> (block: Block, header: SyncBlockHeader) {
        guard receivedCID == expectedCID else {
            throw HeaderChainError.chainContinuityBroken(expected: expectedCID, got: receivedCID)
        }
        guard let block = Block(data: data) else {
            throw HeaderChainError.fetchFailed(expectedCID)
        }
        let actualCID = try VolumeImpl<Block>(node: block).rawCID
        guard actualCID == expectedCID else {
            throw HeaderChainError.cidMismatch(expected: expectedCID, actual: actualCID)
        }
        let diffHash = block.proofOfWorkHash()
        guard block.validateProofOfWork(nexusHash: diffHash) else {
            throw HeaderChainError.invalidPoW(expectedCID)
        }
        return (
            block,
            SyncBlockHeader(
                cid: expectedCID,
                height: block.height,
                previousBlockCID: block.parent?.rawCID,
                target: block.target,
                nextTarget: block.nextTarget,
                timestamp: block.timestamp,
                specCID: block.spec.rawCID.isEmpty ? nil : block.spec.rawCID,
                spec: block.spec.node
            )
        )
    }

    /// Anchored accept for a CHILD-chain header: the block's PoW lives on its
    /// cross-chain path to the PoW root, not its own hash. The bundled proof must
    /// (1) bind to this chain's carrier-relative directory path, (2) reconstruct
    /// the carrier root whose hash the child's target clears, and (3) connect root → this block.
    /// The carrier root does not need to be canonical for its own chain. Any
    /// missing/invalid proof envelope throws `invalidPoW` — a child header is never
    /// accepted self-hashed. Returns a verified proof envelope so the caller can
    /// record every inherited-work path. `isAcceptedRoot` is retained for source
    /// compatibility and intentionally ignored; canonicality is fork-choice state,
    /// not a proof/work admission condition.
    static func acceptedChildHeader(
        expectedCID: String,
        receivedCID: String,
        data: Data,
        proofData: Data?,
        expectedChildPath: [String],
        isAcceptedRoot _: @Sendable (String, UInt64) async -> Bool = { _, _ in true }
    ) async throws -> (block: Block, header: SyncBlockHeader, proofEnvelope: Data) {
        guard receivedCID == expectedCID else {
            throw HeaderChainError.chainContinuityBroken(expected: expectedCID, got: receivedCID)
        }
        guard let block = Block(data: data) else {
            throw HeaderChainError.fetchFailed(expectedCID)
        }
        let actualCID = try VolumeImpl<Block>(node: block).rawCID
        guard actualCID == expectedCID else {
            throw HeaderChainError.cidMismatch(expected: expectedCID, actual: actualCID)
        }
        guard let proofData,
              let proofs = ChildBlockProofEnvelope.deserialize(proofData),
              !proofs.isEmpty else {
            throw HeaderChainError.invalidPoW(expectedCID)
        }

        var verified: [ChildBlockProof] = []
        for proof in proofs {
            // Bind each proof to this chain's path from the actual PoW carrier.
            // The carrier may be Nexus or a verified descendant, so the proof path
            // is allowed to be a suffix of this chain's full root-exclusive path.
            guard MinedChildBlockSelection.proofPathTargetsExpectedChildPath(
                    proof.directoryPath,
                    expectedChildPath: expectedChildPath
                  ),
                  let root = await proof.anchorRoot(),
                  block.validateProofOfWork(nexusHash: root.hash),
                  await proof.verify(rootHash: root.hash, childCID: expectedCID),
                  let parentPrevState = await proof.committingParentPrevStateCID(),
                  parentPrevState == block.parentState.rawCID else { continue }
            verified.append(proof)
        }
        guard !verified.isEmpty else {
            throw HeaderChainError.invalidPoW(expectedCID)
        }
        return (
            block,
            SyncBlockHeader(
                cid: expectedCID,
                height: block.height,
                previousBlockCID: block.parent?.rawCID,
                target: block.target,
                nextTarget: block.nextTarget,
                timestamp: block.timestamp,
                specCID: block.spec.rawCID.isEmpty ? nil : block.spec.rawCID,
                spec: block.spec.node
            ),
            ChildBlockProofEnvelope.serialize(verified)
        )
    }

    /// Download headers using a single bulk request to `network`, falling back
    /// to sequential CAS fetching if the peer doesn't respond or doesn't support it.
    ///
    /// `expectedChildPath` (non-nil ⇒ this is a CHILD chain) switches the bulk path to
    /// the proof-carrying `getHeaders2` request and verifies each header's anchored PoW
    /// against its bundled proof. A child chain has no self-hash fallback: if proofs
    /// can't be obtained the sync fails closed rather than accepting unanchored blocks.
    public func downloadHeaders(
        peerTipCID: String,
        fetcher: Fetcher,
        genesisBlockHash: String,
        localWork: UInt256,
        knownBlockCIDs: Set<String> = [],
        network: (any HeaderBatchSource)? = nil,
        sourcePeer: PeerID? = nil,
        candidatePeers: [PeerID] = [],
        expectedChildPath: [String]? = nil,
        isAcceptedRoot _: (@Sendable (String, UInt64) async -> Bool)? = nil,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> [SyncBlockHeader] {
        // Child chain: proof-carrying bulk path ONLY — never the self-hash sequential
        // fallback. If we can't run it (no source peer), fail closed rather than
        // risk adopting unanchored child blocks.
        if let expectedChildPath {
            // Source-agnostic candidate set: the hinted source peer first (locality),
            // then every other connected same-chain peer as a redundant fallback.
            // Authority is the per-block `ChildBlockProof` (PoW-anchored), so peers
            // are interchangeable byte providers — fail closed only when NO peer can
            // serve a valid proof, never because one designated peer was absent or
            // returned empty. (consensus-fork-choice.md: "the source does not make the
            // data authoritative"; SOTA: Bitcoin IBD PR#2964 dropped single-source.)
            var peerOrder: [PeerID] = []
            if let sourcePeer { peerOrder.append(sourcePeer) }
            for p in candidatePeers where !peerOrder.contains(where: { $0.publicKey == p.publicKey }) {
                peerOrder.append(p)
            }
            // Bound the set actually tried per batch: an empty/slow peer costs a full
            // request timeout, so an unbounded candidate list (e.g. a Sybil-filled
            // peer set) would let an attacker burn the whole sync window. Cap to a
            // small constant of (already Tally-allowed) peers — enough redundancy
            // without an amplification surface (audit M2). The source hint stays first.
            let triedPeers = Array(peerOrder.prefix(Self.maxSyncCandidatePeers))
            guard let network, !triedPeers.isEmpty else {
                throw HeaderChainError.invalidPoW("child sync requires at least one connected peer")
            }
            return try await downloadChildHeadersWithProofs(
                peerTipCID: peerTipCID, network: network, peers: triedPeers,
                genesisBlockHash: genesisBlockHash, knownBlockCIDs: knownBlockCIDs,
                expectedChildPath: expectedChildPath, progress: progress
            )
        }
        // Bulk fetch: loop in batches until genesis or a locally-known block.
        // Each batch's bytes are stored to CAS immediately so the subsequent
        // syncSnapshot resolves blocks locally without re-fetching.
        if let network, let peer = sourcePeer {
            headers = []
            cumulativeWork = .zero
            var nextCID = peerTipCID
            var totalHeight: UInt64 = 0

            while !Task.isCancelled {
                let bulk = await network.requestHeaderBatch(
                    fromCID: nextCID, count: ChainNetwork.maxHeaderBatchSize, peer: peer
                )
                guard !bulk.isEmpty else { break }

                if totalHeight == 0 {
                    totalHeight = Block(data: bulk.first?.data ?? Data())?.height ?? 0
                }

                let accepted = try await acceptHeaderBatch(
                    bulk,
                    startingAt: nextCID,
                    totalHeight: totalHeight,
                    genesisBlockHash: genesisBlockHash,
                    knownBlockCIDs: knownBlockCIDs,
                    progress: progress,
                    store: { cid, data in
                        await network.storeSyncedBlock(cid: cid, data: data)
                    }
                )

                if accepted.reachedStop { break }
                guard headers.count <= self.maxAccumulatedHeaders else {
                    throw HeaderChainError.headerWalkTooLarge(headers.count)
                }
                guard let lastParent = accepted.nextCID,
                      !lastParent.isEmpty,
                      lastParent != genesisBlockHash else { break }
                nextCID = lastParent
            }

            if Task.isCancelled { throw HeaderChainError.cancelled }

            if !headers.isEmpty {
                headers.reverse()
                return headers
            }
        }
        // Fallback: sequential walk
        return try await downloadHeadersSequential(
            peerTipCID: peerTipCID, fetcher: fetcher,
            genesisBlockHash: genesisBlockHash, knownBlockCIDs: knownBlockCIDs, progress: progress
        )
    }

    func acceptHeaderBatch(
        _ bulk: [(cid: String, data: Data)],
        startingAt nextCID: String,
        totalHeight: UInt64,
        genesisBlockHash: String,
        knownBlockCIDs: Set<String>,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil,
        store: @Sendable (String, Data) async -> Void
    ) async throws -> (reachedStop: Bool, nextCID: String?) {
        var expectedCID = nextCID
        var lastParent: String?

        for (cid, data) in bulk {
            let accepted = try Self.acceptedHeader(expectedCID: expectedCID, receivedCID: cid, data: data)
            let block = accepted.block
            cumulativeWork = saturatingWorkSum(cumulativeWork, workForTarget(block.target))
            headers.append(accepted.header)
            lastParent = accepted.header.previousBlockCID
            await progress?(totalHeight - block.height, totalHeight)
            await store(accepted.header.cid, data)

            if let parentCID = block.parent?.rawCID, knownBlockCIDs.contains(parentCID) {
                return (true, parentCID)
            }
            if accepted.header.cid == genesisBlockHash {
                return (true, block.parent?.rawCID)
            }
            guard let parentCID = block.parent?.rawCID else {
                return (true, nil)
            }
            expectedCID = parentCID
        }

        return (false, lastParent)
    }

    /// Bulk child-chain header download over the proof-carrying `getHeaders2` request.
    /// Each header is anchored-verified against its bundled proof; verified proofs are
    /// retained (keyed by CID) for inherited-weight recording after apply. No self-hash
    /// fallback — an empty/old-peer response simply yields no headers (fail closed).
    private func downloadChildHeadersWithProofs(
        peerTipCID: String,
        network: any HeaderBatchSource,
        peers: [PeerID],
        genesisBlockHash: String,
        knownBlockCIDs: Set<String>,
        expectedChildPath: [String],
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws -> [SyncBlockHeader] {
        headers = []
        cumulativeWork = .zero
        proofs = [:]
        var nextCID = peerTipCID
        var totalHeight: UInt64 = 0

        // Index of the peer that served the previous batch — each batch starts with
        // it (locality: a healthy server keeps serving without re-paying other peers'
        // timeouts) and rotates only when it goes empty (audit M2: don't re-iterate the
        // whole set every batch). Bounded to `peers.count` tries per batch.
        var serveIdx = 0
        while !Task.isCancelled {
            // Source-agnostic: a batch may come from ANY candidate peer — the first
            // non-empty response wins. A peer that is behind, has pruned the range, or
            // whose link is flaky returns empty; rotate to the next rather than ending
            // the walk. Only an empty result from EVERY peer stops it. Mixing peers
            // across batches is safe — each block is verified against its own
            // ChildBlockProof and bound to the carried-over `nextCID` (no fork splice).
            var bulk: [(cid: String, data: Data, proof: Data?)] = []
            for offset in 0..<peers.count {
                if Task.isCancelled { throw HeaderChainError.cancelled }
                let idx = (serveIdx + offset) % peers.count
                bulk = await network.requestHeaderBatchWithProofs(
                    fromCID: nextCID, count: ChainNetwork.maxHeaderBatchSize, peer: peers[idx]
                )
                if !bulk.isEmpty { serveIdx = idx; break }
            }
            guard !bulk.isEmpty else { break }

            if totalHeight == 0 {
                totalHeight = Block(data: bulk.first?.data ?? Data())?.height ?? 0
            }

            let accepted = try await acceptChildHeaderBatch(
                bulk,
                startingAt: nextCID,
                totalHeight: totalHeight,
                genesisBlockHash: genesisBlockHash,
                knownBlockCIDs: knownBlockCIDs,
                expectedChildPath: expectedChildPath,
                progress: progress,
                store: { cid, data in await network.storeSyncedBlock(cid: cid, data: data) }
            )

            if accepted.reachedStop { break }
            guard headers.count <= self.maxAccumulatedHeaders else {
                throw HeaderChainError.headerWalkTooLarge(headers.count)
            }
            guard let lastParent = accepted.nextCID,
                  !lastParent.isEmpty,
                  lastParent != genesisBlockHash else { break }
            nextCID = lastParent
        }

        if Task.isCancelled { throw HeaderChainError.cancelled }

        headers.reverse()
        return headers
    }

    func acceptChildHeaderBatch(
        _ bulk: [(cid: String, data: Data, proof: Data?)],
        startingAt nextCID: String,
        totalHeight: UInt64,
        genesisBlockHash: String,
        knownBlockCIDs: Set<String>,
        expectedChildPath: [String],
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil,
        store: @Sendable (String, Data) async -> Void
    ) async throws -> (reachedStop: Bool, nextCID: String?) {
        var expectedCID = nextCID
        var lastParent: String?

        for (cid, data, proof) in bulk {
            // Genesis is the chain's own trusted base — not a child block embedded in a
            // parent, so it has no anchoring proof. Accept it unproven and stop. It's
            // hash-bound (CID == content hash) AND must structurally be a genesis block
            // (height 0, no parent) so no interior block can masquerade as genesis.
            if cid == genesisBlockHash {
                guard cid == expectedCID, let block = Block(data: data),
                      try VolumeImpl<Block>(node: block).rawCID == cid,
                      block.height == 0, block.parent == nil else {
                    throw HeaderChainError.chainContinuityBroken(expected: expectedCID, got: cid)
                }
                cumulativeWork = saturatingWorkSum(cumulativeWork, workForTarget(block.target))
                headers.append(SyncBlockHeader(
                    cid: cid, height: block.height, previousBlockCID: block.parent?.rawCID,
                    target: block.target, nextTarget: block.nextTarget,
                    timestamp: block.timestamp,
                    specCID: block.spec.rawCID.isEmpty ? nil : block.spec.rawCID,
                    spec: block.spec.node))
                await progress?(totalHeight - block.height, totalHeight)
                await store(cid, data)
                return (true, block.parent?.rawCID)
            }

            let accepted = try await Self.acceptedChildHeader(
                expectedCID: expectedCID, receivedCID: cid, data: data,
                proofData: proof, expectedChildPath: expectedChildPath)
            let block = accepted.block
            cumulativeWork = saturatingWorkSum(cumulativeWork, workForTarget(block.target))
            headers.append(accepted.header)
            proofs[accepted.header.cid] = accepted.proofEnvelope
            lastParent = accepted.header.previousBlockCID
            await progress?(totalHeight - block.height, totalHeight)
            await store(accepted.header.cid, data)

            if let parentCID = block.parent?.rawCID, knownBlockCIDs.contains(parentCID) {
                return (true, parentCID)
            }
            guard let parentCID = block.parent?.rawCID else {
                return (true, nil)
            }
            expectedCID = parentCID
        }

        return (false, lastParent)
    }

    private func downloadHeadersSequential(
        peerTipCID: String,
        fetcher: Fetcher,
        genesisBlockHash: String,
        knownBlockCIDs: Set<String>,
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws -> [SyncBlockHeader] {
        headers = []
        cumulativeWork = .zero
        var currentCID = peerTipCID
        var targetHeight: UInt64?

        while !Task.isCancelled {
            let data: Data
            do {
                data = try await withTimeout(fetchTimeout, cid: currentCID, fetcher: fetcher)
            } catch {
                // If we can't fetch this block it's already local (e.g. premine
                // blocks whose bodies aren't in CAS storage). Stop here — the
                // headers collected so far are the delta we need to apply.
                if !headers.isEmpty { break }
                throw HeaderChainError.fetchFailed(currentCID)
            }

            let accepted = try Self.acceptedHeader(expectedCID: currentCID, receivedCID: currentCID, data: data)
            let block = accepted.block

            if targetHeight == nil {
                targetHeight = block.height
            }

            let work = workForTarget(block.target)
            // Saturating, not wrapping (&+): a minimum-difficulty segment can sum
            // to UInt256.max, and a wrap would drive the accumulator DOWN —
            // making a heavier chain look lighter. Matches the library's
            // saturatingWorkSum used in ChainSyncer/getCumulativeWork.
            cumulativeWork = saturatingWorkSum(cumulativeWork, work)

            let header = accepted.header
            headers.append(header)
            guard headers.count <= self.maxAccumulatedHeaders else {
                throw HeaderChainError.headerWalkTooLarge(headers.count)
            }

            if let th = targetHeight {
                await progress?(th - block.height, th)
            }

            guard let prevCID = block.parent?.rawCID else {
                break
            }

            if prevCID == genesisBlockHash || currentCID == genesisBlockHash {
                break
            }

            // Stop when we reach a block the local chain already has — no need
            // to download further back. This prevents walking into premine blocks
            // that are in ChainState but whose bodies aren't in local storage.
            if knownBlockCIDs.contains(prevCID) {
                break
            }

            currentCID = prevCID
        }

        if Task.isCancelled {
            throw HeaderChainError.cancelled
        }

        // Do not compare delta work against full local work: when downloading
        // only the new-block delta (stopping at a known local boundary), the
        // delta's accumulated work is always less than the full local chain work
        // even though the peer's full chain has more work. The work pre-check
        // in checkSyncNeeded already validated the peer is worthwhile to sync.

        headers.reverse()
        return headers
    } // end downloadHeadersSequential

    public var totalWork: UInt256 { cumulativeWork }
    public var headerCount: Int { headers.count }


    private func withTimeout(_ duration: Duration, cid: String, fetcher: Fetcher) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await fetcher.fetch(rawCid: cid)
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw HeaderChainError.fetchFailed("timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
