import Lattice
import cashew
import UInt256

public struct MinerIdentity: Sendable {
    public let publicKeyHex: String
    public let privateKeyHex: String
    public let address: String

    public init(publicKeyHex: String, privateKeyHex: String) {
        self.publicKeyHex = publicKeyHex
        self.privateKeyHex = privateKeyHex
        self.address = CryptoUtils.createAddress(from: publicKeyHex)
    }
}

public struct MinedBlockPendingRemovals: Sendable {
    public let nexusTxCIDs: Set<String>
}

public struct MinedChildBlock: Sendable {
    public let chainPath: [String]
    public let block: Block
    public let proof: ChildBlockProof

    public init(chainPath: [String], block: Block, proof: ChildBlockProof) {
        self.chainPath = chainPath
        self.block = block
        self.proof = proof
    }
}

public struct ProducedMinedBlock: Sendable {
    public let block: Block
    public let pendingRemovals: MinedBlockPendingRemovals
    public let rootHash: UInt256
    public let rootClearsTarget: Bool

    public init(
        block: Block,
        pendingRemovals: MinedBlockPendingRemovals,
        rootHash: UInt256,
        rootClearsTarget: Bool
    ) {
        self.block = block
        self.pendingRemovals = pendingRemovals
        self.rootHash = rootHash
        self.rootClearsTarget = rootClearsTarget
    }

    public var hasAcceptedWork: Bool {
        rootClearsTarget
    }
}
