import Lattice
import UInt256

enum MinedChildBlockSelection {
    /// `chainPath` is rooted at the blocktree's verified PoW carrier, whatever
    /// chain type that root is. The proof path is root-exclusive.
    static func accepts(
        chainPath: [String],
        block: Block,
        childCID: String,
        rootHash: UInt256,
        proof: ChildBlockProof
    ) async -> Bool {
        guard proofPathTargetsChain(proof.directoryPath, chainPath: chainPath) else { return false }
        guard await proof.verify(rootHash: rootHash, childCID: childCID) else { return false }
        return block.validateProofOfWork(nexusHash: rootHash)
    }

    /// A proof is rooted at the actual PoW carrier, which may be Nexus or any
    /// verified descendant carrier. Therefore its root-exclusive path must match
    /// the suffix from that carrier to this chain, not always the full
    /// Nexus-exclusive path.
    static func proofPathTargetsChain(_ proofPath: [String], chainPath: [String]) -> Bool {
        guard chainPath.count >= 2 else { return false }
        return proofPathTargetsExpectedChildPath(proofPath, expectedChildPath: Array(chainPath.dropFirst()))
    }

    static func proofPathTargetsExpectedChildPath(_ proofPath: [String], expectedChildPath: [String]) -> Bool {
        guard !proofPath.isEmpty, proofPath.count <= expectedChildPath.count else { return false }
        return proofPath == Array(expectedChildPath.suffix(proofPath.count))
    }

    /// Return the proof prefix that targets `chainPath` when the wire proof is
    /// already extended farther down the tree for a descendant. Parent relay
    /// validation uses this to verify the carrier without discarding a proof that
    /// is actually destined for one of the carrier's children.
    static func projectedProof(_ proof: ChildBlockProof, targeting chainPath: [String]) -> ChildBlockProof? {
        guard chainPath.count >= 2 else { return nil }
        let expectedChildPath = Array(chainPath.dropFirst())
        if proofPathTargetsExpectedChildPath(proof.directoryPath, expectedChildPath: expectedChildPath) {
            return proof
        }
        let maxPrefix = min(proof.directoryPath.count - 1, expectedChildPath.count)
        guard maxPrefix > 0 else { return nil }
        for length in stride(from: maxPrefix, through: 1, by: -1) {
            let prefix = Array(proof.directoryPath.prefix(length))
            if prefix == Array(expectedChildPath.suffix(length)) {
                return ChildBlockProof(
                    rootCID: proof.rootCID,
                    directoryPath: prefix,
                    entries: proof.entries
                )
            }
        }
        return nil
    }
}
