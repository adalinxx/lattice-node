import Lattice
import Foundation
import cashew

/// Dev/test utility that keeps a node producing blocks by driving
/// `LatticeNode.produceAndSubmitBlock()` in a cancellable background loop.
///
/// The production node never mines in-process. The external `lattice-miner`
/// is the production miner, talking to the node over the RPC template/candidate
/// endpoints. Devnet/cluster harnesses and tests still need a node that
/// advances its own chain, so this wraps the one-shot producer in a loop
/// without reintroducing a miner into the normal node runtime.
public actor BackgroundBlockProducer {
    private let node: LatticeNode
    private let identity: MinerIdentity?
    private let timestampStepMilliseconds: Int64?
    private var task: Task<Void, Never>?

    public init(
        node: LatticeNode,
        identity: MinerIdentity? = nil,
        timestampStepMilliseconds: Int64? = nil
    ) {
        self.node = node
        self.identity = identity
        self.timestampStepMilliseconds = timestampStepMilliseconds
    }

    public var isRunning: Bool { task != nil }

    /// Start producing blocks on the node's own chain. Idempotent.
    public func start() {
        guard task == nil else { return }
        let node = self.node
        let identity = self.identity
        let timestampStepMilliseconds = self.timestampStepMilliseconds
        task = Task {
            while !Task.isCancelled {
                let timestampOverride: Int64?
                if let timestampStepMilliseconds,
                   let chain = await node.chain(for: node.genesisConfig.directory),
                   let network = await node.network(for: node.genesisConfig.directory),
                   let tip = await chain.getHighestBlock() {
                    let stub = VolumeImpl<Block>(rawCID: tip.blockHash, node: nil, encryptionInfo: nil)
                    if let tipBlock = try? await stub.resolve(fetcher: network.ivyFetcher).node {
                        timestampOverride = tipBlock.timestamp + max(1, timestampStepMilliseconds)
                    } else {
                        timestampOverride = nil
                    }
                } else {
                    timestampOverride = nil
                }
                let produced = await node.produceAndSubmitBlock(
                    identity: identity,
                    timestampOverride: timestampOverride
                )
                // Back off briefly on misses and lightly pace trivial-target chains.
                try? await Task.sleep(for: .milliseconds(produced ? 50 : 100))
            }
        }
    }

    /// Stop producing and await the in-flight block so any pending submit
    /// commits before the caller proceeds.
    public func stop() async {
        let t = task
        task = nil
        t?.cancel()
        await t?.value
    }
}
