import Lattice
import Foundation
import cashew
import UInt256

public let MINIMUM_TRANSACTION_FEE: UInt64 = 1
public let MAX_TRANSACTION_FEE: UInt64 = 1_000_000_000_000
public let MAX_NONCE_DRIFT: UInt64 = 64
public let MAX_TRANSACTION_SIZE: Int = 102_400
/// Maximum number of signatures accepted on a single transaction.
/// A TaskGroup spawns one concurrent verification task per signature;
/// without this cap an attacker submits thousands of signatures in one
/// request to exhaust the cooperative thread pool.
public let MAX_SIGNATURES_PER_TRANSACTION: Int = 16

public enum TransactionValidationError: Error, Sendable {
    case missingBody
    case invalidSignatures
    case signerMismatch
    case duplicateAccountOwner(String)
    case insufficientBalance(owner: String, balance: UInt64, required: UInt64)
    case noStateAvailable
    case depositActionInvalid
    case receiptActionInvalid
    case withdrawalActionInvalid
    case stateResolutionFailed
    case feeTooLow(actual: UInt64, minimum: UInt64)
    case feeTooHigh(actual: UInt64, maximum: UInt64)
    case nonceAlreadyUsed(nonce: UInt64)
    case nonceFromFuture(nonce: UInt64)
    case balanceNotConserved(totalDebits: UInt64, totalCredits: UInt64, fee: UInt64)
    case transactionTooLarge(size: Int, max: Int)
    case chainPathMismatch
    case depositOrWithdrawalOnNexus
    case receiptOnChildChain
    case withdrawalWithoutDeposit
    case invalidAccountAction(String)
    case reservedAccountOwner(String)
}

public enum ConsensusClass: Sendable {
    case consensusInvalid
    case policy
    case transient
    case missingInput
}

public extension TransactionValidationError {
    var consensusClass: ConsensusClass {
        switch self {
        case .invalidSignatures,
             .signerMismatch,
             .duplicateAccountOwner,
             .invalidAccountAction,
             .reservedAccountOwner,
             .balanceNotConserved,
             .depositActionInvalid,
             .receiptActionInvalid,
             .withdrawalActionInvalid,
             .chainPathMismatch,
             .depositOrWithdrawalOnNexus,
             .receiptOnChildChain,
             .transactionTooLarge,
             .nonceAlreadyUsed,
             .missingBody:
            return .consensusInvalid
        case .feeTooLow,
             .feeTooHigh:
            return .policy
        case .noStateAvailable,
             .stateResolutionFailed:
            return .transient
        case .insufficientBalance,
             .nonceFromFuture,
             .withdrawalWithoutDeposit:
            return .missingInput
        }
    }
}

public struct TransactionValidator: Sendable {
    private let fetcher: Fetcher
    private let chainState: ChainState
    private let isCoinbase: Bool
    private let frontierCache: PostStateCache?
    private let chainDirectory: String?
    private let expectedChainPath: [String]?
    private let isNexus: Bool
    /// Legacy directory/depth fallback for direct validator construction. Production
    /// admission passes `expectedChainPath` and requires exact path equality.
    private let chainPathDepth: Int?

    public init(
        fetcher: Fetcher,
        chainState: ChainState,
        isCoinbase: Bool = false,
        frontierCache: PostStateCache? = nil,
        chainDirectory: String? = nil,
        expectedChainPath: [String]? = nil,
        isNexus: Bool = false,
        chainPathDepth: Int? = nil
    ) {
        self.fetcher = fetcher
        self.chainState = chainState
        self.isCoinbase = isCoinbase
        self.frontierCache = frontierCache
        self.chainDirectory = chainDirectory
        self.expectedChainPath = expectedChainPath
        self.isNexus = isNexus
        self.chainPathDepth = chainPathDepth
    }

    /// Validate `transaction` and return the result plus the on-chain confirmed nonce
    /// for the sender (resolved during nonce validation) and the sender's confirmed
    /// on-chain balance (resolved from the SAME tip snapshot the balance check uses).
    /// Callers can use the nonce to seed mempool tracking without a second account-trie
    /// traversal (P-902), and the balance to enforce the cumulative per-sender debit
    /// bound with NO second await re-reading balance after validate — closing
    /// the validate->insert TOCTOU for distinct nonces.
    ///
    /// consensus enforces EVERY signer's nonce sequence and every
    /// net-negative owner's balance, so the per-signer maps
    /// (`confirmedNonceBySigner` / `balanceByOwner`, both from the same locked
    /// snapshot) are returned alongside the primary-signer scalars to let the
    /// mempool track admission state per signer, not just `signers.first`.
    public func validate(_ transaction: Transaction) async -> (
        result: Result<Void, TransactionValidationError>,
        onChainNonce: UInt64?,
        senderBalance: UInt64?,
        confirmedNonceBySigner: [String: UInt64]?,
        balanceByOwner: [String: UInt64]?
    ) {
        guard let body = transaction.body.node else {
            return (.failure(.missingBody), nil, nil, nil, nil)
        }

        // run ALL pure in-memory gates BEFORE the expensive
        // signature verification (up to 16 Ed25519 verifies) and before any
        // state/trie I/O. An attacker flooding well-formed-but-cheap-rejectable
        // txs (bad chainPath, too-low fee, malformed deposit/receipt/withdrawal
        // shapes, duplicate owners) is now rejected without paying signature CPU
        // or a single trie hop. Observable: a tx that fails a cheap gate AND has
        // invalid signatures returns the cheap error, not `.invalidSignatures`.
        if let err = validateSize(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateFees(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateChainPath(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateDeposits(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateReceipts(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateWithdrawals(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateUniqueOwners(body) { return (.failure(err), nil, nil, nil, nil) }
        if let err = validateConservation(body) { return (.failure(err), nil, nil, nil, nil) }

        // Signature verification runs only after every cheap gate passes.
        if let err = await validateSignatures(transaction, body: body) { return (.failure(err), nil, nil, nil, nil) }

        // P-704: fetch tipSnapshot once — validateNonce and validateBalances both need it,
        // avoiding two sequential actor hops to ChainState per validation call.
        let snapshot = isCoinbase ? nil : await chainState.tipSnapshot
        let (nonceErr, confirmedNonceBySigner) = await validateNonceReturningConfirmed(body, snapshot: snapshot)
        let onChainNonce = body.signers.first.flatMap { confirmedNonceBySigner?[$0] }
        if let err = nonceErr { return (.failure(err), onChainNonce, nil, confirmedNonceBySigner, nil) }
        if let err = await validateWithdrawalDeposits(body, snapshot: snapshot) { return (.failure(err), nil, nil, confirmedNonceBySigner, nil) }
        let (balanceErr, balanceByOwner) = await validateBalances(body, snapshot: snapshot)
        if let err = balanceErr { return (.failure(err), onChainNonce, nil, confirmedNonceBySigner, nil) }
        let senderBalance = body.signers.first.flatMap { balanceByOwner?[$0] }

        return (.success(()), onChainNonce, senderBalance, confirmedNonceBySigner, balanceByOwner)
    }

    // MARK: - Validation Phases

    private func validateSize(_ body: TransactionBody) -> TransactionValidationError? {
        if let bodyData = body.toData(), bodyData.count > MAX_TRANSACTION_SIZE {
            return .transactionTooLarge(size: bodyData.count, max: MAX_TRANSACTION_SIZE)
        }
        return nil
    }

    private func validateSignatures(_ transaction: Transaction, body: TransactionBody) async -> TransactionValidationError? {
        if transaction.signatures.isEmpty {
            return .invalidSignatures
        }
        let sigs = Array(transaction.signatures)
        if sigs.count > MAX_SIGNATURES_PER_TRANSACTION {
            return .invalidSignatures
        }
        if sigs.count == 1 {
            // THE consensus signature rule — the same predicate block
            // validation applies (`Transaction.signaturesAreValid`), so
            // admission and consensus can never drift.
            if !transaction.signaturesAreValid() {
                return .invalidSignatures
            }
        } else {
            // Node-only parallel-verification wrapper: same per-signature rule
            // the predicate applies (TransactionSigning.verify over the body
            // CID), parallelized across a TaskGroup so a 16-signature tx does
            // not serialize 16 Ed25519 verifies on one task.
            let allValid = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                for (publicKeyHex, signature) in sigs {
                    group.addTask {
                        TransactionSigning.verify(body: body, bodyCID: transaction.body.rawCID, signature: signature, publicKeyHex: publicKeyHex)
                    }
                }
                for await result in group {
                    if !result { group.cancelAll(); return false }
                }
                return true
            }
            if !allValid { return .invalidSignatures }
        }

        // THE consensus signer-coverage rule (signing keys == declared signers,
        // by derived address) — the Lattice predicate block validation applies.
        if !transaction.signaturesMatchSigners() {
            return .signerMismatch
        }

        // Debited owners must sign. This is the signer-coverage half of
        // Lattice's `accountActionsAreValid`; its other half, per-action
        // `verify()` (delta != 0 && delta != Int64.min), is enforced in
        // `validateUniqueOwners` (delta == 0 → .invalidAccountAction) and
        // `computeNetDebit` (Int64.min). Kept as a hand loop so the
        // signer-coverage failure stays `.signerMismatch`.
        let signerSet = Set(body.signers)
        for action in body.accountActions where action.isDebit {
            if !signerSet.contains(action.owner) {
                return .signerMismatch
            }
        }

        return nil
    }

    private func validateFees(_ body: TransactionBody) -> TransactionValidationError? {
        if !isCoinbase && body.fee < MINIMUM_TRANSACTION_FEE {
            return .feeTooLow(actual: body.fee, minimum: MINIMUM_TRANSACTION_FEE)
        }
        if !isCoinbase && body.fee > MAX_TRANSACTION_FEE {
            return .feeTooHigh(actual: body.fee, maximum: MAX_TRANSACTION_FEE)
        }
        return nil
    }

    /// P-902: returns both the validation error (if any) and the on-chain confirmed
    /// next-expected nonce for EVERY signer so callers can seed per-signer
    /// mempool nonce tracking without a second trie traversal.
    private func validateNonceReturningConfirmed(_ body: TransactionBody, snapshot: TipBlockSnapshot?) async -> (TransactionValidationError?, [String: UInt64]?) {
        guard !isCoinbase else { return (nil, nil) }
        guard let snapshot else { return (.stateResolutionFailed, nil) }
        let state: LatticeState
        if let cached = frontierCache?.get(frontierCID: snapshot.postStateCID) {
            state = cached
        } else {
            let frontierHeader = LatticeStateHeader(rawCID: snapshot.postStateCID)
            guard let resolved = try? await frontierHeader.resolve(fetcher: fetcher).node else {
                return (.stateResolutionFailed, nil)
            }
            state = resolved
            frontierCache?.set(frontierCID: snapshot.postStateCID, state: state)
        }
        let signers = Set(body.signers).sorted()
        var nextExpectedBySigner: [String: UInt64] = [:]
        for signer in signers {
            // THE consensus nonce floor (stored nonce + 1; a never-transacted
            // account floors at 0) — read via the Lattice predicate
            // `AccountStateHeader.nextExpectedNonce(for:fetcher:)`, the same
            // rule `proveAndUpdateState`'s contiguity check applies, so
            // admission can never drift from the state transition.
            guard let nextExpected = try? await state.accountState.nextExpectedNonce(for: signer, fetcher: fetcher) else {
                return (.stateResolutionFailed, nil)
            }
            nextExpectedBySigner[signer] = nextExpected
        }
        for signer in signers {
            let nextExpected = nextExpectedBySigner[signer] ?? 0
            if body.nonce < nextExpected {
                return (.nonceAlreadyUsed(nonce: body.nonce), nextExpectedBySigner)
            }
            let (driftLimit, driftOverflow) = nextExpected.addingReportingOverflow(MAX_NONCE_DRIFT)
            if !driftOverflow, body.nonce > driftLimit {
                return (.nonceFromFuture(nonce: body.nonce), nextExpectedBySigner)
            }
        }
        return (nil, nextExpectedBySigner)
    }

    private func validateChainPath(_ body: TransactionBody) -> TransactionValidationError? {
        if let expectedChainPath {
            return body.chainPath == expectedChainPath ? nil : .chainPathMismatch
        }
        guard let dir = chainDirectory else { return nil }
        if let depth = chainPathDepth, body.chainPath.count != depth { return .chainPathMismatch }
        if body.chainPath.last != dir { return .chainPathMismatch }
        return nil
    }

    private func validateDeposits(_ body: TransactionBody) -> TransactionValidationError? {
        // Node-only policy layered on top of the consensus shape rule: the
        // nexus has no parent chain to lock funds against, so deposits are
        // rejected there outright.
        if isNexus, !body.depositActions.isEmpty { return .depositOrWithdrawalOnNexus }
        // THE consensus shape rule (non-zero amounts, demander signs) — the
        // Lattice predicate block validation applies.
        if !body.depositActionsAreValid() { return .depositActionInvalid }
        return nil
    }

    // Receipts are valid on any non-leaf chain: a grandchild's withdrawal
    // resolves `parentState.receiptState` on its DIRECT parent (which may
    // itself be a non-nexus chain like Mid in a 3-level hierarchy). The
    // validator can't cheaply tell whether the current chain has children,
    // and correctness is enforced at block-application time via
    // `TransactionBody.withdrawalsAreValid`, which checks the parent-chain
    // receipt state. Allowing receipts on any chain makes 2+ level deep
    // cross-chain swaps work.
    private func validateReceipts(_ body: TransactionBody) -> TransactionValidationError? {
        // THE consensus shape rule (non-zero amount, withdrawer signs) — the
        // Lattice predicate block validation applies.
        if !body.receiptActionsAreValid() { return .receiptActionInvalid }
        // Node-stricter bound the Lattice shape predicate does not impose:
        // amountDemanded must fit in Int64. Consensus still rejects larger
        // amounts (TransactionBody.netAccountDeltas throws balanceOverflow in
        // the state transition), so this only fails the tx earlier — at
        // admission, as a malformed receipt — never admits what consensus
        // would reject.
        for receipt in body.receiptActions {
            if receipt.amountDemanded > UInt64(Int64.max) { return .receiptActionInvalid }
        }
        return nil
    }

    private func validateWithdrawals(_ body: TransactionBody) -> TransactionValidationError? {
        // Node-only policy layered on top of the consensus shape rule: the
        // nexus has no parent chain to withdraw from.
        if isNexus, !body.withdrawalActions.isEmpty { return .depositOrWithdrawalOnNexus }
        // THE consensus shape rule (non-zero amounts, withdrawer signs) — the
        // Lattice predicate block validation applies.
        if !body.withdrawalActionsAreValid() { return .withdrawalActionInvalid }
        return nil
    }

    // Pre-filter: reject withdrawals whose deposit doesn't exist in the current tip state.
    // Only checks deposits (not receipts) — the receipt check requires the parent chain's
    // current state, which may be newer than what's embedded in the tip block's parentState.
    // The full deposit+receipt check happens at block validation time via withdrawalsAreValid.
    private func validateWithdrawalDeposits(_ body: TransactionBody, snapshot: TipBlockSnapshot?) async -> TransactionValidationError? {
        guard !body.withdrawalActions.isEmpty else { return nil }
        guard let snapshot else { return .stateResolutionFailed }
        let prevState: LatticeState
        if let cached = frontierCache?.get(frontierCID: snapshot.postStateCID) {
            prevState = cached
        } else {
            let header = LatticeStateHeader(rawCID: snapshot.postStateCID)
            guard let resolved = try? await header.resolve(fetcher: fetcher).node else { return .stateResolutionFailed }
            prevState = resolved
            frontierCache?.set(frontierCID: snapshot.postStateCID, state: prevState)
        }
        var depositPaths = [[String]: ResolutionStrategy]()
        var depositKeys: [(key: String, amountWithdrawn: UInt64)] = []
        for withdrawal in body.withdrawalActions {
            let key = DepositKey(withdrawalAction: withdrawal).description
            depositPaths[[key]] = .targeted
            depositKeys.append((key: key, amountWithdrawn: withdrawal.amountWithdrawn))
        }
        let resolvedDeposits: DepositStateHeader
        do {
            resolvedDeposits = try await prevState.depositState.resolve(paths: depositPaths, fetcher: fetcher)
        } catch {
            return .stateResolutionFailed
        }
        guard let depositState = resolvedDeposits.node else {
            return .stateResolutionFailed
        }
        for deposit in depositKeys {
            guard let storedAmount: UInt64 = try? depositState.get(key: deposit.key),
                  storedAmount == deposit.amountWithdrawn else {
                return .withdrawalWithoutDeposit
            }
        }
        do {
            _ = try await resolvedDeposits.proveExistenceOfCorrespondingDeposit(
                withdrawalActions: body.withdrawalActions, fetcher: fetcher
            )
        } catch {
            return .stateResolutionFailed
        }
        return nil
    }

    /// Reject account actions that block validation would reject deterministically,
    /// so the mempool never holds an admit-but-unbuildable tx (M11 churn):
    ///   • duplicate owner within one tx;
    ///   • zero-delta action — consensus `AccountAction.verify()` requires
    ///     `delta != 0` (the Int64.min case is rejected by `validateConservation`,
    ///     which runs next, before signatures/balances);
    ///   • a reserved `_nonce_`-prefixed owner — `proveAndUpdateState` throws
    ///     `conflictingActions` for it. The reserved prefix is read from the
    ///     consensus primitive (`nonceTrackingKey("")`), never duplicated here.
    private func validateUniqueOwners(_ body: TransactionBody) -> TransactionValidationError? {
        let reservedPrefix = AccountStateHeader.nonceTrackingKey("")
        var seenOwners = Set<String>()
        for action in body.accountActions {
            if !seenOwners.insert(action.owner).inserted {
                return .duplicateAccountOwner(action.owner)
            }
            if action.owner.hasPrefix(reservedPrefix) {
                return .reservedAccountOwner(action.owner)
            }
            if action.delta == 0 {
                return .invalidAccountAction(action.owner)
            }
        }
        return nil
    }

    /// Net debit per owner for `body`: explicit account-action deltas plus the
    /// implicit receipt transfer (debit withdrawer / credit demander by
    /// `amountDemanded`). A negative value is funds the owner must afford. Returns
    /// `.balanceNotConserved` only on the arithmetic-overflow / Int64.min cases the
    /// caller must reject. This is the SINGLE source of net-debit semantics — both
    /// the per-tx balance check (`validateBalances`) and the mempool's cumulative
    /// per-sender bound (via `senderNetDebit`) read it, so the two never drift.
    ///
    /// R6 (closed): the per-action delta derivation — receipt transfers
    /// included, UNCONDITIONALLY on every chain — comes from the consensus
    /// predicate `TransactionBody.netAccountDeltas`, the exact rule
    /// `LatticeState.proveAndUpdateState` applies, so admission and block
    /// validation share one definition. The node layers only per-owner
    /// aggregation (with overflow / Int64.min rejection) on top.
    func computeNetDebit(_ body: TransactionBody) -> Result<[String: Int64], TransactionValidationError> {
        do {
            // Net-debit arithmetic is owned by `TransactionBody.netBalanceDeltas`
            // (the single source consensus block validation also uses); the node
            // only adapts its overflow throw into the mempool's reject reason.
            return .success(try body.netBalanceDeltas())
        } catch {
            // StateErrors.balanceOverflow: a receipt amount of 0/>Int64.max, or a
            // per-owner aggregation overflow / Int64.min — all unaffordable.
            return .failure(.balanceNotConserved(totalDebits: 0, totalCredits: 0, fee: body.fee))
        }
    }

    /// per-owner net outflow for `body`, as non-negative amounts —
    /// `computeNetDebit` restricted to net-negative owners. For a tx that passed
    /// `validateSignatures`/`validateReceipts`, every net-negative owner is a
    /// signer, so this is exactly the per-SIGNER debit set the mempool's
    /// cumulative bound must track. Empty on the overflow cases
    /// `computeNetDebit` rejects (those txs never get admitted).
    func netDebits(_ body: TransactionBody) -> [String: UInt64] {
        body.netOutflows()
    }

    /// Funds `sender` must afford for `body` alone, as a non-negative outflow.
    /// Reuses `computeNetDebit` (via `netDebits`) so the mempool's cumulative
    /// bound matches the per-tx consensus balance check exactly. Returns 0 when
    /// the sender's net position is non-negative (a net credit/zero is no
    /// outflow) or on the overflow cases `computeNetDebit` rejects.
    func senderNetDebit(_ body: TransactionBody, sender: String) -> UInt64 {
        body.netOutflow(of: sender)
    }

    /// Returns the per-tx balance-validation error (if any) AND the confirmed
    /// on-chain balances of the sender plus every net-negative owner, resolved
    /// from the SAME `snapshot`. The balances let the admission
    /// seam enforce the cumulative per-signer bound without a second await
    /// re-reading balance after validate.
    private func validateBalances(_ body: TransactionBody, snapshot: TipBlockSnapshot?) async -> (TransactionValidationError?, [String: UInt64]?) {
        guard !isCoinbase else { return (nil, nil) }
        // Net debit per owner from explicit actions + implicit receipt transfers.
        // Receipts generate implicit debit(withdrawer, amountDemanded) and
        // credit(demander, amountDemanded) during block state computation on
        // EVERY chain (Lattice proveAndUpdateState). We must verify the
        // withdrawer can afford this before accepting into the mempool.
        let netDebit: [String: Int64]
        switch computeNetDebit(body) {
        case .failure(let err): return (err, nil)
        case .success(let nd): netDebit = nd
        }

        // Only owners with a net negative position need a balance check
        let ownersToCheck = netDebit.filter { $0.value < 0 }
        let sender = body.signers.first
        // The sender's confirmed balance is needed by the cumulative bound even
        // when THIS tx is net-positive for the sender, so resolve it whenever a
        // sender exists — not only when it is in ownersToCheck.
        var ownersToResolve = Set(ownersToCheck.keys)
        if let sender { ownersToResolve.insert(sender) }
        guard !ownersToResolve.isEmpty else { return (nil, [:]) }

        // snapshot was fetched once at validate() entry (P-704) — use it directly
        guard let snapshot else {
            return (ownersToCheck.isEmpty ? nil : .noStateAvailable, nil)
        }

        let state: LatticeState
        if let cached = frontierCache?.get(frontierCID: snapshot.postStateCID) {
            state = cached
        } else {
            let frontierHeader = LatticeStateHeader(rawCID: snapshot.postStateCID)
            guard let resolved = try? await frontierHeader.resolve(fetcher: fetcher).node else {
                return (.stateResolutionFailed, nil)
            }
            state = resolved
            frontierCache?.set(frontierCID: snapshot.postStateCID, state: state)
        }

        var accountPaths = [[String]: ResolutionStrategy]()
        for owner in ownersToResolve { accountPaths[[owner]] = .targeted }
        guard let accountDict = try? await state.accountState.resolve(paths: accountPaths, fetcher: fetcher).node else {
            return (.stateResolutionFailed, nil)
        }

        var balanceByOwner: [String: UInt64] = [:]
        for owner in ownersToResolve {
            balanceByOwner[owner] = (try? accountDict.get(key: owner)) ?? 0
        }

        for (owner, delta) in ownersToCheck {
            // Int64.min cannot reach here: accountActions skips it explicitly, and
            // the receipt loop now guards against wSum == Int64.min above. The
            // assertion is defensive; remove if it ever fires in a legitimate path.
            assert(delta > Int64.min, "delta == Int64.min would trap in UInt64(-delta)")
            let required = UInt64(-delta)
            let actualBalance: UInt64 = (try? accountDict.get(key: owner)) ?? 0
            if actualBalance < required {
                return (.insufficientBalance(
                    owner: owner,
                    balance: actualBalance,
                    required: required
                ), nil)
            }
        }

        return (nil, balanceByOwner)
    }

    private func validateConservation(_ body: TransactionBody) -> TransactionValidationError? {
        guard !isCoinbase else { return nil }

        if body.fee > 0 && body.accountActions.isEmpty {
            return .balanceNotConserved(totalDebits: 0, totalCredits: 0, fee: body.fee)
        }

        guard !body.accountActions.isEmpty else { return nil }

        let conservation = body.valueConservation()
        if conservation.overflow || !conservation.conserved {
            return .balanceNotConserved(
                totalDebits: conservation.totalDebits,
                totalCredits: conservation.totalCredits,
                fee: body.fee
            )
        }
        return nil
    }
}
