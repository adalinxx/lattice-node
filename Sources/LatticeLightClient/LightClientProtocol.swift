import Foundation
import Lattice
import cashew

// Kept below LatticeNode so clients can verify proofs without node, network, or
// storage machinery.

public struct LightClientProof: Codable, Sendable {
    /// The complete block lets verification recompute its CID and bind the
    /// witnessed state root to content-addressed consensus data. A client still
    /// verifies the block's ancestry and fork choice separately.
    public let block: Block
    public let address: String
    public let balance: UInt64
    /// The STORED on-chain nonce: the value witnessed under `_nonce_<address>`
    /// (the account's last-used nonce), or 0 when the key is absent (never signed).
    /// This is what the Merkle witness proves — it is NOT the RPC `getNonce`'s
    /// "next" nonce (stored + 1); a sender computes its next nonce as `nonce + 1`.
    public let nonce: UInt64
    /// CID of the proven account-state subtree. Bound to `stateRoot` by the
    /// witness (the LatticeState committed under `stateRoot` references this CID
    /// as its `accountState`).
    public let accountRoot: String
    /// The real pruned Merkle witness: the minimal set of DAG-CBOR nodes a light
    /// client needs to (a) recompute `accountRoot` from the account-path nodes,
    /// (b) confirm `accountRoot` is committed under `stateRoot` via the
    /// LatticeState wrapper node, and (c) read the proven balance from the
    /// verified account leaf. Each entry's bytes are content-bound to its CID.
    public let witness: [WitnessNode]

    public init(
        block: Block,
        address: String,
        balance: UInt64,
        nonce: UInt64,
        accountRoot: String,
        witness: [WitnessNode]
    ) {
        self.block = block
        self.address = address
        self.balance = balance
        self.nonce = nonce
        self.accountRoot = accountRoot
        self.witness = witness
    }

    /// One content-addressed node of the pruned witness DAG. `data` is the
    /// base64-encoded DAG-CBOR serialization of the node stored under `cid`.
    public struct WitnessNode: Codable, Sendable {
        public let cid: String
        public let data: String

        public init(cid: String, data: Data) {
            self.cid = cid
            self.data = data.base64EncodedString()
        }

        public var rawData: Data? { Data(base64Encoded: data) }
    }
}

public enum LightClientProtocol {
    /// Collect the pruned Merkle witness that proves `address`'s account leaf is
    /// committed under `stateRoot`. Returns the (accountRoot, witness-nodes) pair:
    ///
    ///  - the LatticeState wrapper node committed under `stateRoot` (binds
    ///    `accountRoot` as its `accountState`), and
    ///  - the pruned account-state subtree along the radix path to `address`
    ///    (its top node hashes to `accountRoot`).
    ///
    /// The returned `accountRoot` is the proof result's own CID; its bytes and the
    /// wrapper's bytes are content-addressed, so a verifier recomputes both CIDs
    /// and rejects any tampered witness.
    public static func collectAccountWitness(
        state: LatticeState,
        stateRoot: String,
        address: String,
        balanceExists: Bool = true,
        nonceExists: Bool,
        fetcher: any Fetcher
    ) async throws -> (accountRoot: String, witness: [LightClientProof.WitnessNode]) {
        // Prove the balance leaf AND the nonce leaf on EVERY proof so it is
        // self-contained: `.existence` when the "_nonce_<address>" key exists,
        // `.insertion` (the non-existence / would-insert proof) when it does not.
        // Without the insertion proof a zero-nonce proof is not verifiable —
        // `verify` could default missing data to 0 with no absence witness.
        let proofPaths: [[String]: SparseMerkleProof] = [
            [address]: balanceExists ? .existence : .insertion,
            [AccountStateHeader.nonceTrackingKey(address)]: nonceExists ? .existence : .insertion,
        ]
        let proof = try await state.accountState.proof(paths: proofPaths, fetcher: fetcher)

        let storer = _ProofCollectingStorer()
        // Store the two proven paths, not every reference reachable from the
        // sparse proof: unrelated siblings are intentionally unresolved.
        try await proof.store(
            paths: [
                [address]: .targeted,
                [AccountStateHeader.nonceTrackingKey(address)]: .targeted,
            ],
            storer: storer
        )
        // The LatticeState wrapper node committed under stateRoot. Store only the
        // wrapper's own bytes (not its full sub-trees) so the witness stays pruned
        // while still binding accountRoot → stateRoot.
        if let wrapperData = state.toData() {
            try await storer.store(entries: [stateRoot: wrapperData])
        }

        let witness = await storer.entries.sorted { $0.key < $1.key }.map {
            LightClientProof.WitnessNode(cid: $0.key, data: $0.value)
        }
        return (proof.rawCID, witness)
    }

    /// Verify a balance proof end-to-end from its own witness, fail-closed:
    ///  (0) recompute the complete block's CID and use its post-state root,
    ///  (a) recompute `accountRoot` from the witness's account-path nodes,
    ///  (b) confirm `accountRoot` is committed under `stateRoot` (the LatticeState
    ///      wrapper node stored under `stateRoot` references it as `accountState`),
    ///  (c) read the balance from the verified account leaf and confirm it equals
    ///      the proof's claimed balance.
    ///
    /// The witness's CID→bytes map is attacker-supplied, so every node fetched is
    /// content-bound: bytes stored under a CID must hash back to it.
    /// Returns the content-addressed block CID anchoring a valid state witness.
    /// The caller must independently verify that block's ancestry and fork
    /// choice; returning the CID makes that required comparison explicit.
    public static func verify(_ proof: LightClientProof) async -> String? {
        guard !proof.witness.isEmpty, !proof.accountRoot.isEmpty,
              let blockCID = try? BlockHeader(node: proof.block).rawCID else {
            return nil
        }
        let stateRoot = proof.block.postState.rawCID

        // Verification runs over ONLY the proof's witness nodes, in a sealed
        // in-memory source. `InMemoryContentSource` has no tier chain — it cannot
        // reach the network by construction — so a self-contained proof is
        // enforced by the type, not by convention.
        var witnessMap: [String: Data] = [:]
        witnessMap.reserveCapacity(proof.witness.count)
        for node in proof.witness {
            guard let data = node.rawData else { return nil }
            guard witnessMap.updateValue(data, forKey: node.cid) == nil else {
                return nil
            }
        }
        let fetcher = InMemoryContentSource(witnessMap)

        // (b) The LatticeState wrapper committed under stateRoot must be present and
        // content-bound, and must reference the claimed accountRoot as accountState.
        guard let stateData = try? await fetcher.fetch(rawCid: stateRoot),
              let stateNode = LatticeState(data: stateData),
              // known-valid local node; CID cannot fail
              try! LatticeStateHeader(node: stateNode).rawCID == stateRoot,
              stateNode.accountState.rawCID == proof.accountRoot else {
            return nil
        }

        // (a)+(c) Resolve the account leaf (and the nonce key when claimed) from the
        // pruned account subtree at accountRoot. Targeted resolution recomputes node
        // CIDs along each path; a tampered node fails content-binding inside cashew.
        let nonceKey = AccountStateHeader.nonceTrackingKey(proof.address)
        let accountHeader = AccountStateHeader(rawCID: proof.accountRoot)
        guard let accountNode = try? await accountHeader.resolve(
            paths: [[proof.address]: .targeted, [nonceKey]: .targeted], fetcher: fetcher
        ).node else {
            return nil
        }
        let balance: UInt64 = (try? accountNode.get(key: proof.address)) ?? 0
        guard balance == proof.balance else { return nil }
        // A non-zero claimed nonce must be backed by the witnessed nonce leaf. A
        // zero claim is valid only when resolving the nonce path succeeds and no
        // nonce value is present; for absent keys, the witness carries an insertion
        // proof for that path.
        let witnessedNonce: UInt64 = (try? accountNode.get(key: nonceKey)) ?? 0
        guard witnessedNonce == proof.nonce else { return nil }
        return blockCID
    }
}

private actor _ProofCollectingStorer: Storer {
    private(set) var entries: [String: Data] = [:]

    func store(entries newEntries: [String: Data]) async throws {
        for (cid, data) in newEntries {
            entries[cid] = data
        }
    }
}
