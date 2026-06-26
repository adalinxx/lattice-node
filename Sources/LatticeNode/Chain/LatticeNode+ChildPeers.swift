import Foundation
import Ivy
import Tally

/// Same-chain peer bootstrap (node side). See `ChildPeerProvider` for the why:
/// the parent chain is the rendezvous, a child advertises its chain-gossip
/// endpoint over the parent link, and a follower asks the parent for the
/// endpoints of its connected same-chain children. The serve side reads the
/// LIVE spawn-trusted subscriber set (no registry); the client side is driven by
/// the parent-subscription loop.
extension LatticeNode {
    // MARK: - Serve (a parent answers a followed child)

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerAdvertise payload: Data, from peer: PeerID) async {
        guard let adv = ChildPeerProvider.decodeAdvertise(payload) else { return }
        await recordAdvertisedChildEndpoint(peer: peer, directory: adv.directory, endpoint: adv.endpoint)
    }

    func recordAdvertisedChildEndpoint(peer: PeerID, directory: String, endpoint: String) {
        advertisedChildEndpoints[peer] = (directory, endpoint)
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerRequest payload: Data, from peer: PeerID) async -> Data? {
        guard let req = ChildPeerProvider.decodeRequest(payload) else { return nil }
        var endpoints = await collectChildPeerEndpoints(network: network, directory: req.directory, asker: peer)
        // Transitive forward (one hop): if we serve no DIRECT same-chain child for this
        // directory but were asked with ttl>0, ask OUR OWN same-chain peers — one of them
        // may be the source's parent, which DOES have it advertised. This is what makes
        // discovery converge at depth, where a follower's immediate parent is a fresh node
        // that hasn't yet propagated its same-chain peers. ttl=0 on the forward → no
        // re-forward (single hop, no loops); fan-out is capped.
        if endpoints.isEmpty && req.ttl > 0 {
            endpoints = await forwardChildPeerQuery(network: network, directory: req.directory, asker: peer)
        }
        return ChildPeerProvider.encodeResponse(requestId: req.requestId, endpoints: endpoints)
    }

    /// One-hop forward of an UNANSWERED getChildPeers query to our own same-chain peers
    /// (peers on `network`, excluding the asker), bounded by `maxForwardFanout` and sent
    /// with ttl=0 so they never re-forward. Parallel, so the responder stays fast (it
    /// returns as soon as the source's parent answers from its direct subscriber set).
    func forwardChildPeerQuery(network: ChainNetwork, directory: String, asker: PeerID) async -> [String] {
        guard let provider = childPeerProvider else { return [] }
        let targets = await network.ivy.connectedPeers.filter { $0 != asker }.prefix(ChildPeerProvider.maxForwardFanout)
        guard !targets.isEmpty else { return [] }
        var aggregated: [String] = []
        await withTaskGroup(of: [String].self) { group in
            for p in targets {
                group.addTask { await provider.requestChildPeers(from: p, directory: directory, ttl: 0) }
            }
            for await eps in group {
                aggregated.append(contentsOf: eps)
                // Return as soon as a peer answers, so the responder stays well within the
                // original asker's request timeout (the source's parent answers fast from
                // its direct subscriber set). Stragglers time out harmlessly.
                if !aggregated.isEmpty { group.cancelAll(); break }
            }
        }
        var seen = Set<String>()
        return Array(aggregated.filter { seen.insert($0).inserted }.prefix(ChildPeerProvider.maxEndpoints))
    }

    /// Endpoints of THIS chain's connected `directory` children — the live
    /// subscribers on `network` that advertised that directory. The directory is
    /// self-declared (verified on dial); the asker is excluded so a follower never
    /// dials itself. Reads the live connection set, so eviction is by disconnect.
    func collectChildPeerEndpoints(network: ChainNetwork, directory: String, asker: PeerID) async -> [String] {
        let connected = await network.ivy.connectedPeers
        var result: [String] = []
        for p in connected where p != asker {
            if let adv = advertisedChildEndpoints[p], adv.directory == directory {
                result.append(adv.endpoint)
            }
        }
        return result
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerResponse payload: Data, from peer: PeerID) async {
        await childPeerProvider?.handleResponse(payload, from: peer)
    }

    /// Route a getChildPeers response that arrived on the parent-subscription link
    /// into the client correlation (responder-bound).
    func deliverChildPeerResponse(_ payload: Data, from peer: PeerID) async {
        await childPeerProvider?.handleResponse(payload, from: peer)
    }

    // MARK: - Client (a followed child finds same-chain peers via its parents)

    /// This node's own chain-gossip endpoint to advertise to parents: the operator
    /// public address when set (cloud/NAT), else loopback for local/test — the same
    /// self-advertisement source the rest of the node uses.
    var ownChainGossipEndpoint: String {
        let host = config.externalAddress?.host ?? "127.0.0.1"
        let port = config.externalAddress?.port ?? config.listenPort
        return "\(config.p2pPublicKey)@\(host):\(port)"
    }

    /// Advertise our chain endpoint to every parent on the `directory` subscription
    /// link, so a parent can serve us to a same-chain follower.
    func advertiseChainEndpointToParents(directory: String) async {
        guard let ivy = parentConsensusLinks[directory]?.ivy else { return }
        let payload = ChildPeerProvider.encodeAdvertise(directory: directory, endpoint: ownChainGossipEndpoint)
        await ivy.broadcastMessage(topic: ChildPeerProvider.advertiseTopic, payload: payload)
    }

    /// Direct peer count on the `directory` chain-gossip network.
    func chainGossipPeerCount(directory: String) async -> Int {
        guard let network = network(for: directory) else { return 0 }
        return await network.ivy.directPeerCount
    }

    /// Whether a followed child still needs a same-chain peer: it has no peer on
    /// its chain-gossip network, or it has not synced any block past genesis yet.
    /// (A peer count alone is insufficient — a cross-chain bootstrap peer can be
    /// connected without ever serving this chain.)
    func needsSameChainPeer(directory: String) async -> Bool {
        if await chainGossipPeerCount(directory: directory) == 0 { return true }
        let height = await chain(for: directory)?.getHighestBlockHeight() ?? 0
        return height == 0
    }

    /// Ask every connected parent for this chain's same-chain peers and dial any
    /// returned endpoints on the chain-gossip network. Verify-not-trust: the dial
    /// authenticates the identity and consensus validates the chain, so a bogus
    /// endpoint costs only a wasted dial. Our own endpoint is skipped.
    func discoverAndDialSameChainPeers(directory: String) async {
        guard let ivy = parentConsensusLinks[directory]?.ivy,
              let provider = childPeerProvider,
              let network = network(for: directory) else { return }
        let ownPubkey = config.p2pPublicKey
        let connected = Set(await network.ivy.connectedPeers.map { $0.publicKey })
        let log = NodeLogger("childpeers")
        for parent in await ivy.connectedPeers {
            let endpoints = await provider.requestChildPeers(from: parent, directory: directory)
            for ep in endpoints {
                guard let endpoint = Self.parseChainEndpoint(ep),
                      endpoint.publicKey != ownPubkey,
                      !connected.contains(endpoint.publicKey) else { continue }
                log.info("\(directory): dialing same-chain peer \(String(ep.prefix(24)))… (found via getChildPeers)")
                try? await network.ivy.connect(to: endpoint)
            }
        }
    }

    /// Parse a `pubkey@host:port` chain endpoint (raw or ed01-prefixed key).
    static func parseChainEndpoint(_ s: String) -> PeerEndpoint? {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var pubkey = String(parts[0])
        if pubkey.hasPrefix("ed01") && pubkey.count == 68 { pubkey = String(pubkey.dropFirst(4)) }
        let hostPort = String(parts[1]).split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]), !pubkey.isEmpty else { return nil }
        return PeerEndpoint(publicKey: pubkey, host: String(hostPort[0]), port: port)
    }
}
