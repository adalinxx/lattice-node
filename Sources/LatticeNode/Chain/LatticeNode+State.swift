import Lattice
import Foundation
import LatticeLightClient
import cashew
import UInt256

extension LatticeNode {

    public struct ChainInfo: Sendable {
        public let chainPath: [String]
        public let directory: String
        public let parentDirectory: String?
        public let height: UInt64
        public let tip: String
        public let timestamp: Int64
        public let mining: Bool
        public let mempoolCount: Int
        public let syncing: Bool
        public let unhealthy: Bool
        public let health: String
        public let healthReason: String?
        // Contract 6 (fee-policy): this node's effective per-byte fee-rate floor for
        // admission on this chain. A cross-chain swap buyer must size the child
        // withdrawal fee against this value before the irreversible parent payment.
        public let minFeeRate: UInt64
    }

    public func chainStatus() async -> [ChainInfo] {
        var result: [ChainInfo] = []
        let rootPath = chainPath(forDirectory: genesisConfig.directory)
        let rootDir = rootPath.last ?? genesisConfig.directory
        let rootHeight = await lattice.nexus.chain.getHighestBlockHeight()
        let rootTip = await lattice.nexus.chain.getMainChainTip()
        let rootCommitted = statusTipHeight(
            chainPath: rootPath,
            fallbackHeight: rootHeight,
            fallbackTip: rootTip
        )
        let rootMempoolCount = await network(forPath: rootPath)?.nodeMempool.count ?? 0
        let ownParentDir: String? = {
            if let fp = config.fullChainPath, fp.count >= 2 { return fp[fp.count - 2] }
            return nil
        }()
        result.append(ChainInfo(
            chainPath: rootPath,
            directory: rootDir, parentDirectory: ownParentDir,
            height: rootCommitted.height, tip: rootCommitted.tip,
            timestamp: await lattice.nexus.chain.tipSnapshot?.timestamp ?? genesisConfig.timestamp,
            // Block production runs in the external lattice-miner, not in-node.
            mining: false, mempoolCount: rootMempoolCount,
            syncing: isSyncing,
            unhealthy: rootCommitted.unhealthy,
            health: rootCommitted.health,
            healthReason: rootCommitted.healthReason,
            minFeeRate: config.minFeeRate
        ))
        return result
    }

    private func statusTipHeight(
        chainPath: [String],
        fallbackHeight: UInt64,
        fallbackTip: String
    ) -> (height: UInt64, tip: String, unhealthy: Bool, health: String, healthReason: String?) {
        let healthState = chainHealth[chainKey(forPath: chainPath)]
        let unhealthy = healthState != nil
        let health = healthState?.label ?? "healthy"
        let healthReason = healthState?.reason
        guard unhealthy else {
            return (fallbackHeight, fallbackTip, false, health, healthReason)
        }
        guard let store = stateStore(forPath: chainPath) else {
            return (0, "", true, health, healthReason)
        }
        return (store.getHeight() ?? 0, store.getChainTip() ?? "", true, health, healthReason)
    }

    public func getBalance(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.directory
        return try await getAccount(address: address, directory: dir).balance
    }

    public func getBalance(address: String, chainPath: [String]) async throws -> UInt64 {
        try await getAccount(address: address, chainPath: chainPath).balance
    }

    public func getNextNonce(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.directory
        return try await getNonce(address: address, chainPath: chainPath(forDirectory: dir))
    }

    public func getNonce(address: String, directory: String? = nil) async throws -> UInt64 {
        try await getNextNonce(address: address, directory: directory)
    }

    public func getNonce(address: String, chainPath: [String]) async throws -> UInt64 {
        guard let tip = try await resolveTipFrontier(chainPath: chainPath) else { return 0 }
        let nonceKey = AccountStateHeader.nonceTrackingKey(address)
        let accountResolved = try await tip.state.accountState.resolve(
            paths: [[nonceKey]: .targeted],
            fetcher: tip.fetcher
        )
        guard let dict = accountResolved.node else { return 0 }
        let stored: UInt64? = try? dict.get(key: nonceKey)
        guard let last = stored else { return 0 }
        let (next, overflow) = last.addingReportingOverflow(1)
        return overflow ? UInt64.max : next
    }

    public func getAccount(address: String, directory: String? = nil) async throws -> (balance: UInt64, nonce: UInt64) {
        let dir = directory ?? genesisConfig.directory
        return try await getAccount(address: address, chainPath: chainPath(forDirectory: dir))
    }

    public func getAccount(address: String, chainPath: [String]) async throws -> (balance: UInt64, nonce: UInt64) {
        guard let tip = try await resolveTipFrontier(chainPath: chainPath) else { return (0, 0) }
        let nonceKey = AccountStateHeader.nonceTrackingKey(address)
        let accountResolved = try await tip.state.accountState.resolve(
            paths: [[address]: .targeted, [nonceKey]: .targeted],
            fetcher: tip.fetcher
        )
        guard let dict = accountResolved.node else { return (0, 0) }
        let balance: UInt64 = (try? dict.get(key: address)) ?? 0
        let stored: UInt64? = try? dict.get(key: nonceKey)
        let nonce: UInt64
        if let last = stored {
            let (next, overflow) = last.addingReportingOverflow(1)
            nonce = overflow ? UInt64.max : next
        } else {
            nonce = 0
        }
        return (balance, nonce)
    }

    /// Batch variant — resolves all balances and nonces in a single tree walk.
    /// Used by mining and block-assembly hot paths that need many addresses at once.
    public func batchGetAccounts(addresses: [String], directory: String? = nil) async throws -> [String: (balance: UInt64, nonce: UInt64)] {
        guard !addresses.isEmpty else { return [:] }
        let dir = directory ?? genesisConfig.directory
        guard let tip = try await resolveTipFrontier(directory: dir) else { return [:] }
        var paths = [[String]: ResolutionStrategy]()
        paths.reserveCapacity(addresses.count * 2)
        for addr in addresses {
            paths[[addr]] = .targeted
            paths[[AccountStateHeader.nonceTrackingKey(addr)]] = .targeted
        }
        let resolved = try await tip.state.accountState.resolve(paths: paths, fetcher: tip.fetcher)
        guard let dict = resolved.node else { return [:] }
        var out: [String: (balance: UInt64, nonce: UInt64)] = [:]
        out.reserveCapacity(addresses.count)
        for addr in addresses {
            let balance: UInt64 = (try? dict.get(key: addr)) ?? 0
            let nonce: UInt64 = (try? dict.get(key: AccountStateHeader.nonceTrackingKey(addr))) ?? 0
            out[addr] = (balance, nonce)
        }
        return out
    }

    private func resolveTipFrontier(directory: String) async throws -> (state: LatticeState, fetcher: Fetcher)? {
        try await resolveTipFrontier(chainPath: chainPath(forDirectory: directory))
    }

    private func resolveTipFrontier(chainPath: [String]) async throws -> (state: LatticeState, fetcher: Fetcher)? {
        guard !isChainUnavailable(chainPath: chainPath) else {
            let displayPath = chainPath.isEmpty ? genesisConfig.directory : chainPath.joined(separator: "/")
            throw NodeError.chainUnavailable(displayPath)
        }
        guard let network = network(forPath: chainPath) else { return nil }
        guard let chain = await chain(forPath: chainPath) else { return nil }
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierCID = snapshot.postStateCID
        let fetcher = await network.fetcher
        if let cached = postStateCaches[chainKey(forPath: chainPath)]?.get(frontierCID: frontierCID) {
            return (cached, fetcher)
        }
        let frontierHeader = LatticeStateHeader(rawCID: frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: fetcher)
        guard let state = resolved.node else { return nil }
        postStateCaches[chainKey(forPath: chainPath)]?.set(frontierCID: frontierCID, state: state)
        return (state, fetcher)
    }

    public func getBlock(hash: String, directory: String? = nil) async throws -> Block? {
        let dir = directory ?? genesisConfig.directory
        guard !isChainUnavailable(directory: dir) else {
            throw NodeError.chainUnavailable(dir)
        }
        guard let network = network(for: dir) else { return nil }
        let header = VolumeImpl<Block>(rawCID: hash)
        return try await header.resolve(fetcher: network.fetcher).node
    }

    public func getBlockHash(atIndex index: UInt64, directory: String? = nil) async -> String? {
        let dir = directory ?? genesisConfig.directory
        guard !isChainUnavailable(directory: dir) else { return nil }
        if let chainState = await chain(for: dir),
           let hash = await chainState.getMainChainBlockHash(atIndex: index) {
            return hash
        }
        return stateStores[chainKey(forDirectory: dir)]?.getBlockHash(atHeight: index)
    }

    public func getDeposit(demander: String, amountDemanded: UInt64, nonce: UInt128, chainPath: [String]) async throws -> UInt64? {
        guard let tip = try await resolveTipFrontier(chainPath: chainPath) else { return nil }
        let key = DepositKey(nonce: nonce, demander: demander, amountDemanded: amountDemanded).description
        let depositResolved = try await tip.state.depositState.resolve(paths: [[key]: .targeted], fetcher: tip.fetcher)
        guard let depositDict = depositResolved.node else { return nil }
        return try? depositDict.get(key: key)
    }

    public func getReceipt(demander: String, amountDemanded: UInt64, nonce: UInt128, destinationPath: [String]) async throws -> String? {
        guard let directory = destinationPath.last else { return nil }
        let parentPath = destinationPath.count > 1 ? Array(destinationPath.dropLast()) : destinationPath
        guard let tip = try await resolveTipFrontier(chainPath: parentPath) else { return nil }
        let key = ReceiptKey(receiptAction: ReceiptAction(withdrawer: "", nonce: nonce, demander: demander, amountDemanded: amountDemanded, directory: directory)).description
        // Resolve via a SCOPED sparse-merkle proof for this one key — the same primitive
        // consensus uses to read a receipt's withdrawer in withdrawal validation
        // (Lattice ReceiptState.proveExistenceAndVerifyWithdrawers). This is correct on
        // all three axes that the resolve-based strategies are not:
        //   - SCOPED: `proof(paths:)` only recurses the queried key's path and returns
        //     off-path children as-is (cashew MerkleDictionary+proofs.swift:8-37), so it
        //     does NOT walk the whole receiptState trie — avoiding the unauthenticated
        //     O(all-receipts) DoS that `[[""]: .list]` would incur on mainnet.
        //   - NO VALUE HYDRATION: it yields the leaf's CID (`stored.rawCID` == the
        //     withdrawer) without fetching the value node, so a just-mined / merged-mined
        //     receipt whose value isn't locally materialized doesn't throw `notFound`
        //     (the bug that `.targeted` and a keyed `.list` both hit).
        //   - GRACEFUL ABSENCE: `.existence` (unlike `.mutation`/`.deletion`, which throw
        //     on a non-existent child, ibid. :17) returns an absence proof, so polling a
        //     not-yet-mined receipt yields `get(key:) == nil` → not found, not an error.
        let proven = try await tip.state.receiptState.proof(paths: [[key]: .existence], fetcher: tip.fetcher)
        guard let receiptDict = proven.node else { return nil }
        guard let stored: HeaderImpl<PublicKey> = try? receiptDict.get(key: key) else { return nil }
        return stored.rawCID
    }

    public func listDeposits(chainPath: [String], limit: Int = 100, after: String? = nil) async throws -> [(key: String, amountDeposited: UInt64)] {
        guard let tip = try await resolveTipFrontier(chainPath: chainPath) else { return [] }
        // Bounded, fetcher-backed page (cashew 3.4.0): boundedKeysAndValues resolves only
        // the radix nodes on the page's path — pruning pre-cursor branches without fetching
        // them and stopping at `limit` — so cost is O(limit + depth), not O(all deposits).
        // This replaces `resolveRecursive` (which hydrated the ENTIRE depositState on every
        // call) AND the interim `.range` resolve (whose resolver ignores `limit`, and whose
        // sortedKeysAndValues throws nodeNotAvailable on unresolved pre-cursor branches) —
        // both of which left GET /api/deposits an unauthenticated O(all-deposits) walk.
        guard let depositDict = try await tip.state.depositState.resolve(fetcher: tip.fetcher).node else { return [] }
        let entries = try await depositDict.boundedKeysAndValues(after: after, limit: limit, fetcher: tip.fetcher)
        return entries.map { (key: $0.key, amountDeposited: $0.value) }
    }

    /// Discover the child chains announced by `chainPath`: a bounded page of the chain's
    /// on-chain `GenesisState` (`directory -> genesisBlockCID`, written by each genesisAction).
    /// Any node that synced `chainPath` can enumerate its immediate children with no knowledge
    /// of who deployed or runs them. Uses cashew 3.4.0 `boundedKeysAndValues` — the same
    /// O(limit+depth) bounded read as `listDeposits`, so it never walks the whole genesisState
    /// trie. Deeper descendants become enumerable once their parent is followed and synced.
    public func listChildChains(chainPath: [String], limit: Int = 100, after: String? = nil) async throws -> [(directory: String, genesisHash: String)] {
        guard let tip = try await resolveTipFrontier(chainPath: chainPath) else { return [] }
        guard let genesisDict = try await tip.state.genesisState.resolve(fetcher: tip.fetcher).node else { return [] }
        let entries = try await genesisDict.boundedKeysAndValues(after: after, limit: limit, fetcher: tip.fetcher)
        return entries.map { (directory: $0.key, genesisHash: $0.value) }
    }

    /// Resolve a single announced child's genesis block CID from the PARENT chain's on-chain
    /// `GenesisState`. Permissionless: a node that synced the parent holds this with no
    /// knowledge of who deployed or runs the child. Scoped `.existence` proof (same primitive
    /// as `getReceipt`) — reads one key, never walks the whole genesisState trie. Returns nil
    /// when the child isn't announced on the parent (or the parent isn't synced here).
    public func announcedChildGenesisCID(chainPath: [String]) async -> String? {
        guard chainPath.count >= 2, let directory = chainPath.last else { return nil }
        let parentPath = Array(chainPath.dropLast())
        guard let tip = try? await resolveTipFrontier(chainPath: parentPath) else { return nil }
        guard let proven = try? await tip.state.genesisState.proof(paths: [[directory]: .existence], fetcher: tip.fetcher),
              let dict = proven.node,
              let genesisCID = try? dict.get(key: directory) else { return nil }
        return genesisCID
    }

    public func getBalanceProof(address: String, directory: String? = nil) async throws -> Data? {
        let dir = directory ?? genesisConfig.directory
        return try await getBalanceProof(address: address, chainPath: chainPath(forDirectory: dir))
    }

    public func getBalanceProof(address: String, chainPath: [String]) async throws -> Data? {
        guard let chain = await chain(forPath: chainPath) else { return nil }
        guard let network = network(forPath: chainPath) else { return nil }
        let blockHash = await chain.getMainChainTip()
        let fetcher = await network.fetcher
        guard let block = try? await VolumeImpl<Block>(rawCID: blockHash).resolve(fetcher: fetcher).node,
              let state = try await resolvePostStateForProof(
                stateRoot: block.postState.rawCID,
                cacheKey: chainKey(forPath: chainPath),
                fetcher: fetcher
              ) else { return nil }
        let cumulativeWork = (await chain.getCumulativeWork(forHash: blockHash)) ?? .zero
        return try await encodeBalanceProof(
            address: address,
            state: state,
            fetcher: fetcher,
            header: lightClientHeader(block: block, blockHash: blockHash, cumulativeWork: cumulativeWork)
        )
    }

    /// Height of the parent-chain block that this chain's current tip references via
    /// `parentState`. Returns `nil` for the root chain (no parent) or when the tip
    /// has not yet referenced any parent block.
    public func getParentChainHeight(chainPath: [String]) async -> UInt64? {
        guard let chain = await self.chain(forPath: chainPath) else { return nil }
        // Read from the persisted child-parent anchor: the normal block-submission path
        // does not populate the Lattice parentIndex field, so a block accepted via
        // processBlockHeader can have parentIndex == nil even when its parent anchor is
        // durably stored in the StateStore.
        if let tipHash = await chain.getHighestBlock()?.blockHash,
           let store = stateStore(forPath: chainPath),
           let parentHash = store.getChildParentAnchor(childHash: tipHash),
           let header = store.getParentHeader(parentHash: parentHash) {
            return header.height
        }
        return await chain.getHighestBlock()?.parentIndex
    }

    private func resolvePostStateForProof(
        stateRoot: String,
        cacheKey: String,
        fetcher: Fetcher
    ) async throws -> LatticeState? {
        if let cached = postStateCaches[cacheKey]?.get(frontierCID: stateRoot) {
            return cached
        }
        let resolved = try await LatticeStateHeader(rawCID: stateRoot).resolve(fetcher: fetcher)
        guard let state = resolved.node else { return nil }
        postStateCaches[cacheKey]?.set(frontierCID: stateRoot, state: state)
        return state
    }

    private func lightClientHeader(block: Block, blockHash: String, cumulativeWork: UInt256) -> ChainHeader {
        ChainHeader(
            hash: blockHash,
            height: block.height,
            previousHash: block.parent?.rawCID,
            stateRoot: block.postState.rawCID,
            target: block.target.toHexString(),
            timestamp: block.timestamp,
            cumulativeWork: cumulativeWork.toHexString()
        )
    }

    /// H6: serialize a verifiable balance proof carrying the REAL pruned Merkle
    /// witness (LatticeState wrapper + account-path nodes), so a light client can
    /// recompute the account-state CID, confirm it is committed under `stateRoot`,
    /// and read the balance from the verified leaf — rather than trusting a bare
    /// `(balance, accountRoot)` tuple with no inclusion evidence.
    private func encodeBalanceProof(
        address: String,
        state: LatticeState,
        fetcher: Fetcher,
        header: ChainHeader
    ) async throws -> Data? {
        // Resolve balance AND the stored nonce from the SAME tip account subtree. The
        // nonce lives under the reserved "_nonce_<address>" key; it is INSERTED on the
        // account's first signed tx (nonce 0) with stored value 0, so presence — not
        // value > 0 — decides existence. `storedNonce == nil` ⇒ the key is absent (the
        // account never signed); a present key may legitimately hold 0.
        let nonceKey = AccountStateHeader.nonceTrackingKey(address)
        let accountResolved = try await state.accountState.resolve(
            paths: [[address]: .targeted, [nonceKey]: .targeted], fetcher: fetcher
        )
        let balance: UInt64 = accountResolved.node.flatMap { try? $0.get(key: address) } ?? 0
        let storedNonce: UInt64? = accountResolved.node.flatMap { try? $0.get(key: nonceKey) }
        // LightClientProof.nonce is the STORED on-chain nonce (the last-used value the
        // witness proves) — NOT getNonce's "next" nonce (stored + 1).
        let nonce = storedNonce ?? 0
        // Always cover the nonce key in the witness: .existence when the key is present
        // (incl. stored 0), .insertion (absence proof) when it is absent — so the proof
        // is self-contained and the client can verify the nonce in either case.
        let (accountRoot, witness) = try await LightClientProtocol.collectAccountWitness(
            state: state,
            stateRoot: header.stateRoot,
            address: address,
            nonceExists: storedNonce != nil,
            fetcher: fetcher
        )
        let proof = await LightClientProtocol.buildAccountProof(
            address: address,
            balance: balance,
            nonce: nonce,
            blockHash: header.hash,
            blockHeight: header.height,
            header: header,
            stateRoot: header.stateRoot,
            timestamp: header.timestamp,
            accountRoot: accountRoot,
            witness: witness
        )
        return try JSONEncoder().encode(proof)
    }
}
