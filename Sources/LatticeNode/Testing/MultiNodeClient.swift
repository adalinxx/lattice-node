import Lattice
import Foundation
import cashew
import Ivy
import UInt256

public struct NodeIdentity: Sendable {
    public let id: String
    public let publicKey: String
    public let privateKey: String
    public let port: UInt16

    public init(id: String, publicKey: String, privateKey: String, port: UInt16) {
        self.id = id
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.port = port
    }

    public static func generate(id: String, port: UInt16) -> NodeIdentity {
        let keyPair = CryptoUtils.generateKeyPair()
        return NodeIdentity(
            id: id,
            publicKey: keyPair.publicKey,
            privateKey: keyPair.privateKey,
            port: port
        )
    }
}

public struct NodeStatus: Sendable {
    public let id: String
    public let port: UInt16
    public let isRunning: Bool
    public let miningDirectories: [String]
    public let chainHeight: UInt64
    public let chainTip: String
    public let mempoolCount: Int
}

public actor MultiNodeClient {
    private var nodes: [String: LatticeNode]
    private var identities: [String: NodeIdentity]
    private var runningNodes: Set<String>
    private var miningDirectories: [String: Set<String>]
    /// One background producer per node, driving `produceAndSubmitBlock` so the
    /// cluster advances without an in-node miner. Keyed by node id.
    private var producers: [String: BackgroundBlockProducer] = [:]
    private let genesisConfig: GenesisConfig
    private let baseStoragePath: URL
    private let bootstrapPeers: [PeerEndpoint]

    public init(
        genesisConfig: GenesisConfig,
        baseStoragePath: URL,
        bootstrapPeers: [PeerEndpoint] = []
    ) {
        self.nodes = [:]
        self.identities = [:]
        self.runningNodes = []
        self.miningDirectories = [:]
        self.genesisConfig = genesisConfig
        self.baseStoragePath = baseStoragePath
        self.bootstrapPeers = bootstrapPeers
    }

    // MARK: - Node Management

    public func addNode(identity: NodeIdentity) async throws -> LatticeNode {
        guard nodes[identity.id] == nil else {
            throw MultiNodeError.nodeAlreadyExists(identity.id)
        }

        let storagePath = baseStoragePath.appendingPathComponent("node-\(identity.id)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)

        var peers = bootstrapPeers
        for (otherId, _) in nodes {
            if runningNodes.contains(otherId) {
                let otherIdentity = identities[otherId]!
                peers.append(PeerEndpoint(
                    publicKey: otherIdentity.publicKey,
                    host: "127.0.0.1",
                    port: otherIdentity.port
                ))
            }
        }

        let config = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: identity.privateKey,
            listenPort: identity.port,
            bootstrapPeers: peers,
            storagePath: storagePath,
            enableLocalDiscovery: true,
            persistInterval: 50,
            // Test/cluster topology of random throwaway identities: the mainnet
            // peer-key-PoW gate (defaultMinPeerKeyBits) would reject every
            // handshake, so opt out explicitly.
            minPeerKeyBits: 0
        )

        let node = try await LatticeNode(config: config, genesisConfig: genesisConfig)
        nodes[identity.id] = node
        identities[identity.id] = identity
        miningDirectories[identity.id] = []

        return node
    }

    public func removeNode(id: String) async throws {
        guard let node = nodes[id] else {
            throw MultiNodeError.nodeNotFound(id)
        }

        if runningNodes.contains(id) {
            await node.stop()
            runningNodes.remove(id)
        }

        nodes.removeValue(forKey: id)
        identities.removeValue(forKey: id)
        miningDirectories.removeValue(forKey: id)
    }

    public func getNode(id: String) -> LatticeNode? {
        nodes[id]
    }

    public var nodeCount: Int { nodes.count }
    public var activeNodeCount: Int { runningNodes.count }
    public var allNodeIds: [String] { Array(nodes.keys.sorted()) }

    // MARK: - Lifecycle

    public func startNode(id: String) async throws {
        guard let node = nodes[id] else {
            throw MultiNodeError.nodeNotFound(id)
        }
        guard !runningNodes.contains(id) else {
            throw MultiNodeError.nodeAlreadyRunning(id)
        }

        try await node.start()
        runningNodes.insert(id)
    }

    public func stopNode(id: String) async throws {
        guard let node = nodes[id] else {
            throw MultiNodeError.nodeNotFound(id)
        }
        guard runningNodes.contains(id) else {
            throw MultiNodeError.nodeNotRunning(id)
        }

        await producers[id]?.stop()
        producers[id] = nil
        miningDirectories[id] = []

        await node.stop()
        runningNodes.remove(id)
    }

    public func startAll() async throws {
        for id in nodes.keys {
            if !runningNodes.contains(id) {
                try await startNode(id: id)
            }
        }
    }

    public func stopAll() async {
        for id in runningNodes {
            guard let node = nodes[id] else { continue }
            await producers[id]?.stop()
            producers[id] = nil
            await node.stop()
        }
        runningNodes.removeAll()
        for key in miningDirectories.keys {
            miningDirectories[key] = []
        }
    }

    // MARK: - Mining

    public func startMining(nodeId: String, directory: String) async throws {
        guard let node = nodes[nodeId] else {
            throw MultiNodeError.nodeNotFound(nodeId)
        }
        guard runningNodes.contains(nodeId) else {
            throw MultiNodeError.nodeNotRunning(nodeId)
        }

        // Each node mines its own chain; the `directory` is retained only for
        // status reporting. Block production runs through the background
        // producer, not an in-node miner.
        let producer = producers[nodeId] ?? BackgroundBlockProducer(node: node)
        producers[nodeId] = producer
        await producer.start()
        miningDirectories[nodeId, default: []].insert(directory)
    }

    public func stopMining(nodeId: String, directory: String) async throws {
        guard nodes[nodeId] != nil else {
            throw MultiNodeError.nodeNotFound(nodeId)
        }

        await producers[nodeId]?.stop()
        producers[nodeId] = nil
        miningDirectories[nodeId]?.remove(directory)
    }

    public func startMiningAll(directory: String) async throws {
        for id in runningNodes {
            try await startMining(nodeId: id, directory: directory)
        }
    }

    public func stopMiningAll(directory: String) async {
        for id in runningNodes {
            await producers[id]?.stop()
            producers[id] = nil
            miningDirectories[id]?.remove(directory)
        }
    }

    // MARK: - Transactions

    public func submitTransaction(
        nodeId: String,
        directory: String,
        transaction: Transaction
    ) async throws -> Bool {
        guard let node = nodes[nodeId] else {
            throw MultiNodeError.nodeNotFound(nodeId)
        }
        return await node.submitTransaction(directory: directory, transaction: transaction)
    }

    public func broadcastTransaction(
        directory: String,
        transaction: Transaction
    ) async -> [String: Bool] {
        var results: [String: Bool] = [:]
        for id in runningNodes {
            guard let node = nodes[id] else { continue }
            results[id] = await node.submitTransaction(directory: directory, transaction: transaction)
        }
        return results
    }

    // MARK: - Status

    public func nodeStatus(id: String) async throws -> NodeStatus {
        guard let node = nodes[id] else {
            throw MultiNodeError.nodeNotFound(id)
        }
        guard let identity = identities[id] else {
            throw MultiNodeError.nodeNotFound(id)
        }

        let nexus = await node.lattice.nexus
        let chain = await nexus.chain
        let height = await chain.getHighestBlockHeight()
        let tip = await chain.getMainChainTip()

        let mining = Array(miningDirectories[id] ?? [])

        var mempoolCount = 0
        if let network = await node.network(for: genesisConfig.directory) {
            mempoolCount = await network.nodeMempool.count
        }

        return NodeStatus(
            id: id,
            port: identity.port,
            isRunning: runningNodes.contains(id),
            miningDirectories: mining,
            chainHeight: height,
            chainTip: tip,
            mempoolCount: mempoolCount
        )
    }

    public func allNodeStatuses() async -> [NodeStatus] {
        var statuses: [NodeStatus] = []
        for id in nodes.keys.sorted() {
            if let status = try? await nodeStatus(id: id) {
                statuses.append(status)
            }
        }
        return statuses
    }

    // MARK: - Convenience: Quick Cluster Setup

    public func spawnNodes(
        count: Int,
        basePort: UInt16 = 4001
    ) async throws -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let id = "node-\(i)"
            let identity = NodeIdentity.generate(id: id, port: basePort + UInt16(i))
            let _ = try await addNode(identity: identity)
            ids.append(id)
        }
        return ids
    }
}

// MARK: - Errors

public enum MultiNodeError: Error, CustomStringConvertible {
    case nodeAlreadyExists(String)
    case nodeNotFound(String)
    case nodeAlreadyRunning(String)
    case nodeNotRunning(String)

    public var description: String {
        switch self {
        case .nodeAlreadyExists(let id): return "Node '\(id)' already exists"
        case .nodeNotFound(let id): return "Node '\(id)' not found"
        case .nodeAlreadyRunning(let id): return "Node '\(id)' is already running"
        case .nodeNotRunning(let id): return "Node '\(id)' is not running"
        }
    }
}
