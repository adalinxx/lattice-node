import Lattice
import Foundation
import cashew

extension TransactionValidationError {
    /// M9: typed predicate replacing the fragile `reason.contains("no
    /// corresponding deposit")` string match in reorg orphan recovery. A
    /// withdrawal whose backing deposit is momentarily non-canonical after a
    /// reorg fails validation with exactly this case; recovery tolerates it and
    /// re-admits through the cumulative-bound seam.
    var isWithdrawalWithoutDeposit: Bool {
        if case .withdrawalWithoutDeposit = self { return true }
        return false
    }
}

struct MempoolAdmission: Sendable {
    let result: AddResult
    let consensusClass: ConsensusClass?
}

extension MempoolRejectionKind {
    /// R5: peer-penalty classification of a `NodeMempool.addTransaction`
    /// rejection, keyed on the typed kind — NEVER on the human message, so a
    /// reworded message cannot silently reclassify a GossipAdmission decision.
    /// `nil` means a capacity (mempool-full) rejection: the gossip layer
    /// penalizes the flooding SOURCE rather than classifying the transaction.
    /// The switch is exhaustive on purpose — adding a kind forces an explicit
    /// classification decision here.
    var mempoolAddConsensusClass: ConsensusClass? {
        switch self {
        case .full:
            return nil
        case .nonceConfirmed, .nonceGap, .cumulativeDebit:
            return .missingInput
        case .missingBody, .duplicate, .feeFloor, .feeRateFloor,
             .multiSignerNonceConflict, .accountLimit, .oversizedBody,
             .feeRateOutbid, .rbfUnderpay, .rbfStateKeyConflict, .rbfByteBudget:
            return .policy
        // Admission-funnel kinds never flow through addTransaction; their
        // ConsensusClass is set explicitly where they are constructed. Mapped
        // to the legacy catch-all for totality.
        case .unknownChain, .chainUnavailable, .invalidChainPath,
             .validationFailed, .policyViolation, .stateUnavailable:
            return .policy
        }
    }
}

extension LatticeNode {

    public func submitTransaction(directory: String, transaction: Transaction) async -> Bool {
        switch await submitTransactionWithReason(directory: directory, transaction: transaction) {
        case .success: return true
        case .failure: return false
        }
    }

    public enum TransactionSubmitResult: Sendable {
        case success
        case failure(String)
    }

    /// R4: thin resolver onto the single chainPath funnel. The guard preserves
    /// the directory-form "Unknown chain" message for callers that submit by
    /// leaf directory.
    public func submitTransactionWithReason(directory: String, transaction: Transaction) async -> TransactionSubmitResult {
        guard network(for: directory) != nil else {
            return .failure("Unknown chain: \(directory)")
        }
        return await submitTransactionWithReason(chainPath: chainPath(forDirectory: directory), transaction: transaction)
    }

    public func submitTransactionWithReason(chainPath: [String], transaction: Transaction) async -> TransactionSubmitResult {
        guard let network = network(forPath: chainPath) else {
            return .failure("Unknown chain path: \(chainPath.joined(separator: "/"))")
        }
        let addResult = await admitToMempool(transaction: transaction, chainPath: chainPath)
        switch addResult {
        case .rejected(let reason):
            return .failure(reason.message)
        case .added, .replacedExisting:
            break
        }
        metrics.increment("lattice_transactions_submitted_total")
        if let bodyData = transaction.body.node?.toData(),
           let txData = transaction.toData() {
            await network.storeLocally(cid: transaction.body.rawCID, data: bodyData)
            // Also store the whole Transaction closure (Transaction volume + body)
            // so this node can serve the volume a block references by root, not
            // only the standalone body node.
            await network.storeTransactionClosure(transaction)
            await network.gossipTransaction(cid: transaction.body.rawCID, bodyData: bodyData, transactionData: txData)
        }
        let fee = transaction.body.node?.fee ?? 0
        let sender = transaction.body.node?.signers.first ?? ""
        await subscriptions.emit(.newTransaction(
            cid: transaction.body.rawCID,
            fee: fee,
            sender: sender
        ))
        return .success
    }

    /// Unified mempool admission for any chain. One classifier funnels:
    ///   - direct submit (RPC, restart restoration)
    ///   - gossip-received transactions
    ///   - reorg orphan re-add (nexus and child)
    ///
    /// With automatic receipts (v2), there is no pending pool. All
    /// transactions are either admitted as valid or rejected outright.
    /// `allowWithdrawalWithoutDeposit` — M9: reorg orphan-recovery re-admits a
    /// withdrawal whose backing deposit is momentarily non-canonical on the new
    /// chain (it will be re-confirmed). Set this flag ONLY on that recovery path
    /// so the validator's `.withdrawalWithoutDeposit` failure is tolerated. The
    /// tx is then admitted through the SAME `addTransaction` seam every other tx
    /// uses — with the sender's resolved confirmed balance and net-debit threaded
    /// in — so the cumulative per-sender double-spend bound still runs (the prior
    /// raw `addTransaction(confirmedBalance: nil)` bypass is removed).
    public func admitToMempool(
        transaction: Transaction,
        directory: String,
        allowWithdrawalWithoutDeposit: Bool = false
    ) async -> AddResult {
        await admitToMempoolAdmission(
            transaction: transaction,
            directory: directory,
            allowWithdrawalWithoutDeposit: allowWithdrawalWithoutDeposit
        ).result
    }

    /// R4: thin resolver onto the SINGLE chainPath funnel below — the two
    /// ~100-line hand-maintained copies had already drifted (only the directory
    /// variant carried the M9 toleration + balance fallback; isNexus was
    /// computed by two different formulas). The guard preserves the
    /// directory-form "Unknown chain" message; everything else — availability,
    /// validation, policy, nonce refresh, the cumulative-bound admission — runs
    /// once, in the chainPath funnel.
    func admitToMempoolAdmission(
        transaction: Transaction,
        directory: String,
        allowWithdrawalWithoutDeposit: Bool = false
    ) async -> MempoolAdmission {
        guard network(for: directory) != nil else {
            return MempoolAdmission(result: .rejected(.unknownChain, "Unknown chain: \(directory)"), consensusClass: .missingInput)
        }
        return await admitToMempoolAdmission(
            transaction: transaction,
            chainPath: chainPath(forDirectory: directory),
            allowWithdrawalWithoutDeposit: allowWithdrawalWithoutDeposit
        )
    }

    public func admitToMempool(transaction: Transaction, chainPath: [String]) async -> AddResult {
        await admitToMempoolAdmission(transaction: transaction, chainPath: chainPath).result
    }

    func admitToMempoolAdmission(
        transaction: Transaction,
        chainPath: [String],
        allowWithdrawalWithoutDeposit: Bool = false
    ) async -> MempoolAdmission {
        guard let network = network(forPath: chainPath) else {
            return MempoolAdmission(
                result: .rejected(.unknownChain, "Unknown chain path: \(chainPath.joined(separator: "/"))"),
                consensusClass: .missingInput
            )
        }
        guard let body = transaction.body.node else {
            return MempoolAdmission(result: .rejected(.missingBody, "Missing transaction body"), consensusClass: .consensusInvalid)
        }
        guard !chainPath.isEmpty else {
            return MempoolAdmission(result: .rejected(.invalidChainPath, "Invalid empty chainPath"), consensusClass: .missingInput)
        }
        guard !isChainUnavailable(chainPath: chainPath) else {
            return MempoolAdmission(
                result: .rejected(.chainUnavailable, "Chain \(chainPath.joined(separator: "/")) is unavailable"),
                consensusClass: .transient
            )
        }

        if let chain = await chain(forPath: chainPath) {
            let isNexus = chainPath.count == 1
            let validator = TransactionValidator(
                fetcher: await network.fetcher,
                chainState: chain,
                frontierCache: postStateCaches[chainKey(forPath: chainPath)],
                expectedChainPath: chainPath,
                isNexus: isNexus
            )
            let (result, _, _, confirmedNonceBySigner, balanceByOwner) = await validator.validate(transaction)
            if case .failure(let error) = result {
                // M9: tolerate ONLY the typed withdrawal-without-deposit failure on
                // the reorg-recovery path, replacing the prior fragile string match.
                // The deposit-bearing block re-confirms shortly; meanwhile the tx is
                // re-admitted through the cumulative-bound seam below.
                let toleratedWithdrawal = allowWithdrawalWithoutDeposit
                    && error.isWithdrawalWithoutDeposit
                    && !body.withdrawalActions.isEmpty
                if !toleratedWithdrawal {
                    return MempoolAdmission(
                        result: .rejected(.validationFailed, describeValidationError(error)),
                        consensusClass: error.consensusClass
                    )
                }
            }
            if let policyError = await validateWasmPoliciesForMempool(body: body, chain: chain, network: network, chainPath: chainPath) {
                return MempoolAdmission(
                    result: .rejected(.policyViolation, policyError),
                    consensusClass: classifyMempoolPolicyError(policyError)
                )
            }
            // Refresh confirmedNonce BEFORE addTransaction so the nonce-gap check
            // in addTransaction uses the real on-chain nonce, not a stale cached
            // value (e.g. after headers-first sync that skips block-apply nonce
            // updates). refreshConfirmedNonce only raises the floor — it never
            // evicts pending txs or the queue, so SEC-401 cleanup is not triggered.
            //
            // the validator returned EVERY signer's confirmed
            // next-expected nonce, every debited owner's confirmed balance, and the
            // per-tx net-debits from the SAME locked frontier snapshot — thread
            // them straight into addTransaction (single view across the cumulative
            // per-signer check and the insert; no second await re-reads balance).
            var seenSigners = Set<String>()
            let uniqueSigners = body.signers.filter { seenSigners.insert($0).inserted }
            let debits = validator.netDebits(body)
            var confirmedBalances = balanceByOwner ?? [:]
            var freshNonceBySigner: [String: UInt64] = [:]
            for signer in uniqueSigners {
                var freshNonce = confirmedNonceBySigner?[signer]
                if freshNonce == nil { freshNonce = try? await getNonce(address: signer, chainPath: chainPath) }
                if let n = freshNonce {
                    freshNonceBySigner[signer] = n
                    await network.nodeMempool.refreshConfirmedNonce(sender: signer, nonce: n)
                }
            }
            // M9: on the tolerated withdrawal-without-deposit path the validator
            // short-circuited before resolving balances (balanceByOwner == nil).
            // Resolve them here so the cumulative per-signer bound still runs for
            // the re-admit instead of going inert.
            if balanceByOwner == nil {
                var ownersToResolve = Set(debits.keys)
                if let sender = body.signers.first { ownersToResolve.insert(sender) }
                for owner in ownersToResolve {
                    if let balance = try? await getBalance(address: owner, chainPath: chainPath) {
                        confirmedBalances[owner] = balance
                    }
                }
            }
            // P-902: also seed confirmedNonce AFTER addTransaction so the SEC-401
            // defer doesn't evict a newly-created queue before it can be populated.
            // Reuses the freshNonce values resolved above — same snapshot, no
            // second getNonce round-trip per signer.
            let addResult = await network.nodeMempool.addTransaction(transaction, confirmedBalances: confirmedBalances, debits: debits)
            switch addResult {
            case .added, .replacedExisting:
                let updates = uniqueSigners.compactMap { signer in
                    freshNonceBySigner[signer].map { (sender: signer, nonce: $0) }
                }
                if !updates.isEmpty {
                    await network.nodeMempool.batchUpdateConfirmedNonces(updates: updates)
                }
            case .rejected:
                break
            }
            return classifyMempoolAddResult(addResult)
        }

        // fail closed when chain state is unavailable (mirrors the
        // directory: overload). No validated balance view => no cumulative
        // double-spend check => reject rather than admit an unbankable backlog.
        return MempoolAdmission(result: .rejected(.stateUnavailable, "Chain state not available"), consensusClass: .transient)
    }

    private func classifyMempoolAddResult(_ result: AddResult) -> MempoolAdmission {
        switch result {
        case .added, .replacedExisting:
            return MempoolAdmission(result: result, consensusClass: nil)
        case .rejected(let reason):
            return MempoolAdmission(
                result: result,
                consensusClass: reason.kind.mempoolAddConsensusClass
            )
        }
    }

    private func classifyMempoolPolicyError(_ reason: String) -> ConsensusClass {
        reason == "Unable to resolve chain spec" ? .transient : .policy
    }

    func refreshMempoolNonceFloorsFromTip(directory: String, chainPath: [String]? = nil) async {
        let key: String
        let chainState: ChainState?
        let targetNetwork: ChainNetwork?
        if let chainPath {
            key = chainKey(forPath: chainPath)
            chainState = await chain(forPath: chainPath)
            targetNetwork = network(forPath: chainPath)
        } else {
            key = chainKey(forDirectory: directory)
            chainState = await chain(for: directory)
            targetNetwork = network(for: directory)
        }
        guard let targetNetwork, let chainState else { return }
        let tipCID = await chainState.getMainChainTip()
        guard !tipCID.isEmpty else { return }
        let mempoolGeneration = await targetNetwork.nodeMempool.currentGeneration
        if let previous = mempoolNonceFloorRefreshKeys[key],
           previous.tipCID == tipCID,
           previous.mempoolGeneration == mempoolGeneration {
            return
        }
        mempoolNonceFloorRefreshKeys[key] = (tipCID: tipCID, mempoolGeneration: mempoolGeneration)

        let senders = await targetNetwork.nodeMempool.allSenders()
        guard !senders.isEmpty else { return }
        var updates: [(sender: String, nonce: UInt64)] = []
        updates.reserveCapacity(senders.count)
        // M11: also gather fresh confirmed balances so residents that became
        // unaffordable since admission (their backing balance was spent in a
        // later block) are dropped instead of churning the trial-build path
        // every template build.
        var balanceUpdates: [(sender: String, confirmedBalance: UInt64)] = []
        balanceUpdates.reserveCapacity(senders.count)
        for sender in senders {
            let nonce: UInt64?
            let balance: UInt64?
            if let chainPath {
                nonce = try? await getNonce(address: sender, chainPath: chainPath)
                balance = try? await getBalance(address: sender, chainPath: chainPath)
            } else {
                nonce = try? await getNonce(address: sender, directory: directory)
                balance = try? await getBalance(address: sender, directory: directory)
            }
            if let nonce {
                updates.append((sender: sender, nonce: nonce))
            }
            if let balance {
                balanceUpdates.append((sender: sender, confirmedBalance: balance))
            }
        }
        await targetNetwork.nodeMempool.resetConfirmedNoncesAfterReorg(updates: updates)
        await targetNetwork.nodeMempool.dropUnaffordable(updates: balanceUpdates)
    }

    private func validateWasmPoliciesForMempool(
        body: TransactionBody,
        chain: ChainState,
        network: ChainNetwork,
        chainPath: [String]
    ) async -> String? {
        let tipHash = await chain.getMainChainTip()
        let tipHeader = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await tipHeader.resolve(fetcher: network.ivyFetcher).node,
              let spec = try? await tipBlock.spec.resolve(fetcher: network.ivyFetcher).node else {
            return "Unable to resolve chain spec"
        }
        guard !spec.wasmPolicies.isEmpty else { return nil }
        // Mirror block-time validation: validateNexus/validateChildBlock call
        // batchVerifyPolicies with the candidate chain's spec, the full chain path,
        // and the default scope set. Admission fails closed if the current spec
        // cannot be resolved; accepting through a transient miss would let a tx
        // enter mempool before the same policy inputs are available to block validation.
        let acceptedByPolicy = await TransactionBody.batchVerifyPolicies(
            bodies: [body],
            spec: spec,
            chainPath: chainPath,
            fetcher: network.ivyFetcher
        )
        return acceptedByPolicy ? nil : "Rejected by WASM policy"
    }

    func describeValidationError(_ error: TransactionValidationError) -> String {
        switch error {
        case .missingBody:
            return "Transaction body not resolved"
        case .invalidSignatures:
            return "Invalid signature(s)"
        case .signerMismatch:
            return "Signers do not match signatures"
        case .duplicateAccountOwner:
            return "Duplicate account action for owner"
        case .insufficientBalance:
            // Intentionally omits owner address and exact balance — callers
            // could binary-search any address's balance using the error string.
            return "Insufficient balance"
        case .noStateAvailable:
            return "Chain state not available"
        case .depositActionInvalid:
            return "Deposit action invalid (zero amount or demander not in signers)"
        case .receiptActionInvalid:
            return "Receipt action invalid (zero amount or withdrawer not in signers)"
        case .withdrawalActionInvalid:
            return "Withdrawal action invalid (zero amount or withdrawer not in signers)"
        case .withdrawalWithoutDeposit:
            return "Withdrawal rejected: no corresponding deposit found in current state"
        case .stateResolutionFailed:
            return "Failed to resolve chain state"
        case .feeTooLow(let actual, let minimum):
            return "Fee too low: \(actual) < minimum \(minimum)"
        case .nonceAlreadyUsed:
            return "Nonce already used or expired"
        case .nonceFromFuture:
            return "Nonce too far in the future"
        case .balanceNotConserved:
            return "Balance not conserved"
        case .transactionTooLarge(let size, let max):
            return "Transaction too large: \(size) bytes (max \(max))"
        case .feeTooHigh(let actual, let maximum):
            return "Fee too high: \(actual) > maximum \(maximum)"
        case .chainPathMismatch:
            return "Transaction chainPath does not match this chain"
        case .depositOrWithdrawalOnNexus:
            return "Deposit and withdrawal actions are not allowed on the nexus chain"
        case .receiptOnChildChain:
            return "Receipt actions are not allowed on child chains"
        case .invalidAccountAction:
            return "Account action invalid (zero delta)"
        case .reservedAccountOwner:
            return "Account action targets a reserved (_nonce_) owner key"
        }
    }

    // MARK: - Gossip Admission

    /// Gossip-path admission. Funnels a peer-broadcast transaction through
    /// the same `admitToMempool` classifier as direct submits.
    /// Returns true on any acceptance (added or replaced) so the caller
    /// can rebroadcast.
    nonisolated public func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> GossipAdmission {
        let admission = await admitToMempoolAdmission(transaction: transaction, chainPath: network.chainPath)
        switch admission.result {
        case .added, .replacedExisting: return .accepted
        case .rejected(let reason):
            // R5: typed — a capacity rejection penalizes the flooding source.
            // (`.full` is the only kind whose consensus class is nil.)
            if reason.kind == .full {
                return .rejectedMempoolFull
            }
            return .rejected(consensusInvalid: admission.consensusClass == .consensusInvalid)
        }
    }

}
