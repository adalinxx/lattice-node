import Foundation
import Lattice
import cashew

/// The outcome of finalizing an accepted child block's securing proofs. The node's
/// `applyInheritedWeight` path distinguishes exactly two consensus-relevant states:
/// either every effect is durably in place (or idempotently already present / a benign
/// zero-work proof — all of which `applyInheritedWeight` reports as success), or a
/// durable persistence/publish failure occurred. There is deliberately no `.unavailable`
/// or `.invalid` case here: proofs reaching this step were already PoW/path-verified at
/// the acquisition boundary and carry their own witness entries, so the only remaining
/// failure mode at finalization is local durable storage. (A richer taxonomy would be
/// dishonest — it would name outcomes the code cannot actually produce.)
enum ProofFinalizationOutcome {
    /// All decoded proofs persisted AND their inherited work durably folded into fork
    /// choice (or idempotently already present, or a benign zero-contribution proof).
    /// The block's consensus-relevant proof effects are complete.
    case finalized
    /// A durable persistence/publish failure while folding inherited work. The block may
    /// be accepted IN MEMORY, but its securing-weight effects are NOT durable — so it
    /// must NOT be treated as adopted / published / submit-succeeded. Fail closed (not
    /// the peer's fault; not retriable by waiting), exactly like any storage degradation.
    case storageFailed
}

extension LatticeNode {
    /// THE single proof-finalization step for an accepted or duplicate child block.
    ///
    /// Every ingress transport — sync, gossip, mining, held-heavier rescue — MUST route
    /// proof persistence + inherited-weight application through here, so that "adopted",
    /// "published", and "submit succeeded" all mean the SAME thing: the accepted state's
    /// consensus-relevant proof effects are durably finalized. Previously each transport
    /// inlined the same two loops and reacted to the shared `applyInheritedWeight` Bool
    /// inconsistently (sync/rescue `break`-and-adopt-anyway, gossip `return`, mining
    /// `return false`), so a durable storage failure meant three different things across
    /// transports. This choke point removes that divergence.
    func finalizeAcceptedChildProofs(
        directory: String,
        height: UInt64,
        blockHash: String,
        proofs: [ChildBlockProof],
        source: any ContentSource
    ) async -> ProofFinalizationOutcome {
        // P1-2: make the securing proof SELF-CONTAINED and DURABLE. Fold the parent
        // `receiptState` existence proof for this block's withdrawals INTO the proof
        // BEFORE persisting, so the witness is retained with the proof (retention-scoped
        // in `block_proofs`) rather than synthesized best-effort at serve time against a
        // parentState that may later be evicted. The PRODUCER (which holds the parent
        // state) enriches here; a follower's received proof already carries the witness,
        // so the fold is idempotent (entries present) or a no-op when the follower can't
        // resolve parent state. Folding into the first proof suffices — the consumer
        // merges every decoded proof's entries into one overlay.
        let witness = await selfContainedReceiptWitnessEntries(directory: directory, blockCID: blockHash)
        var durableProofs = proofs
        if !witness.isEmpty, !durableProofs.isEmpty {
            durableProofs[0] = durableProofs[0].foldingReceiptWitness(witness)
        }
        for proof in durableProofs {
            await persistAcceptedBlockProof(directory: directory, height: height, blockHash: blockHash, proof: proof)
        }
        for proof in durableProofs {
            guard await applyInheritedWeight(directory: directory, blockHash: blockHash, proof: proof, source: source) else {
                return .storageFailed
            }
        }
        return .finalized
    }
}

extension ChildBlockProof {
    /// Union `witness` CAS entries into this proof's entry set (dedup by CID, first wins).
    /// Used to fold a parent `receiptState` receipt-existence witness into a securing
    /// proof so it becomes self-contained for cross-chain withdrawal validation.
    func foldingReceiptWitness(_ witness: [(cid: String, data: Data)]) -> ChildBlockProof {
        guard !witness.isEmpty else { return self }
        var seen = Set(entries.map { $0.cid })
        var merged = entries
        for entry in witness where seen.insert(entry.cid).inserted { merged.append(entry) }
        return ChildBlockProof(rootCID: rootCID, directoryPath: directoryPath, entries: merged)
    }
}
