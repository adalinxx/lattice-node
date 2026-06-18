import Foundation
import cashew
import Ivy
import VolumeBroker
import Tally
import OrderedCollections

public enum FetcherError: Error {
    case notFound(String)
}

/// Stage 2c (content-store cutover): batched Ivy-backed `ContentSource`.
/// cashew's `resolve(paths:source:)` asks for each BFS wave of CIDs at once
/// (via `CoalescingFetcher`); `IvyFetcher.fetchWave` serves the wave from
/// local CAS and fetches the misses — by wave order, always Volume boundary
/// roots — as whole attributed bundles. This is the replacement the cashew
/// `enterVolume`/`VolumeAwareFetcher` deletion (cashew #12/#13) shipped for:
/// boundary knowledge stays out of the fetch layer entirely.
public struct IvyContentSource: ContentSource {
    private let ivyFetcher: IvyFetcher

    public init(_ ivyFetcher: IvyFetcher) {
        self.ivyFetcher = ivyFetcher
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        await ivyFetcher.fetchWave(cids)
    }
}

/// Fetcher that bridges Cashew's resolution system to Ivy's content network.
///
/// cashew 3.x resolves per-CID over a plain `Fetcher` (and batched over a
/// `ContentSource`); there is no `enterVolume`/`exitVolume` pre-fetch
/// side-channel. A miss in the local broker tier falls through to an Ivy
/// network fetch. (Stage-2 cutover replaces this with object-grain
/// `ContentStore` composition; here it is adapted to the new protocols.)
///
/// Module 8 (layer cleanup) — placement VALIDATED to stay node-side. Ivy and
/// VolumeBroker are independent packages (neither depends on the other), so
/// hosting this Ivy↔VolumeBroker bridge in either would force a new cross
/// dependency; and the bridge is mostly node policy (fetch deadlines/poll
/// intervals, `NodeLogger`, the per-resolution volume trace, the two-tier
/// `broker.near` cascade). The reusable peer-punishment already lives below the
/// node — `ivy.reportDeficientVolume` does the Tally demote + suppression; this
/// actor only attributes a deficient bundle to the peer that served it. So the
/// node keeps the thin adapter and nothing moves down.
public actor IvyFetcher: Fetcher {
    private let ivy: Ivy
    private let broker: any VolumeBroker
    private let fetchDeadline: Duration
    private let fetchPollInterval: Duration

    /// Which peer served each volume bundle this fetcher persisted. A received
    /// volume is a locality grouping, not a completeness claim — its
    /// completeness/correctness is verified lazily (JIT) by the typed
    /// resolution that consumes it. When that resolution fails, the consumer
    /// calls `reportDeficientVolumes(roots:)` and this map attributes the
    /// deficient bundle to its server. Bounded LRU-ish (oldest dropped).
    private var volumeServers = OrderedDictionary<String, PeerID>()
    private let maxVolumeServers = 1024

    public init(
        ivy: Ivy,
        broker: any VolumeBroker,
        fetchDeadline: Duration = NodeTuning.Sync().fetchDeadline,
        fetchPollInterval: Duration = NodeTuning.Sync().fetchPollInterval
    ) {
        self.ivy = ivy
        self.broker = broker
        self.fetchDeadline = fetchDeadline
        self.fetchPollInterval = fetchPollInterval
    }

    /// Volume roots network-fetched since `beginVolumeTrace()` — the set a JIT
    /// resolution-failure handler reports as potentially deficient.
    private var volumeTrace: [String]?

    func beginVolumeTrace() {
        volumeTrace = []
    }

    func takeVolumeTrace() -> [String] {
        defer { volumeTrace = nil }
        return volumeTrace ?? []
    }

    private func rememberVolumeServer(_ peer: PeerID?, rootCID: String) {
        guard let peer else { return }
        volumeServers[rootCID] = peer
        while volumeServers.count > maxVolumeServers {
            volumeServers.removeFirst()
        }
        if volumeTrace != nil {
            volumeTrace?.append(rootCID)
        }
    }

    /// JIT verification verdict from resolution: the bundles fetched for
    /// `roots` did not resolve (in-package entries were missing or falsified).
    /// Report each remembered server to Ivy — Tally demotion plus provider-
    /// record removal — and return the punished peers so the caller can
    /// exclude them from the refetch. Trust is local: nothing is recorded
    /// about the volumes, only about the peers that served them.
    public func reportDeficientVolumes(roots: [String]) async -> Set<PeerID> {
        var punished: Set<PeerID> = []
        for root in roots {
            guard let peer = volumeServers.removeValue(forKey: root) else { continue }
            await ivy.reportDeficientVolume(rootCID: root, peer: peer)
            punished.insert(peer)
        }
        return punished
    }

    /// Hint that `peer` is a known provider for `rootCID`.
    public func bindPinner(rootCID: String, peer: PeerID) async {
        guard !rootCID.isEmpty else { return }
        await ivy.recordProvider(rootCID: rootCID, peer: peer)
    }

    /// Bind multiple CIDs to the same peer in one Ivy actor hop.
    public func bindPinners(rootCIDs: [String], peer: PeerID) async {
        let nonEmpty = rootCIDs.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        await ivy.recordProviders(rootCIDs: nonEmpty, peer: peer)
    }

    // MARK: - Fetcher

    public func fetch(rawCid: String) async throws -> Data {
        // Content-by-CID across the local tier chain (memory → disk). Grain-
        // independent: resolves any node from cas_data, not only volume roots, so
        // an object stored as a single closure resolves its internal nodes too.
        if let data = await broker.fetchData(cid: rawCid) { return data }

        // Not local — fetch from peers. Ivy exposes volume fetch as fan-out
        // today; divergence safety belongs to block validation/fork choice after
        // the fetched content is decoded.
        //
        // Poll peers until the deadline rather than giving up after a single
        // empty fan-out. A connected peer can transiently answer "notHave" for
        // content it is about to hold — a freshly-accepted block whose singleton
        // sub-node volumes are still writing through to disk on the source, or a
        // data channel still negotiating right after connect. Whole-block
        // resolution issues one fetch() per internal trie node, so a single
        // transient miss would otherwise abort an entire block and leave a
        // follower stuck on a stale tip. This is an availability retry only; it
        // never weakens validation. Content a peer genuinely lacks simply runs
        // out the deadline and throws notFound as before.
        let waitDeadline = ContinuousClock.Instant.now + fetchDeadline
        while true {
            let connectedPeers = await ivy.connectedPeers
            if !connectedPeers.isEmpty {
                let response = await ivy.fetchVolumeFromAllPeersAttributed(rootCID: rawCid)
                if let data = response.entries[rawCid] {
                    await persistVolume(rootCID: rawCid, entries: response.entries)
                    rememberVolumeServer(response.servedBy, rootCID: rawCid)
                    return data
                }
            }
            if ContinuousClock.Instant.now >= waitDeadline { break }
            try? await Task.sleep(for: fetchPollInterval)
        }
        NodeLogger("fetcher").error("notFound:\(rawCid)")
        throw FetcherError.notFound(rawCid)
    }

    /// Fetch a volume's full bundle — its root node PLUS its in-package entries —
    /// from peers and persist it locally, even when the root node is already
    /// cached. Headers-first sync and compact-block gossip deliver only the block
    /// ROOT node; object-grain storage keeps the block's in-package closure (the
    /// transaction / children trie nodes) as NON-root entries, so resolving the
    /// block content needs the whole bundle in one round-trip. Per-CID `fetch`
    /// would instead request each internal node individually — and a peer's
    /// root-keyed volume responder cannot serve a non-root internal node, so the
    /// resolve would stall. No-op once the bundle (more than the root entry) is
    /// already local.
    /// `preferComplete` is for roots that are KNOWN to be multi-entry closures
    /// (block volumes): a bare-root (single-entry) response is a stub that would
    /// shadow a complete holder, so suppress bare-root responders for a few polls
    /// and never cache the stub. Leave it false for roots that are legitimately
    /// single node (chain specs, simple transaction bodies) — otherwise every
    /// such fetch pays an unnecessary wait, which on the per-block extraction
    /// path slows a child chain enough that it lags the parent and can never
    /// assemble a parent-state-continuous candidate.
    /// `force` bypasses the local "already have" short-circuit: after a JIT
    /// resolution failure punished the bundle's server, the locally-persisted
    /// grouping is the deficient one — the retry must go back to the network
    /// rather than trust it again. Routing around the punished server is handled
    /// inside Ivy (per-root deficiency suppression driven by reportDeficientVolume),
    /// so there is no exclusion set to thread here.
    @discardableResult
    public func fetchVolumeBundle(
        rootCID: String,
        preferComplete: Bool = false,
        force: Bool = false
    ) async -> Bool {
        guard !rootCID.isEmpty else { return false }
        // Already have the bundle (more than the bare root entry) — nothing to do.
        // Single-entry volumes (root only) can't be distinguished locally from a
        // root delivered as a parent's owned-child edge, so they are (cheaply)
        // re-requested; a peer that lacks the volume answers notHave, so the
        // request is served only by a real holder.
        //
        // The "already have" check must reach the ON-DISK store, not just the
        // in-memory broker: in local mode `broker` is a MemoryBroker whose
        // `fetchVolumeLocal` does not cascade to its `.near` DiskBroker, so a
        // volume fully persisted on disk but aged out of the memory LRU would be
        // treated as absent and needlessly re-fetched — and, with no connected
        // peers, would burn the whole `fetchDeadline` polling for content we
        // already hold. Consult `broker.near` (the disk tier) explicitly.
        if !force {
            // The memory fetch cache is an availability cache, not an authority on
            // bundle completeness: sparse proofs and deficient peer responses can
            // both be multi-entry groupings. Only durable, structurally-stored
            // groupings may short-circuit a bundle fetch.
            if let disk = await broker.near?.fetchVolumeLocal(root: rootCID), disk.entries.count > 1 { return true }
        }
        let waitDeadline = ContinuousClock.Instant.now + fetchDeadline
        // Prefer a COMPLETE (multi-entry) bundle over a bare-root one. The volume
        // fetch resolves on the FIRST peer to answer, so a peer that holds only the
        // bare root — e.g. one that headers-first-synced this block but hasn't
        // fetched its content — can shadow a complete holder and hand back an
        // unusable stub. When `preferComplete` is true the caller has declared the
        // root a known multi-entry closure (currently block volumes), so a bare-root
        // response is never a useful fallback; suppress that peer for this root and
        // never persist the stub into the fetch cache.
        var suppressedBareRootPeers = Set<String>()
        var bareRootPolls = 0
        let bareRootPollLimit = 3
        while true {
            // No connected peers — polling is futile (there is no one to serve
            // the bundle), so return now instead of sleeping to the deadline.
            // The transient-miss polling below is for a CONNECTED peer that is
            // about to hold the content, not for waiting on peers to appear; a
            // node with zero peers cannot fetch and the caller (on-demand
            // resolution / a later wave) re-fetches once peers exist. Without
            // this, a best-effort warm-up (e.g. the parent-extractor content
            // prefetch) spawned with no peers would block/linger for the whole
            // fetch deadline.
            guard !(await ivy.connectedPeers.isEmpty) else { break }
            let response = await ivy.fetchVolumeFromAllPeersAttributed(rootCID: rootCID)
            if response.entries[rootCID] != nil {
                if response.entries.count > 1 || !preferComplete {
                    // Multi-entry closure, or a root we accept as-is (a single-
                    // node volume): take it immediately.
                    await persistVolume(rootCID: rootCID, entries: response.entries)
                    rememberVolumeServer(response.servedBy, rootCID: rootCID)
                    return true
                }
                // preferComplete && single-entry: known stub. Route around the
                // first responder for this root before the next poll; otherwise a
                // fast headers-only tracker can win every round and starve a
                // complete holder. Suppression is short-lived and root-scoped in
                // Ivy, so transient writers self-heal.
                if let peer = response.servedBy,
                   suppressedBareRootPeers.insert(peer.publicKey).inserted {
                    await ivy.reportDeficientVolume(rootCID: rootCID, peer: peer)
                }
                bareRootPolls += 1
                if bareRootPolls >= bareRootPollLimit { break }
            }
            if ContinuousClock.Instant.now >= waitDeadline { break }
            try? await Task.sleep(for: fetchPollInterval)
        }
        return false
    }

    public func hasCompleteLocalBundle(rootCID: String) async -> Bool {
        guard !rootCID.isEmpty else { return false }
        if let memory = await broker.fetchVolumeLocal(root: rootCID), memory.entries.count > 1 { return true }
        if let disk = await broker.near?.fetchVolumeLocal(root: rootCID), disk.entries.count > 1 { return true }
        return false
    }

    // MARK: - Batched wave fetch (ContentSource, cutover Stage 2c)

    /// Serve one cashew resolution WAVE: every CID the resolver needs next, in
    /// one call. Local CAS first; anything not locally resolvable is — by the
    /// wave-order invariant (a volume's entries land locally before resolution
    /// descends into its in-package children) — a Volume BOUNDARY root, and is
    /// fetched as a whole attributed bundle. Internal entries are therefore
    /// never requested individually over the wire; absence in the returned map
    /// is the resolver's notFound, which feeds the JIT deficiency handling.
    public func fetchWave(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        var missing: [String] = []
        for cid in cids where !cid.isEmpty {
            if let data = await broker.fetchData(cid: cid) {
                out[cid] = data
            } else {
                missing.append(cid)
            }
        }
        guard !missing.isEmpty else { return out }
        // The actor is reentrant at await points, so the group's bundle fetches
        // overlap on the network: one wave → one round of parallel volume wants.
        await withTaskGroup(of: Void.self) { group in
            for root in missing {
                group.addTask { _ = await self.fetchVolumeBundle(rootCID: root) }
            }
        }
        for root in missing {
            if let data = await broker.fetchData(cid: root) {
                out[root] = data
            }
        }
        return out
    }

    // MARK: - Store

    public func store(rawCid: String, data: Data, pin: Bool = false) async {
        let payload = SerializedVolume(root: rawCid, entries: [rawCid: data])
        try? await broker.storeVolumeLocal(payload)
    }

    // MARK: - Private

    private func persistVolume(rootCID: String, entries: [String: Data]) async {
        // The fetch cache is MEMORY-ONLY. The durable tier is written exclusively
        // by authoritative, PINNED stores (accepted blocks via storeBlockData,
        // verified payloads, mempool tx closures, staging pins): disk holds only
        // what something pinned — ever. A network response never creates durable
        // rows, so a tracker/syncer accumulates zero durable residue to be swept
        // (or accidentally served) later. Memory eviction mid-resolve costs a
        // refetch, never correctness; once a block is accepted its closure is
        // re-stored authoritatively from the hydrated object.
        //
        // The fetched bundle is stored as ONE grouping (no singleton promotion):
        // in-package entries stay grouped under rootCID so the next resolution
        // waves hit local memory.
        //
        // A persist failure must be VISIBLE: a silently-dropped bundle later
        // surfaces as notFound during resolution and gets misattributed to the
        // peer that served it correctly (JIT deficiency reporting).
        do {
            try await broker.storeVolumesLocal([SerializedVolume(root: rootCID, entries: entries)])
        } catch {
            NodeLogger("fetcher").error("persistVolume \(String(rootCID.prefix(16)))… (\(entries.count) entries) failed: \(error)")
        }
    }
}
