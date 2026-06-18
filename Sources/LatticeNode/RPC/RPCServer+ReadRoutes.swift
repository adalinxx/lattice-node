import Lattice
import Foundation
import Hummingbird
import HTTPTypes
import LatticeLightClient
import cashew
import VolumeBroker
import UInt256

private typealias BlockTransactionDictionary = MerkleDictionaryImpl<VolumeImpl<Transaction>>
private typealias BlockChildrenDictionary = MerkleDictionaryImpl<VolumeImpl<Block>>

// Read/explorer RPC command services for RPCServer.
// Behavior-preserving extraction : balance, block, transaction-detail,
// receipt, finality, state-explorer, light-client, peers, and swap-state read
// endpoints plus block-resolution helpers. Pure relocation; no logic change.

extension RPCRoutes {
    static func getBalance(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        do {
            let balance = try await node.getBalance(address: address, chainPath: chain.path)
            struct R: Encodable { let address: String; let balance: UInt64; let chainPath: String }
            return json(R(address: address, balance: balance, chainPath: chain.key))
        } catch {
            log.error("Balance query failed for \(address): \(error)")
            return jsonError("Failed to query balance", status: .internalServerError)
        }
    }

    static func latestBlock(node: LatticeNode, request: Request) async throws -> Response {
        let resolved: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let chain): resolved = chain
        case .failure(let response): return response
        }
        guard let chain = await node.chain(forPath: resolved.path) else {
            return jsonError("Unknown chain path: \(resolved.key)", status: .notFound)
        }
        let tip = await chain.getMainChainTip()
        let s = await chain.tipSnapshot
        struct R: Encodable { let hash: String; let height: UInt64?; let timestamp: Int64?; let target: String?; let chain: String }
        return json(R(hash: tip, height: s?.tipHeight, timestamp: s?.timestamp, target: s?.target.toHexString(), chain: resolved.directory))
    }

    static func getBlock(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        var h = id
        if let i = UInt64(id) {
            guard let chainState = await node.chain(forPath: chain.path) else {
                return jsonError("Unknown chain path: \(chain.key)", status: .notFound)
            }
            var found = await chainState.getMainChainBlockHash(atIndex: i)
            if found == nil {
                found = await node.stateStore(forPath: chain.path)?.getBlockHash(atHeight: i)
            }
            guard let found else { return jsonError("Block not found at index \(i)", status: .notFound) }
            h = found
        }
        let header = VolumeImpl<Block>(rawCID: h)
        // Use canonical content storage without a DHT round-trip, so
        // orphaned/unknown CIDs still return 404 immediately.
        let localFetcher = network.canonicalContentFetcher()
        guard let b = try? await header.resolve(fetcher: localFetcher).node else { return jsonError("Block not found", status: .notFound) }
        let txCount = (try? await transactionDictionaryVolume(b.transactions).resolve(fetcher: localFetcher).node?.count) ?? 0
        let childCount = (try? await childrenDictionaryVolume(b.children).resolve(fetcher: localFetcher).node?.count) ?? 0
        struct R: Encodable {
            let hash: String; let height: UInt64; let timestamp: Int64
            let previousBlock: String?; let target: String; let nextTarget: String
            let nonce: UInt64; let version: UInt16
            let transactionsCID: String; let prevStateCID: String; let postStateCID: String
            let parentStateCID: String; let specCID: String; let childrenCID: String
            let transactionCount: Int; let childBlockCount: Int
            let chain: String
        }
        return json(R(
            hash: h, height: b.height, timestamp: b.timestamp,
            previousBlock: b.parent?.rawCID,
            target: b.target.toHexString(), nextTarget: b.nextTarget.toHexString(),
            nonce: b.nonce, version: b.version,
            transactionsCID: b.transactions.rawCID, prevStateCID: b.prevState.rawCID,
            postStateCID: b.postState.rawCID, parentStateCID: b.parentState.rawCID,
            specCID: b.spec.rawCID, childrenCID: b.children.rawCID,
            transactionCount: txCount, childBlockCount: childCount,
            chain: chain.directory
        ))
    }

    // MARK: - Block Detail Endpoints

    static func getBlockTransactions(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        let fetcher = localBlockFetcher(network: network)
        let block = try await resolveBlock(id: id, chainPath: chain.path, node: node, fetcher: fetcher)
        guard let b = block else { return jsonError("Block not found", status: .notFound) }
        guard let txNode = try? await transactionDictionaryVolume(b.transactions).resolve(paths: [[""]: .list], fetcher: fetcher).node else {
            return jsonError("Failed to resolve transactions", status: .internalServerError)
        }
        guard let allEntries = try? txNode.sortedKeysAndValues() else {
            return jsonError("Failed to enumerate transactions", status: .internalServerError)
        }
        // A block can hold up to `maxNumberOfTransactionsPerBlock` entries, and each
        // summary resolves a tx + body (2 CAS reads). The DoS risk is the
        // CONCURRENT fan-out (one task per entry), which `boundedConcurrentMap`
        // caps regardless of page size. Pagination is OPT-IN to preserve the
        // legacy "full collection" contract: with no ?limit= the whole block is
        // returned (so existing clients never silently truncate); pass ?limit=
        // (clamped 1...1000) + ?offset= to page. `total`/`nextOffset` signal more.
        let total = allEntries.count
        let limit = request.uri.queryParameters["limit"].flatMap { Int($0) }.map { max(1, min($0, 1000)) } ?? total
        let offset = max(0, request.uri.queryParameters["offset"].flatMap { Int($0) } ?? 0)
        let pageHeaders: [VolumeImpl<Transaction>] = offset < total
            ? Array(allEntries[offset..<min(offset + limit, total)]).map { $0.value }
            : []
        struct TxSummary: Encodable, Sendable {
            let txCID: String; let bodyCID: String; let fee: UInt64; let nonce: UInt64
            let signers: [String]; let accountActionCount: Int
            let depositActionCount: Int; let receiptActionCount: Int; let withdrawalActionCount: Int
        }
        // P-803: resolve tx + body pairs concurrently instead of 2N sequential CAS
        // fetches, but bound the in-flight count so a full page can't open
        // `limit` CAS tasks at once.
        let txs: [TxSummary] = await boundedConcurrentMap(pageHeaders, maxInFlight: blockContentResolveConcurrency) { txHeader in
            guard let tx = try? await txHeader.resolve(fetcher: fetcher).node else { return nil }
            let body = try? await tx.body.resolve(fetcher: fetcher).node
            return TxSummary(
                txCID: txHeader.rawCID, bodyCID: tx.body.rawCID,
                fee: body?.fee ?? 0, nonce: body?.nonce ?? 0,
                signers: body?.signers ?? [],
                accountActionCount: body?.accountActions.count ?? 0,
                depositActionCount: body?.depositActions.count ?? 0,
                receiptActionCount: body?.receiptActions.count ?? 0,
                withdrawalActionCount: body?.withdrawalActions.count ?? 0
            )
        }
        let nextOffset = offset + pageHeaders.count < total ? offset + pageHeaders.count : nil
        struct R: Encodable { let transactions: [TxSummary]; let count: Int; let total: Int; let offset: Int; let nextOffset: Int?; let blockHash: String }
        return json(R(transactions: txs, count: txs.count, total: total, offset: offset, nextOffset: nextOffset, blockHash: id))
    }

    static func getBlockChildren(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        let fetcher = localBlockFetcher(network: network)
        let block = try await resolveBlock(id: id, chainPath: chain.path, node: node, fetcher: fetcher)
        guard let b = block else { return jsonError("Block not found", status: .notFound) }
        guard let cbNode = try? await childrenDictionaryVolume(b.children).resolve(paths: [[""]: .list], fetcher: fetcher).node else {
            struct R: Encodable { let children: [String]; let count: Int }
            return json(R(children: [], count: 0))
        }
        guard let allEntries = try? cbNode.sortedKeysAndValues() else {
            struct R: Encodable { let children: [String]; let count: Int }
            return json(R(children: [], count: 0))
        }
        // Each child resolves a block + its transaction dictionary. Bounded
        // concurrency (boundedConcurrentMap) is the DoS fix; pagination is opt-in
        // (default = full collection) to preserve the legacy contract, same as
        // getBlockTransactions.
        let total = allEntries.count
        let limit = request.uri.queryParameters["limit"].flatMap { Int($0) }.map { max(1, min($0, 1000)) } ?? total
        let offset = max(0, request.uri.queryParameters["offset"].flatMap { Int($0) } ?? 0)
        let page: [(key: String, value: VolumeImpl<Block>)] = offset < total
            ? Array(allEntries[offset..<min(offset + limit, total)])
            : []
        struct ChildEntry: Encodable {
            let directory: String; let blockHash: String; let height: UInt64; let timestamp: Int64
            let target: String; let transactionCount: Int
        }
        let children: [ChildEntry] = await boundedConcurrentMap(page, maxInFlight: blockContentResolveConcurrency) { entry in
            guard let childBlock = try? await entry.value.resolve(fetcher: fetcher).node else { return nil }
            let txCount = (try? await transactionDictionaryVolume(childBlock.transactions).resolve(fetcher: fetcher).node?.count) ?? 0
            return ChildEntry(
                directory: entry.key, blockHash: entry.value.rawCID,
                height: childBlock.height, timestamp: childBlock.timestamp,
                target: childBlock.target.toHexString(),
                transactionCount: txCount
            )
        }
        let nextOffset = offset + page.count < total ? offset + page.count : nil
        struct R: Encodable { let children: [ChildEntry]; let count: Int; let total: Int; let offset: Int; let nextOffset: Int? }
        return json(R(children: children, count: children.count, total: total, offset: offset, nextOffset: nextOffset))
    }

    /// Max concurrent CAS resolves a single paged block-content request may have
    /// in flight. A page is already capped at 1000 entries; this bounds the
    /// instantaneous fan-out within a page so one request can't open one CAS
    /// task per entry at once.
    static let blockContentResolveConcurrency = 32

    /// Map `items` through `transform` with at most `maxInFlight` concurrent
    /// tasks, preserving input order and dropping nil results. Used by the block
    /// detail routes to bound their per-request CAS fan-out.
    static func boundedConcurrentMap<Item: Sendable, Out: Sendable>(
        _ items: [Item],
        maxInFlight: Int,
        _ transform: @escaping @Sendable (Item) async -> Out?
    ) async -> [Out] {
        guard !items.isEmpty else { return [] }
        let window = max(1, maxInFlight)
        var results = [Out?](repeating: nil, count: items.count)
        var next = 0
        await withTaskGroup(of: (Int, Out?).self) { group in
            while next < items.count && next < window {
                let i = next
                group.addTask { (i, await transform(items[i])) }
                next += 1
            }
            while let (i, out) = await group.next() {
                results[i] = out
                if next < items.count {
                    let j = next
                    group.addTask { (j, await transform(items[j])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    // Durable, DHT-free fetcher for block read routes.
    static func localBlockFetcher(network: ChainNetwork) -> BrokerFetcher {
        network.canonicalContentFetcher()
    }

    private static func transactionDictionaryVolume(
        _ header: HeaderImpl<BlockTransactionDictionary>
    ) -> VolumeImpl<BlockTransactionDictionary> {
        VolumeImpl<BlockTransactionDictionary>(rawCID: header.rawCID, node: header.node, encryptionInfo: header.encryptionInfo)
    }

    private static func childrenDictionaryVolume(
        _ header: HeaderImpl<BlockChildrenDictionary>
    ) -> VolumeImpl<BlockChildrenDictionary> {
        VolumeImpl<BlockChildrenDictionary>(rawCID: header.rawCID, node: header.node, encryptionInfo: header.encryptionInfo)
    }

    static func resolveBlock(id: String, chainPath: [String], node: LatticeNode, fetcher: any Fetcher) async throws -> Block? {
        var h = id
        if let i = UInt64(id) {
            guard let chain = await node.chain(forPath: chainPath) else { return nil }
            var found = await chain.getMainChainBlockHash(atIndex: i)
            if found == nil {
                found = await node.stateStore(forPath: chainPath)?.getBlockHash(atHeight: i)
            }
            guard let found else { return nil }
            h = found
        }
        let header = VolumeImpl<Block>(rawCID: h)
        return try? await header.resolve(fetcher: fetcher).node
    }

    // MARK: - Transactions

    static func balanceProof(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let proof = try await node.getBalanceProof(address: address, chainPath: chain.path) else {
            return jsonError("Proof generation failed", status: .internalServerError)
        }
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: proof)))
    }

    static func getPeers(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let peers = await node.connectedPeerEndpoints(chainPath: chain.path)
        struct P: Encodable { let publicKey: String; let host: String; let port: UInt16 }
        struct R: Encodable { let count: Int; let peers: [P] }
        return json(R(count: peers.count, peers: peers.map { P(publicKey: String($0.publicKey.prefix(16)) + "...", host: $0.host, port: $0.port) }))
    }

    // MARK: - Fee Estimation

    static func lightHeaders(node: LatticeNode, request: Request) async throws -> Response {
        let fromStr = request.uri.queryParameters["from"].map(String.init) ?? "0"
        let toStr = request.uri.queryParameters["to"].map(String.init) ?? "100"
        let from = UInt64(fromStr) ?? 0
        let maxRange: UInt64 = 500
        // Use overflow-safe addition: `from + maxRange` wraps on UInt64.max inputs
        let (ceiling, overflowed) = from.addingReportingOverflow(maxRange)
        let safeMax = overflowed ? UInt64.max : ceiling
        let to = min(UInt64(toStr) ?? 100, safeMax)

        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let store = await node.stateStore(forPath: chain.path) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        guard let chainState = await node.chain(forPath: chain.path),
              let network = await node.network(forPath: chain.path) else {
            return jsonError("Chain not available", status: .internalServerError)
        }

        let headers = await buildLightClientHeaders(
            chain: chainState,
            fetcher: network.canonicalContentFetcher(),
            stateStore: store,
            fromHeight: from,
            toHeight: to
        )
        struct R: Encodable { let headers: [ChainHeader]; let count: Int }
        return json(R(headers: headers, count: headers.count))
    }

    /// Serve canonical (main-chain) block headers in `[fromHeight, toHeight]` for
    /// light clients. Each header carries the genesis-relative cumulative PoW so a
    /// client can compare chain weight without the bodies.
    ///
    /// Hashes come from the in-memory main-chain index (durable `stateStore`
    /// fallback for body-pruned-but-indexed blocks); header fields are read from
    /// the locally-resolved block. Resolution uses the caller's local-only
    /// `fetcher`, so a height whose body has been pruned cannot be served — the
    /// walk stops at the retained window rather than blocking on a DHT fetch.
    private static func buildLightClientHeaders(
        chain: ChainState,
        fetcher: any Fetcher,
        stateStore: StateStore,
        fromHeight: UInt64,
        toHeight: UInt64
    ) async -> [ChainHeader] {
        guard fromHeight <= toHeight else { return [] }
        var headers: [ChainHeader] = []
        var height = fromHeight
        while height <= toHeight {
            guard let hash = await chain.getMainChainBlockHash(atIndex: height)
                ?? stateStore.getBlockHash(atHeight: height) else { break }
            guard let block = try? await VolumeImpl<Block>(rawCID: hash).resolve(fetcher: fetcher).node else { break }
            let cumulativeWork = (await chain.getCumulativeWork(forHash: hash)) ?? .zero
            headers.append(ChainHeader(
                hash: hash,
                height: block.height,
                previousHash: block.parent?.rawCID,
                stateRoot: block.postState.rawCID,
                target: block.target.toHexString(),
                timestamp: block.timestamp,
                cumulativeWork: cumulativeWork.toHexString()
            ))
            if height == UInt64.max { break }
            height += 1
        }
        return headers
    }

    static func lightProof(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let resolved: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let chain): resolved = chain
        case .failure(let response): return response
        }
        guard await node.chain(forPath: resolved.path) != nil else {
            return jsonError("Chain not found: \(resolved.key)", status: .notFound)
        }
        // H6: serve a verifiable proof carrying the real pruned Merkle witness so a
        // light client can confirm inclusion under stateRoot rather than trusting
        // the served (balance, accountRoot) tuple.
        guard let proofData = try await node.getBalanceProof(address: address, chainPath: resolved.path),
              let proof = try? JSONDecoder().decode(LightClientProof.self, from: proofData) else {
            return jsonError("Proof generation failed", status: .internalServerError)
        }
        return json(proof)
    }

    // MARK: - Transaction Receipts

    static func getReceipt(node: LatticeNode, txCID: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let store = await node.stateStore(forPath: chain.path),
              let network = await node.network(forPath: chain.path) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        let receiptStore = TransactionReceiptStore(store: store, fetcher: network.ivyFetcher)
        guard let receipt = await receiptStore.getReceipt(txCID: txCID) else {
            return jsonError("Receipt not found", status: .notFound)
        }
        return json(receipt)
    }

    // MARK: - Transaction Detail

    static func getTransaction(node: LatticeNode, txCID: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else {
            return jsonError("Unknown chain path: \(chain.key)", status: .notFound)
        }

        // Determine block hash: prefer explicit ?blockHash param, fall back to receipt index
        let fetcher = localBlockFetcher(network: network)
        let blockHash: String
        let blockHeight: UInt64
        let blockTimestamp: Int64
        if let explicitHash = request.uri.queryParameters["blockHash"].map(String.init) {
            guard let data = try? await fetcher.fetch(rawCid: explicitHash),
                  let b = Block(data: data) else {
                return jsonError("Block not found", status: .notFound)
            }
            blockHash = explicitHash
            blockHeight = b.height
            blockTimestamp = b.timestamp
        } else {
            guard let store = await node.stateStore(forPath: chain.path) else {
                return jsonError("State store not available", status: .internalServerError)
            }
            let receiptStore = TransactionReceiptStore(store: store, fetcher: network.ivyFetcher)
            guard let receipt = await receiptStore.getReceipt(txCID: txCID) else {
                return jsonError("Transaction not found", status: .notFound)
            }
            blockHash = receipt.blockHash
            blockHeight = receipt.blockHeight
            blockTimestamp = receipt.timestamp
        }

        // Resolve the full transaction body from the block.
        // Transaction dict keys are sequential indices ("0","1",...), not CIDs,
        // so we resolve all entries and match by rawCID.
        guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
              let block = Block(data: blockData) else {
            return jsonError("Block not found", status: .notFound)
        }
        guard let txDict = try? await block.transactions.resolve(paths: [[""]: .list], fetcher: fetcher).node,
              let entries = try? txDict.allKeysAndValues() else {
            return jsonError("Transaction not found in block", status: .notFound)
        }
        var matchedTx: Transaction?
        for (_, txHeader) in entries {
            guard txHeader.rawCID == txCID else { continue }
            matchedTx = try? await txHeader.resolve(fetcher: fetcher).node
            break
        }
        guard let tx = matchedTx else {
            return jsonError("Transaction not found in block", status: .notFound)
        }
        let body: TransactionBody
        if let n = tx.body.node {
            body = n
        } else if let resolved = try? await tx.body.resolve(fetcher: fetcher).node {
            body = resolved
        } else {
            return jsonError("Failed to resolve transaction body", status: .internalServerError)
        }

        struct AccountActionJSON: Encodable { let owner: String; let delta: Int64 }
        struct DepositActionJSON: Encodable { let nonce: String; let demander: String; let amountDemanded: UInt64; let amountDeposited: UInt64 }
        struct ReceiptActionJSON: Encodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let directory: String }
        struct WithdrawalActionJSON: Encodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let amountWithdrawn: UInt64 }
        struct R: Encodable {
            let txCID: String; let bodyCID: String
            let blockHash: String; let blockHeight: UInt64; let timestamp: Int64
            let fee: UInt64; let nonce: UInt64
            let signers: [String]; let chainPath: [String]
            let signatures: [String: String]
            let accountActions: [AccountActionJSON]
            let depositActions: [DepositActionJSON]
            let receiptActions: [ReceiptActionJSON]
            let withdrawalActions: [WithdrawalActionJSON]
            let chain: String
        }
        return json(R(
            txCID: txCID, bodyCID: tx.body.rawCID,
            blockHash: blockHash, blockHeight: blockHeight, timestamp: blockTimestamp,
            fee: body.fee, nonce: body.nonce,
            signers: body.signers, chainPath: body.chainPath,
            signatures: tx.signatures,
            accountActions: body.accountActions.map { AccountActionJSON(owner: $0.owner, delta: $0.delta) },
            depositActions: body.depositActions.map { DepositActionJSON(nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, amountDeposited: $0.amountDeposited) },
            receiptActions: body.receiptActions.map { ReceiptActionJSON(withdrawer: $0.withdrawer, nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, directory: $0.directory) },
            withdrawalActions: body.withdrawalActions.map { WithdrawalActionJSON(withdrawer: $0.withdrawer, nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, amountWithdrawn: $0.amountWithdrawn) },
            chain: chain.directory
        ))
    }

    // MARK: - Transaction History

    static func getTransactionHistory(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let store = await node.stateStore(forPath: chain.path) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        // M4: cap pagination so a single address can't force an unbounded scan.
        // ?limit= (default 100, clamped to 1...1000 — a negative limit must NOT
        // become SQLite's "no limit") + ?after=<height>:<txCID> seek cursor.
        let limit = max(1, min(request.uri.queryParameters["limit"].flatMap { Int($0) } ?? 100, 1000))
        // Cursor is the previous page's last entry encoded as "<height>:<txCID>" so
        // the seek happens in the store query (a fixed first window can't page).
        var afterHeight: UInt64?
        var afterTxCID: String?
        if let after = request.uri.queryParameters["after"].map(String.init),
           let sep = after.firstIndex(of: ":") {
            // A block height is always representable as Int64 (SQLite's column type);
            // reject a malformed/out-of-range cursor rather than trapping on the
            // unchecked Int64(afterHeight) conversion in the store.
            guard let h = UInt64(after[..<sep]), h <= UInt64(Int64.max) else {
                return jsonError("Invalid pagination cursor", status: .badRequest)
            }
            afterHeight = h
            afterTxCID = String(after[after.index(after: sep)...])
        }
        let history = store.getTransactionHistory(address: address, limit: limit, afterHeight: afterHeight, afterTxCID: afterTxCID)
        // Only advertise a next cursor when the page is full (more rows may exist).
        let nextCursor = history.count == limit ? history.last.map { "\($0.height):\($0.txCID)" } : nil
        struct Entry: Encodable { let txCID: String; let blockHash: String; let height: UInt64 }
        struct R: Encodable { let address: String; let transactions: [Entry]; let count: Int; let nextCursor: String? }
        return json(R(
            address: address,
            transactions: history.map { Entry(txCID: $0.txCID, blockHash: $0.blockHash, height: $0.height) },
            count: history.count,
            nextCursor: nextCursor
        ))
    }

    // MARK: - Finality

    static func getFinality(node: LatticeNode, height: String, request: Request) async throws -> Response {
        guard let blockHeight = UInt64(height) else {
            return jsonError("Invalid height", status: .badRequest)
        }
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let chainState = await node.chain(forPath: chain.path) else {
            return jsonError("Chain not found: \(chain.key)", status: .notFound)
        }
        let currentHeight = await chainState.getHighestBlockHeight()
        let finality = await node.config.finality
        let isFinal = finality.isFinal(chain: chain.directory, blockHeight: blockHeight, currentHeight: currentHeight)
        let confirmations = currentHeight >= blockHeight ? currentHeight - blockHeight : 0
        let required = finality.confirmations(for: chain.directory)

        struct R: Encodable {
            let height: UInt64; let currentHeight: UInt64
            let confirmations: UInt64; let required: UInt64
            let isFinal: Bool; let chain: String
        }
        return json(R(
            height: blockHeight, currentHeight: currentHeight,
            confirmations: confirmations, required: required,
            isFinal: isFinal, chain: chain.directory
        ))
    }

    static func getFinalityConfig(node: LatticeNode) async throws -> Response {
        let finality = await node.config.finality
        let chains = await node.chainStatus()
        struct ChainFinality: Encodable {
            let chain: String; let confirmations: UInt64; let currentHeight: UInt64
        }
        let configs = chains.map {
            ChainFinality(chain: $0.directory, confirmations: finality.confirmations(for: $0.directory), currentHeight: $0.height)
        }
        struct R: Encodable { let chains: [ChainFinality]; let defaultConfirmations: UInt64 }
        return json(R(chains: configs, defaultConfirmations: finality.defaultConfirmations))
    }

    // MARK: - State Explorer

    static func getAccountState(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let store = await node.stateStore(forPath: chain.path) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        let (balance, nonce) = try await node.getAccount(address: address, chainPath: chain.path)
        let exists = balance > 0 || nonce > 0
        // M4: bound the history scan explicitly; `transactionCount` reflects the
        // bounded recent window, not an unbounded enumeration of all history.
        let history = store.getTransactionHistory(address: address, limit: 50)
        struct TxEntry: Encodable { let txCID: String; let blockHash: String; let height: UInt64 }
        struct R: Encodable {
            let address: String; let chain: String
            let balance: UInt64; let nonce: UInt64; let exists: Bool
            let recentTransactions: [TxEntry]; let transactionCount: Int
        }
        return json(R(
            address: address, chain: chain.directory,
            balance: balance, nonce: nonce,
            exists: exists,
            recentTransactions: history.prefix(50).map { TxEntry(txCID: $0.txCID, blockHash: $0.blockHash, height: $0.height) },
            transactionCount: history.count
        ))
    }

    static func getStateSummary(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let store = await node.stateStore(forPath: chain.path) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        guard let chainState = await node.chain(forPath: chain.path) else {
            return jsonError("Chain not found", status: .notFound)
        }
        let height = await chainState.getHighestBlockHeight()
        let tip = await chainState.getMainChainTip()
        let stateRoot = store.getChainTip() ?? ""
        struct R: Encodable {
            let chain: String; let height: UInt64; let tip: String; let stateRoot: String
        }
        return json(R(chain: chain.directory, height: height, tip: tip, stateRoot: stateRoot))
    }

    // MARK: - Block State

    static func getBlockState(node: LatticeNode, blockId: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        let fetcher = localBlockFetcher(network: network)
        guard let block = try await resolveBlock(id: blockId, chainPath: chain.path, node: node, fetcher: fetcher) else {
            return jsonError("Block not found", status: .notFound)
        }

        // Resolve the frontier (post-block state) to get sub-tree CIDs
        let state = try? await block.postState.resolve(fetcher: fetcher).node

        struct StateSection: Encodable { let name: String; let cid: String }
        var sections: [StateSection] = []
        if let state {
            sections = [
                StateSection(name: "accountState", cid: state.accountState.rawCID),
                StateSection(name: "depositState", cid: state.depositState.rawCID),
                StateSection(name: "receiptState", cid: state.receiptState.rawCID),
                StateSection(name: "genesisState", cid: state.genesisState.rawCID),
                StateSection(name: "generalState", cid: state.generalState.rawCID),
            ]
        }

        struct R: Encodable {
            let blockHash: String; let blockHeight: UInt64
            let prevStateCID: String; let postStateCID: String
            let sections: [StateSection]; let chain: String
        }
        return json(R(
            blockHash: try VolumeImpl<Block>(node: block).rawCID,
            blockHeight: block.height,
            prevStateCID: block.prevState.rawCID,
            postStateCID: block.postState.rawCID,
            sections: sections,
            chain: chain.directory
        ))
    }

    static func getBlockAccountState(node: LatticeNode, blockId: String, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let network = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        let fetcher = localBlockFetcher(network: network)
        guard let block = try await resolveBlock(id: blockId, chainPath: chain.path, node: node, fetcher: fetcher) else {
            return jsonError("Block not found", status: .notFound)
        }

        // Resolve the frontier's account state with targeted path for this address
        guard let state = try? await block.postState.resolve(fetcher: fetcher).node else {
            return jsonError("Failed to resolve block state", status: .internalServerError)
        }
        let resolved = try? await state.accountState.resolve(paths: [[address]: .targeted], fetcher: fetcher)
        let balance: UInt64 = resolved?.node.flatMap({ try? $0.get(key: address) }) ?? 0

        struct R: Encodable {
            let address: String; let balance: UInt64; let exists: Bool
            let blockHeight: UInt64; let chain: String
        }
        return json(R(
            address: address, balance: balance, exists: balance > 0,
            blockHeight: block.height, chain: chain.directory
        ))
    }

    // MARK: - Deposit & Receipt State Queries

    static func getDepositState(node: LatticeNode, request: Request) async throws -> Response {
        guard let demander = request.uri.queryParameters["demander"].map(String.init),
              let amountStr = request.uri.queryParameters["amount"].map(String.init),
              let amount = UInt64(amountStr),
              let nonceHex = request.uri.queryParameters["nonce"].map(String.init),
              let nonce = UInt128(nonceHex, radix: 16) else {
            return jsonError("Required: ?demander=&amount=&nonce=<hex>&chainPath=<path>")
        }
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        do {
            let deposited = try await node.getDeposit(demander: demander, amountDemanded: amount, nonce: nonce, chainPath: chain.path)
            struct R: Encodable { let exists: Bool; let amountDeposited: UInt64?; let chain: String; let key: String }
            let key = DepositKey(nonce: nonce, demander: demander, amountDemanded: amount).description
            return json(R(exists: deposited != nil, amountDeposited: deposited, chain: chain.directory, key: key))
        } catch {
            log.error("Deposit state query failed: \(error)")
            return jsonError("Failed to query deposit state", status: .internalServerError)
        }
    }

    static func getReceiptState(node: LatticeNode, request: Request) async throws -> Response {
        guard let demander = request.uri.queryParameters["demander"].map(String.init),
              let amountStr = request.uri.queryParameters["amount"].map(String.init),
              let amount = UInt64(amountStr),
              let nonceHex = request.uri.queryParameters["nonce"].map(String.init),
              let nonce = UInt128(nonceHex, radix: 16) else {
            return jsonError("Required: ?demander=&amount=&nonce=<hex>&chainPath=<destinationPath>")
        }
        let basePath = await currentChainPath(node: node)
        let rawPath = request.uri.queryParameters["chainPath"].map(String.init)
        let destinationPath: [String]
        if let rawPath {
            guard let resolved = resolveChainSelector(rawPath, from: basePath) else {
                return jsonError("Invalid chainPath", status: .badRequest)
            }
            destinationPath = resolved
        } else {
            destinationPath = basePath
        }
        guard let directory = destinationPath.last else {
            return jsonError("Invalid empty chainPath", status: .badRequest)
        }
        let parentPath = destinationPath.count > 1 ? Array(destinationPath.dropLast()) : destinationPath
        guard await node.network(forPath: parentPath) != nil else {
            if let endpoint = await node.registeredRPCEndpoint(chainPath: parentPath) {
                let authToken = await node.registeredRPCAuthToken(chainPath: parentPath)
                return await proxyRegisteredRPC(endpoint: endpoint, request: request, authToken: authToken)
            }
            return jsonError("Unknown parent chain path: \(parentPath.joined(separator: "/"))", status: .notFound)
        }
        if let unavailable = await chainUnavailableResponse(node: node, chainPath: parentPath) {
            return unavailable
        }
        do {
            let withdrawer = try await node.getReceipt(demander: demander, amountDemanded: amount, nonce: nonce, destinationPath: destinationPath)
            struct R: Encodable { let exists: Bool; let withdrawer: String?; let directory: String; let chainPath: [String]; let key: String }
            let key = ReceiptKey(receiptAction: ReceiptAction(withdrawer: "", nonce: nonce, demander: demander, amountDemanded: amount, directory: directory)).description
            return json(R(exists: withdrawer != nil, withdrawer: withdrawer, directory: directory, chainPath: destinationPath, key: key))
        } catch {
            log.error("Receipt state query failed: \(error)")
            return jsonError("Failed to query receipt state", status: .internalServerError)
        }
    }

    static func listDeposits(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let limitStr = request.uri.queryParameters["limit"].map(String.init)
        let limit = min(limitStr.flatMap(Int.init) ?? 100, 1000)
        let after = request.uri.queryParameters["after"].map(String.init)
        do {
            let entries = try await node.listDeposits(chainPath: chain.path, limit: limit, after: after)
            struct DepositEntry: Encodable {
                let key: String
                let demander: String
                let amountDemanded: UInt64
                let nonce: String
                let amountDeposited: UInt64
            }
            let deposits = entries.compactMap { entry -> DepositEntry? in
                guard let dk = DepositKey(entry.key) else { return nil }
                return DepositEntry(
                    key: entry.key,
                    demander: dk.demander,
                    amountDemanded: dk.amountDemanded,
                    nonce: String(dk.nonce, radix: 16),
                    amountDeposited: entry.amountDeposited
                )
            }
            struct R: Encodable { let deposits: [DepositEntry]; let count: Int; let chain: String }
            return json(R(deposits: deposits, count: deposits.count, chain: chain.key))
        } catch {
            log.error("List deposits failed: \(error)")
            return jsonError("Failed to list deposits", status: .internalServerError)
        }
    }

    // MARK: - Health Check
}
