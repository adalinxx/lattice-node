import Lattice
import Foundation
import Ivy
import LatticeNodeWire
import VolumeBroker
import cashew
import UInt256
import OrderedCollections

// Gossip codec + publish/relay policy for ChainNetwork.
// Behavior-preserving extraction : block/mempool wire encode-decode,
// block publish/announce, block relay, and Dandelion++ stem transaction relay.
extension ChainNetwork {

    // MARK: - Block Operations (backward compat aliases)

    static func encodeBlockPayload(cid: String, data: Data) -> Data {
        NetworkWireCodecs.encodeBlockPayload(cid: cid, data: data)
    }

    static func decodeBlockPayload(_ payload: Data) -> (cid: String, data: Data)? {
        NetworkWireCodecs.decodeBlockPayload(payload)
    }

    public func publishBlock(
        cid: String,
        data: Data,
        rootHash: UInt256? = nil,
        proof: ChildBlockProof? = nil,
        proofs: [ChildBlockProof] = []
    ) async {
        await storeAndPublish(cid: cid, data: data)

        // B1(a): pin the published block under a HEIGHT-SCOPED owner so retention
        // prune (`pruneBlocks`, keyed on `ownerNamespace:<height>`) can reclaim it
        // via window-slide + transitive eviction. `storeAndPublish` no longer pins
        // under the bare
        // `ownerNamespace` owner, which leaked permanently. Idempotent with
        // `commitBlockStorage`'s identical height pin.
        let publishedBlock = Block(data: data)
        if let height = publishedBlock?.height {
            do {
                try await pinDurably(root: cid, owner: "\(ownerNamespace):\(height)")
            } catch {
                NodeLogger("storage").error("\(directory): publishBlock/pin root=\(String(cid.prefix(16)))… failed: \(error)")
            }
        }

        let cidPayload = Self.encodeBlockPayload(cid: cid, data: data)
        guard !cidPayload.isEmpty else { return }

        if rootHash != nil || proof != nil || !proofs.isEmpty {
            // Child chain gossip wire format:
            // [proofLen: UInt32 LE][proof envelope][cidLen: UInt16][cid][blockData]
            // proof envelope = one or more sparse CAS paths from parent/root blocks to the child.
            var payload = Data()
            let proofSet = proofs.isEmpty ? proof.map { [$0] } ?? [] : proofs
            let proofBytes = proofSet.isEmpty ? Data() : ChildBlockProofEnvelope.serialize(proofSet)
            var proofLen = UInt32(proofBytes.count).littleEndian
            payload.append(Data(bytes: &proofLen, count: 4))
            payload.append(proofBytes)
            payload.append(cidPayload)
            await ivy.broadcastMessage(topic: "childBlock", payload: payload)
        } else {
            await ivy.broadcastMessage(topic: "newBlock", payload: cidPayload)
        }

        if let block = publishedBlock {
            await announceVolumeBoundaries(block: block)
        }
        // Advertise the publisher as a DHT pinner of the block ROOT. Gossip
        // receivers announce via announceStoredBlock after acceptance, but the
        // origin (miner) otherwise never appears in provider discovery — peers
        // that only heard the announcement could not discoverPinners/fetch the
        // block from the node that actually mined and durably stores it.
        await announceStoredBlock(cid: cid, data: data)
    }

    /// Publish a pin announce via Ivy and record the CID with the disk broker.
    /// Ivy 5.5 removed selector — DHT pin discovery is now whole-root.
    public func announce(cid: String, expiry: UInt64, fee: UInt64) async {
        guard !cid.isEmpty else { return }
        // Dedup window: see `recentPinAnnounces`. Re-announcing the same CID
        // within the window is pure churn that drains the per-peer Tally
        // admission budget and can starve newBlock gossip during block bursts.
        let now = ContinuousClock.Instant.now
        if let last = recentPinAnnounces[cid], now - last < pinAnnounceDeduplicationWindow {
            return
        }
        recentPinAnnounces[cid] = now
        Self.evictRecentTxCIDs(&recentPinAnnounces, limit: maxRecentPinAnnounces)
        // Use the self-signing overload: Ivy verifies pin announcements and
        // silently drops any with an empty/invalid signature, so passing
        // signature: Data() made every announce a no-op (peers could never
        // discover this node as a pinner). Clamp expiry to Ivy's max TTL —
        // isExpiryValid also drops announcements beyond now+maxTTLSeconds
        // (the periodic re-announce loop refreshes long-lived pins).
        let maxExpiry = UInt64(Date().timeIntervalSince1970) + PinAnnouncementSignature.maxTTLSeconds
        await ivy.publishPinAnnounce(rootCID: cid, expiry: min(expiry, maxExpiry), fee: fee)
    }

    /// Publish pin announcements for each Volume boundary root in the block.
    /// Ivy 5.5 dropped subtree selectors — pins are now whole-root, so per-
    /// subtree announce calls have collapsed to one announce per distinct CID.
    private func announceVolumeBoundaries(block: Block) async {
        let fee = await ivy.config.relayFee * 3
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400

        let frontierCID = block.postState.rawCID
        if !frontierCID.isEmpty {
            await announce(cid: frontierCID, expiry: expiry, fee: fee)
        }
        let homesteadCID = block.prevState.rawCID
        if !homesteadCID.isEmpty {
            await announce(cid: homesteadCID, expiry: expiry, fee: fee)
        }

        let txCID = block.transactions.rawCID
        if !txCID.isEmpty {
            await announce(cid: txCID, expiry: expiry, fee: fee)
        }

        let childCID = block.children.rawCID
        if !childCID.isEmpty {
            await announce(cid: childCID, expiry: expiry, fee: fee)
        }
    }

    public func storeBlock(cid: String, data: Data) async {
        await storeLocally(cid: cid, data: data)
        // Announce stored block so we can earn from serving it
        await announceStoredBlock(cid: cid, data: data)
    }

    public func storeSyncedBlock(cid: String, data: Data) async {
        // Persist the header BYTES only — headers-first sync walks parent links
        // through them, and they survive a mid-sync restart. Deliberately does
        // NOT pin: a pin is a commitment to SERVE, and we must not commit to
        // serve a block whose closure we have not yet verified complete. At this
        // point we hold only the bare root node (no tx bodies / postState /
        // children), so pinning it would advertise + serve a 1-entry stub — the
        // exact bare-root poison the serve-by-pins model exists to prevent. The
        // height-scoped pin is taken later, in materializeSyncedCanonicalContent,
        // only AFTER the block's content closure resolves and validates. Until
        // then these unpinned header bytes are reclaimable by eviction.
        await storeLocally(cid: cid, data: data)
        do {
            try await storeVolumeDurably(SerializedVolume(root: cid, entries: [cid: data]))
        } catch {
            NodeLogger("storage").error("\(directory): failed to persist synced header \(String(cid.prefix(16)))…: \(error)")
        }
    }

    /// Announce a block we received and stored so peers can discover us as a pinner.
    /// Lighter than publishBlock — no storeAndPublish, just pin announcements.
    /// Only the block root CID is announced here because this path stores only
    /// the block bytes (via storeLocally), never the sub-volumes (state/tx tries).
    /// Announcing sub-volume CIDs we don't actually hold causes false provider
    /// records: other nodes send `want` to us, receive empty, and mark the fetch
    /// failed. Sub-volume CIDs are announced by storeBlockRecursively, which is
    /// the only path that actually fetches and stores those volumes.
    func announceStoredBlock(cid: String, data: Data) async {
        let fee = await ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400
        await announce(cid: cid, expiry: expiry, fee: fee)
    }

    // MARK: - Gossip

    /// Re-broadcast a received block with full inline data to all direct peers.
    /// Called after a gossiped block is accepted so nodes one hop away from the
    /// original miner receive the data directly instead of having to DHT-discover
    /// and fetch it. The 100ms dedup window in the receiver prevents storms.
    public func relayBlock(cid: String, data: Data) async {
        let payload = Self.encodeBlockPayload(cid: cid, data: data)
        guard !payload.isEmpty else { return }
        await ivy.broadcastMessage(topic: "newBlock", payload: payload)
    }

    public func relayBlock(
        cid: String,
        data: Data,
        rootHash: UInt256,
        proof: ChildBlockProof? = nil,
        proofs: [ChildBlockProof] = []
    ) async {
        await publishBlock(cid: cid, data: data, rootHash: rootHash, proof: proof, proofs: proofs)
    }

    /// Gossip a transaction to all direct peers with body data inline.
    /// `HeaderImpl`'s Codable only emits rawCID, so a gossiped Transaction decodes
    /// with `body.node == nil` — which trips `TransactionValidator.validate`'s
    /// missingBody guard and drops the tx. We include body bytes in the payload
    /// so receivers can reconstruct the Transaction with body.node populated.
    /// Wire format: [cidLen: UInt16 LE][cid][bodyLen: UInt32 LE][body][tx]
    public func gossipTransaction(cid: String, bodyData: Data, transactionData: Data) async {
        let payload = Self.encodeMempoolFullPayload(
            cid: cid,
            bodyData: bodyData,
            transactionData: transactionData
        )
        guard !payload.isEmpty else { return }

        // Dandelion++ stem phase: route through a single peer for
        // dandelionStemEpochDuration before fluff-broadcasting to all peers.
        // Rotate the stem peer every epoch so no single peer can correlate
        // all transactions to this node.
        let now = ContinuousClock.Instant.now
        if now - dandelionEpochStart > dandelionStemEpochDuration {
            dandelionStemPeer = await ivy.connectedPeers.randomElement()
            dandelionEpochStart = now
        }
        if let stemPeer = dandelionStemPeer,
           await ivy.connectedPeers.contains(where: { $0 == stemPeer }) {
            await ivy.sendMessage(to: stemPeer, topic: "mempool-full", payload: payload)
        } else {
            // Stem peer disconnected — fall back to fluff broadcast this epoch
            await ivy.broadcastMessage(topic: "mempool-full", payload: payload)
        }
    }

    static func encodeMempoolFullPayload(cid: String, bodyData: Data, transactionData: Data) -> Data {
        NetworkWireCodecs.encodeMempoolFullPayload(cid: cid, bodyData: bodyData, transactionData: transactionData)
    }

    static func decodeMempoolFullPayload(_ payload: Data) -> (cid: String, bodyData: Data, transactionData: Data)? {
        NetworkWireCodecs.decodeMempoolFullPayload(payload)
    }

    static func evictRecentTxCIDs(
        _ recent: inout OrderedDictionary<String, ContinuousClock.Instant>,
        limit: Int
    ) {
        guard limit >= 0 else {
            recent.removeAll()
            return
        }
        // Evict by oldest TIMESTAMP, not insertion order: a CID refreshed in place
        // (re-seen after its dedup window) keeps its old slot but a newer time, so
        // front-eviction would wrongly drop it. See
        // testRecentTxCIDEvictsOldestTimestampNotInsertionOrder. The scan is O(n)
        // over an 8k-capped map; the perf nit is not worth coupling correctness to
        // caller touch-discipline.
        while recent.count > limit,
              let oldest = recent.min(by: { $0.value < $1.value })?.key {
            recent.removeValue(forKey: oldest)
        }
    }
}
