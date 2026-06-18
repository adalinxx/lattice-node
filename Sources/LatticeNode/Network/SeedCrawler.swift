import Foundation
import Ivy
import Tally

/// Crawls the network to discover and score peers, then exports the healthiest
/// ones to a seeds file that DNS infrastructure can serve.
///
/// Scoring criteria:
///   - Tally reputation (latency, success rate, reciprocity)
///   - Recently seen (not stale)
///   - Subnet diversity (max 2 per /16)
///   - Uptime stability (firstSeen age)
///
/// Output: one `pubkey@host:port` per line in `{dataDir}/seeds.txt`.
public actor SeedCrawler {
    private let ivy: Ivy
    private let dataDir: URL
    private let maxSeeds: Int

    /// Minimum Tally reputation (0.0–1.0) for a peer to be seed-eligible.
    private let minReputation: Double = 0.1

    /// Peers must have been seen within this window to be considered alive.
    private let maxStaleAge: Duration = .seconds(600)

    /// How often the crawler re-scores and writes the seeds file.
    private let crawlInterval: Duration = .seconds(300)

    public init(ivy: Ivy, dataDir: URL, maxSeeds: Int = 25) {
        self.ivy = ivy
        self.dataDir = dataDir
        self.maxSeeds = maxSeeds
    }

    public func start() async {
        // Run an initial crawl immediately, then loop
        await crawlAndExport()
        while !Task.isCancelled {
            try? await Task.sleep(for: crawlInterval)
            guard !Task.isCancelled else { break }
            await crawlAndExport()
        }
    }

    private func crawlAndExport() async {
        // Discover more peers via random DHT walks
        for _ in 0..<3 {
            let _ = await ivy.findNode(target: UUID().uuidString)
        }

        let allKnown = await ivy.router.allPeers()
        let connectedIDs = Set(await ivy.connectedPeers.map { $0.publicKey })
        let now = ContinuousClock.Instant.now

        // Score each known peer
        var scored: [(endpoint: PeerEndpoint, score: Double)] = []
        for entry in allKnown {
            let peerID = entry.id
            let endpoint = entry.endpoint

            // Skip peers with empty public keys (A-record fallback peers)
            guard !endpoint.publicKey.isEmpty else { continue }

            // Freshness: how recently was this peer seen?
            let age = entry.lastSeen.duration(to: now)
            guard age < maxStaleAge else { continue }

            // Tally reputation
            let reputation = await ivy.tally.reputation(for: peerID)
            guard reputation >= minReputation else { continue }

            // Bonus for being currently connected (proven reachable right now)
            let connectedBonus: Double = connectedIDs.contains(peerID.publicKey) ? 0.2 : 0.0

            // Bonus for uptime stability (peers seen longer ago are more stable)
            var uptimeBonus: Double = 0.0
            if let ledger = await ivy.tally.peerLedger(for: peerID) {
                let uptimeSeconds = ledger.firstSeen.duration(to: now)
                let uptimeHours = Double(uptimeSeconds.components.seconds) / 3600.0
                // Cap at 0.1 bonus after 24 hours
                uptimeBonus = min(uptimeHours / 240.0, 0.1)
            }

            let score = reputation + connectedBonus + uptimeBonus
            scored.append((endpoint: endpoint, score: score))
        }

        // Sort by score descending
        scored.sort { $0.score > $1.score }

        // Apply subnet diversity: max 2 per /16 subnet
        var selected: [PeerEndpoint] = []
        var subnetCounts: [String: Int] = [:]
        for (endpoint, _) in scored {
            guard selected.count < maxSeeds else { break }
            let subnet = PeerDiversity.subnet(endpoint.host)
            let count = subnetCounts[subnet, default: 0]
            if count < PeerDiversity.maxPerSubnet {
                selected.append(endpoint)
                subnetCounts[subnet, default: 0] += 1
            }
        }

        // Write seeds file
        writeSeeds(selected)
    }

    private func writeSeeds(_ peers: [PeerEndpoint]) {
        let lines: [String] = peers.compactMap { peer in
            // Strip newlines and the record-delimiter character '@' from
            // peer-supplied fields. A peer whose host or publicKey contains
            // a newline would inject extra lines into seeds.txt, corrupting
            // bootstrap records parsed by other nodes.
            let safeKey = peer.publicKey.filter { !$0.isNewline && $0 != "@" }
            let safeHost = peer.host.filter { !$0.isNewline && $0 != "@" }
            guard !safeKey.isEmpty, !safeHost.isEmpty else { return nil }
            return "\(safeKey)@\(safeHost):\(peer.port)"
        }
        let content = lines.joined(separator: "\n") + "\n"
        let path = dataDir.appendingPathComponent("seeds.txt")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }
}
