import ArgumentParser
import Foundation
import Lattice
import cashew
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrate an atomic cross-chain swap.
///
/// The swap is a 3-step protocol between a seller (Alice, on the child chain) and a
/// buyer (Bob, on the parent chain):
///
///   1. Seller: `ln swap sell` — lock child-coin escrow + print swap-ID for the buyer
///   2. Buyer:  `ln swap buy`  — pay seller on parent, wait, claim escrow on child
///   3. Either: `ln swap status` — inspect current progress of a live swap
///
/// The swap-ID is a colon-separated string: `directory:nonce:sellerAddr:amountDemanded:amountDeposited`
/// printed by `sell` and consumed by `buy`/`status`.

struct SwapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swap",
        abstract: "Orchestrate an atomic cross-chain swap (sell / buy / status)",
        subcommands: [
            SwapSellCommand.self,
            SwapBuyCommand.self,
            SwapStatusCommand.self,
        ]
    )
}

// MARK: - swap sell

struct SwapSellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sell",
        abstract: "Lock child-coin in escrow (step 1 of a swap). Prints the swap-ID for the buyer."
    )

    @Option(help: "Child-chain node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to signer (seller) key JSON file")
    var key: String

    @Option(help: "Amount of child-coin to lock in escrow (you will give this to the buyer)")
    var deposit: UInt64

    @Option(help: "Amount of parent-coin you demand in exchange")
    var demand: UInt64

    @Option(help: "Chain path on the child node (default: auto-detected)")
    var chainPath: String?

    func run() async throws {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let publicKey = keyJSON["publicKey"] as? String,
              let privateKey = keyJSON["privateKey"] as? String else {
            printError("Invalid key file"); throw ExitCode.failure
        }
        let seller = CryptoUtils.createAddress(from: publicKey)

        // Detect chain path from node if not provided
        let resolvedChainPath: String
        if let cp = chainPath {
            resolvedChainPath = cp
        } else {
            let info = try await fetchJSON("\(rpc)/api/chain/info")
            let chains = info["chains"] as? [[String: Any]] ?? []
            guard let first = chains.first,
                  let cp = (first["chainPath"] as? [String])?.joined(separator: "/") else {
                printError("Cannot detect chain path; use --chain-path"); throw ExitCode.failure
            }
            resolvedChainPath = cp
        }
        let path = resolvedChainPath.split(separator: "/").map(String.init)
        let directory = path.last ?? resolvedChainPath

        // Swap nonce: 64 bits of randomness. Although the field is UInt128, the
        // DAG-CBOR serialization caps integer values at UInt64.max (cashew throws
        // integerOverflow above it), so a full 128-bit nonce makes the deposit body
        // unserializable. 64 bits of entropy keeps the per-seller collision probability
        // negligible while staying within the serializable range.
        let nonce = UInt128(UInt64.random(in: 1...UInt64.max))

        // Deposits are rejected on the root chain (Nexus). Require a child chain.
        guard path.count > 1 else {
            printError("Deposits are not allowed on the root chain. Pass a child chain path (e.g. --chain-path Nexus/Payments).")
            throw ExitCode.failure
        }

        guard deposit > 0 else { printError("--deposit must be > 0"); throw ExitCode.failure }
        guard demand > 0  else { printError("--demand must be > 0");  throw ExitCode.failure }
        // Amounts are negated into Int64 deltas; guard against overflow and leave room for fee.
        guard deposit <= UInt64(Int64.max) - 10_000 else {
            printError("--deposit too large (would overflow Int64 delta)"); throw ExitCode.failure
        }
        guard demand <= UInt64(Int64.max) else {
            printError("--demand too large (exceeds Int64.max)"); throw ExitCode.failure
        }

        printHeader("Creating swap deposit")
        printKeyValue("Seller", seller)
        printKeyValue("Chain", resolvedChainPath)
        printKeyValue("Deposit (child coin)", String(deposit))
        printKeyValue("Demand (parent coin)", String(demand))
        printKeyValue("Nonce", nonce.description)

        // Read nonce + balance on the child chain
        var cpAllowed = CharacterSet.urlQueryAllowed; cpAllowed.remove(charactersIn: "&=+")
        let chainQuery = resolvedChainPath.addingPercentEncoding(withAllowedCharacters: cpAllowed) ?? resolvedChainPath
        guard let acctNonce = try await fetchJSON("\(rpc)/api/nonce/\(seller)?chainPath=\(chainQuery)")["nonce"] as? UInt64 else {
            printError("Cannot read nonce for \(seller) on '\(resolvedChainPath)'"); throw ExitCode.failure
        }
        guard let balance = try await fetchJSON("\(rpc)/api/balance/\(seller)?chainPath=\(chainQuery)")["balance"] as? UInt64 else {
            printError("Cannot read balance for \(seller)"); throw ExitCode.failure
        }

        // Build the deposit body (seller locks `deposit` coin, debits self)
        func buildBody(fee: UInt64) -> TransactionBody {
            let delta = Int64(0) - Int64(deposit) - Int64(fee)
            return TransactionBody(
                accountActions: [AccountAction(owner: seller, delta: delta)],
                actions: [],
                depositActions: [DepositAction(nonce: nonce, demander: seller, amountDemanded: demand, amountDeposited: deposit)],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [seller], fee: fee, nonce: acctNonce, chainPath: path
            )
        }
        let probeSize = UInt64(buildBody(fee: 1).toData()?.count ?? 512)
        let fee = probeSize + 16
        guard balance >= deposit + fee else {
            printError("Insufficient balance: have \(balance), need \(deposit + fee)"); throw ExitCode.failure
        }
        let body = buildBody(fee: fee)
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let sig = TransactionSigning.sign(body: body, bodyCID: bodyHeader.rawCID, privateKeyHex: privateKey) else {
            printError("Signing failed"); throw ExitCode.failure
        }
        guard let bodyData = body.toData() else { printError("Serialization failed"); throw ExitCode.failure }
        let txPayload: [String: Any] = [
            "signatures": [publicKey: sig],
            "bodyCID": bodyHeader.rawCID,
            "bodyData": bodyData.map { String(format: "%02x", $0) }.joined(),
            "chainPath": path,
        ]
        let txJSON = try JSONSerialization.data(withJSONObject: txPayload)
        let resp = try await postJSON("\(rpc)/api/transaction", body: txJSON)
        guard resp["accepted"] as? Bool == true else {
            printError("Deposit tx rejected: \(resp["error"] as? String ?? "unknown error")"); throw ExitCode.failure
        }
        let txCID = resp["txCID"] as? String ?? ""
        printSuccess("Deposit submitted: \(String(txCID.prefix(32)))…")
        printWarning("Locked funds have no expiry or refund path. The escrow can only be released by a valid buyer withdrawal. If no buyer completes the swap, run `ln swap status` to confirm funds are still locked.")

        let swapID = "\(directory):\(nonce):\(seller):\(demand):\(deposit)"
        print("")
        print("  Swap ID (give this to the buyer):")
        print("    \(swapID)")
        print("")
        print("  Buyer command:")
        print("    lattice-node swap buy \\")
        print("      --child-rpc \(rpc) \\")
        print("      --rpc <parent-rpc> \\")
        print("      --key <buyer-key.json> \\")
        print("      --swap-id \"\(swapID)\"")
    }
}

// MARK: - swap buy

struct SwapBuyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buy",
        abstract: "Pay the seller on the parent chain and claim the escrowed child-coin (steps 2 + 3 of a swap)."
    )

    @Option(help: "Child-chain node base URL (without /api suffix)")
    var childRpc: String

    @Option(help: "Parent-chain node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to signer (buyer) key JSON file")
    var key: String

    @Option(help: "Swap ID printed by `ln swap sell` (directory:nonce:seller:amountDemanded:amountDeposited)")
    var swapId: String

    @Option(help: "Seconds to wait for receipt to be mined (default 120)")
    var receiptTimeout: Int = 120

    @Option(help: "Seconds to wait for withdrawal to be mined (default 120)")
    var withdrawTimeout: Int = 120

    @Option(help: "Blocks to wait after confirming deposit/receipt before advancing each leg (default 1; 0 = zero-conf)")
    var minConfirmations: UInt = 1

    @Option(help: "Override the per-byte fee rate for the child-chain withdrawal tx. Default: auto — query the child node's fee policy. Must be >= the child's --min-fee-rate or the withdrawal would be rejected after the irreversible payment.")
    var withdrawalFeeRate: UInt64? = nil

    @Flag(help: "Skip the irreversible-payment confirmation prompt")
    var yes: Bool = false

    func run() async throws {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let publicKey = keyJSON["publicKey"] as? String,
              let privateKey = keyJSON["privateKey"] as? String else {
            printError("Invalid key file"); throw ExitCode.failure
        }
        let buyer = CryptoUtils.createAddress(from: publicKey)

        if let r = withdrawalFeeRate, r < 1 {
            printError("--withdrawal-fee-rate must be ≥ 1"); throw ExitCode.failure
        }

        let fields = swapId.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5,
              let nonce = UInt128(fields[1]),
              CryptoUtils.isValidAddress(fields[2]),
              let amountDemanded = UInt64(fields[3]),
              let amountDeposited = UInt64(fields[4]) else {
            printError("Invalid swap-id format. Expected: directory:nonce:seller:amountDemanded:amountDeposited")
            throw ExitCode.failure
        }
        // The swap nonce must be serializable: cashew's DAG-CBOR caps integers at
        // UInt64.max. `swap sell` only emits in-range nonces, but a hand-crafted
        // swap-id could carry a larger one — reject it up front rather than failing
        // later with an opaque serialization error in the deposit/receipt probe.
        guard nonce <= UInt128(UInt64.max) else {
            printError("Invalid swap-id: nonce exceeds UInt64.max and is not serializable")
            throw ExitCode.failure
        }
        let directory = fields[0]
        let seller    = fields[2]

        guard amountDeposited > 0 else {
            printError("Invalid swap-id: amountDeposited must be > 0"); throw ExitCode.failure
        }
        guard amountDemanded > 0 else {
            printError("Invalid swap-id: amountDemanded must be > 0"); throw ExitCode.failure
        }
        // Guard against Int64 overflow when negating and against fee addition overflow.
        // TransactionValidator rejects amountDemanded > Int64.max, so mirror that bound here.
        guard amountDeposited <= UInt64(Int64.max) else {
            printError("Invalid swap-id: amountDeposited exceeds Int64.max"); throw ExitCode.failure
        }
        guard amountDemanded <= UInt64(Int64.max) else {
            printError("Invalid swap-id: amountDemanded exceeds Int64.max (receipt would be rejected)"); throw ExitCode.failure
        }
        // The receipt tx debits buyer for both amountDemanded (implicit via netAccountDeltas)
        // and the fee (explicit AccountAction). Lattice aggregates per-owner Int64 deltas, so
        // the combined debit must also fit in Int64. Use a conservative fee bound (1024 bytes).
        let maxReceiptFee: UInt64 = 1_024
        let (grossDebit, grossOverflow) = amountDemanded.addingReportingOverflow(maxReceiptFee)
        guard !grossOverflow && grossDebit <= UInt64(Int64.max) else {
            printError("Invalid swap-id: amountDemanded + receipt fee would overflow Int64 account delta"); throw ExitCode.failure
        }

        // Detect child chain path from child node's chain/info
        let childInfo  = try await fetchJSON("\(childRpc)/api/chain/info")
        let childChains = childInfo["chains"] as? [[String: Any]] ?? []
        guard let childChain = childChains.first,
              let childPath = (childChain["chainPath"] as? [String]) else {
            printError("Cannot detect child chain path from \(childRpc)"); throw ExitCode.failure
        }
        // Detect parent chain path
        let parentInfo = try await fetchJSON("\(rpc)/api/chain/info")
        let parentChains = parentInfo["chains"] as? [[String: Any]] ?? []
        guard let parentChain = parentChains.first,
              let parentPath = (parentChain["chainPath"] as? [String]) else {
            printError("Cannot detect parent chain path from \(rpc)"); throw ExitCode.failure
        }

        // Verify topology: parent must be exactly the child's direct parent, and the
        // swap-ID directory must match the child's own chain name. Without this check a
        // wrong --rpc could accept the buyer's irreversible payment on an unrelated chain
        // that the child's parentState will never reference, making the withdrawal impossible.
        guard Array(childPath.dropLast()) == parentPath else {
            printError("Topology mismatch: child '\(childPath.joined(separator: "/"))' is not a direct child of parent '\(parentPath.joined(separator: "/"))'. Verify --child-rpc and --rpc point to the correct chains.")
            throw ExitCode.failure
        }
        guard childPath.last == directory else {
            printError("Swap-ID directory '\(directory)' does not match child chain '\(childPath.last ?? "?")'. Verify the swap-ID and --child-rpc refer to the same chain.")
            throw ExitCode.failure
        }

        // Contract 6 (fee-policy): the child admits a withdrawal only if its fee clears
        // `childMinFeeRate * bodyBytes`. The seller is auto-credited the instant the parent
        // receipt mines, with no refund — so an under-priced withdrawal that can never be
        // admitted means the buyer pays and gets nothing. Resolve the effective fee rate
        // BEFORE the irreversible payment, failing closed:
        //   - explicit override below the child's policy  → hard error
        //   - no override + child policy known             → use the child's policy
        //   - no override + child policy unknown           → hard error (can't size safely)
        //   - explicit override + child policy unknown     → warn, proceed on operator's word
        let childMinFeeRate = childChain["minFeeRate"] as? UInt64
        let effectiveFeeRate: UInt64
        if let override = withdrawalFeeRate {
            if let policy = childMinFeeRate {
                guard override >= policy else {
                    printError("--withdrawal-fee-rate \(override) is below the child node's fee policy (\(policy)/byte). The withdrawal would be rejected by admission AFTER you have already paid the seller. Re-run with --withdrawal-fee-rate >= \(policy).")
                    throw ExitCode.failure
                }
            } else {
                printWarning("Could not read the child node's fee policy; proceeding with the explicit --withdrawal-fee-rate \(override). Verify it is >= the child's --min-fee-rate or the withdrawal will be rejected after payment.")
            }
            effectiveFeeRate = override
        } else {
            guard let policy = childMinFeeRate else {
                printError("Could not determine the child node's fee-rate policy from \(childRpc)/api/chain/info. Re-run with an explicit --withdrawal-fee-rate (>= the child's --min-fee-rate) to acknowledge the fee you will pay.")
                throw ExitCode.failure
            }
            effectiveFeeRate = max(policy, 1)
        }

        printHeader("Executing swap buy")
        printKeyValue("Buyer",           buyer)
        printKeyValue("Seller",          seller)
        printKeyValue("Swap nonce",      nonce.description)
        printKeyValue("Pay (parent)",    "\(amountDemanded) on \(parentPath.joined(separator: "/"))")
        printKeyValue("Receive (child)", "\(amountDeposited) on \(childPath.joined(separator: "/"))")

        // ── Pre-check: verify escrow before committing funds ──────────────────
        // The parent-chain receipt is irreversible once mined (netAccountDeltas debits the
        // buyer immediately). Abort if the child escrow does not yet exist or the locked
        // amount does not match the swap-ID, so the buyer never pays for an empty promise.
        print("\n[1/5] Verifying child escrow before paying…")
        let escrowState = try await queryDepositState(rpc: childRpc, demander: seller, amount: amountDemanded, nonce: nonce, chainPath: childPath)
        guard escrowState["exists"] as? Bool == true else {
            printError("Child escrow not found — deposit may not be mined yet or swap-ID is wrong. Aborting to protect buyer funds.")
            throw ExitCode.failure
        }
        let confirmedDeposited = escrowState["amountDeposited"] as? UInt64 ?? 0
        guard confirmedDeposited == amountDeposited else {
            printError("Deposit amount mismatch: swap-ID says \(amountDeposited) but chain shows \(confirmedDeposited). Aborting.")
            throw ExitCode.failure
        }
        printSuccess("Escrow confirmed: \(confirmedDeposited) child-coin locked")

        // Reorg-safety gate: wait for minConfirmations more child blocks before paying,
        // then re-verify the deposit still exists at that height. Fails closed.
        if minConfirmations > 0 {
            print("[1/5] Waiting for \(minConfirmations) child confirmation(s) before paying…")
            let depositInfo = try await fetchJSON("\(childRpc)/api/chain/info")
            let depositHeight = ((depositInfo["chains"] as? [[String: Any]])?.first?["height"] as? UInt64) ?? 0
            let depositTarget = depositHeight + UInt64(minConfirmations)
            // Use receipt timeout as a floor; 1-hour Nexus block time means 300s is too short.
            let confirmationTimeout = max(receiptTimeout, Int(minConfirmations) * 3_600)
            let depositConfirmed = try await pollUntil(timeout: confirmationTimeout, interval: 10) {
                let info = try await fetchJSON("\(self.childRpc)/api/chain/info")
                let h = ((info["chains"] as? [[String: Any]])?.first?["height"] as? UInt64) ?? 0
                return h >= depositTarget
            }
            guard depositConfirmed else {
                printError("Timed out waiting for \(minConfirmations) child confirmation(s). Aborting to protect buyer funds.")
                throw ExitCode.failure
            }
            // Re-verify deposit still exists at the target height (catches reorgs).
            let recheck = try await queryDepositState(rpc: childRpc, demander: seller, amount: amountDemanded, nonce: nonce, chainPath: childPath)
            guard recheck["exists"] as? Bool == true else {
                printError("Deposit no longer exists after \(minConfirmations) confirmation(s) — likely reorged. Aborting.")
                throw ExitCode.failure
            }
            printSuccess("Deposit confirmed at child height ≥ \(depositTarget)")
        }

        // ── Pre-prompt: receipt idempotency check + real fee preflight ──────────
        // Compute the actual receipt fee (from a serialized probe body) before the
        // irreversible-payment prompt so the overflow guard uses the true fee, not a
        // conservative estimate. Move balance check to after prompt (it's a snapshot
        // that can go stale, and this keeps the ordering: preflight → confirm → pay).
        print("[2/5] Checking receipt state on parent…")
        let parentCPStr = parentPath.joined(separator: "/")
        var cpAllowed = CharacterSet.urlQueryAllowed; cpAllowed.remove(charactersIn: "&=+")
        let parentQuery = parentCPStr.addingPercentEncoding(withAllowedCharacters: cpAllowed) ?? parentCPStr

        let existingReceipt = try await queryReceiptState(rpc: rpc, demander: seller, amount: amountDemanded, nonce: nonce, destinationPath: childPath)
        let receiptAlreadyMined = existingReceipt["exists"] as? Bool == true

        var preflightNonce: UInt64 = 0
        var preflightFee: UInt64 = 0

        if receiptAlreadyMined {
            let storedWithdrawer = existingReceipt["withdrawer"] as? String ?? ""
            guard storedWithdrawer == buyer else {
                printError("Receipt already exists but withdrawer is '\(storedWithdrawer)', not you ('\(buyer)'). Another party already paid for this swap.")
                throw ExitCode.failure
            }
            printSuccess("Receipt already mined — resuming at withdrawal")
        } else {
            guard let pNonce = try await fetchJSON("\(rpc)/api/nonce/\(buyer)?chainPath=\(parentQuery)")["nonce"] as? UInt64 else {
                printError("Cannot read nonce for \(buyer) on parent chain"); throw ExitCode.failure
            }
            preflightNonce = pNonce
            func probeBody(fee: UInt64) -> TransactionBody {
                TransactionBody(
                    accountActions: [AccountAction(owner: buyer, delta: -Int64(fee))],
                    actions: [], depositActions: [], genesisActions: [],
                    receiptActions: [ReceiptAction(withdrawer: buyer, nonce: nonce, demander: seller, amountDemanded: amountDemanded, directory: directory)],
                    withdrawalActions: [],
                    signers: [buyer], fee: fee, nonce: pNonce, chainPath: parentPath
                )
            }
            let probeSize = UInt64(probeBody(fee: 1).toData()?.count ?? 512)
            preflightFee = probeSize + 16
            // Guard combined buyer debit (amountDemanded via netAccountDeltas + fee) fits Int64.
            let (grossDebit, grossOverflow) = amountDemanded.addingReportingOverflow(preflightFee)
            guard !grossOverflow && grossDebit <= UInt64(Int64.max) else {
                printError("amountDemanded + receipt fee (\(preflightFee)) would overflow Int64 account delta"); throw ExitCode.failure
            }
        }

        // Withdrawal preflight: verify the escrow amount exceeds the withdrawal fee before
        // the irreversible payment. The withdrawal account delta is (amountDeposited - withdrawFee);
        // a zero or negative delta is rejected by admission and cannot be recovered after the receipt.
        let withdrawProbeBody = TransactionBody(
            accountActions: [AccountAction(owner: buyer, delta: 0)],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: buyer, nonce: nonce, demander: seller, amountDemanded: amountDemanded, amountWithdrawn: amountDeposited)],
            signers: [buyer], fee: 1, nonce: 0, chainPath: childPath
        )
        let preflightBaseSize = UInt64(withdrawProbeBody.toData()?.count ?? 512) + 16
        let (preflightWithdrawFee, feeOverflow) = preflightBaseSize.multipliedReportingOverflow(by: effectiveFeeRate)
        guard !feeOverflow else {
            printError("Effective fee rate \(effectiveFeeRate) overflows the fee calculation"); throw ExitCode.failure
        }
        guard amountDeposited > preflightWithdrawFee else {
            printError("Escrow (\(amountDeposited) child-coin) must exceed the estimated withdrawal fee (\(preflightWithdrawFee)) at fee rate \(effectiveFeeRate). The net delta would be ≤ 0 and the withdrawal would be rejected by admission.")
            throw ExitCode.failure
        }

        // Confirmation gate: the receipt tx irreversibly debits the buyer on the parent.
        // There is no protocol-level refund if the child withdrawal subsequently fails.
        if !yes {
            printWarning("About to pay \(amountDemanded) parent-coin to seller '\(seller)'.")
            printWarning("This is IRREVERSIBLE. Your only recourse if the child withdrawal fails is to retry it manually.")
            print("Type YES to proceed: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces) == "YES" else {
                printError("Aborted."); throw ExitCode.failure
            }
        }

        // ── Step 2: submit receipt ─────────────────────────────────────────────
        // Contract 5: the receipt txCID is the thread that lets us resolve the EXACT
        // parent block the receipt mined in (via /api/receipt/{txCID}), which both the
        // confirmations gate and the child-visibility gate key off. Captured here on the
        // fresh-submit path; nil on resume (we then fall back to the parent tip height).
        var receiptTxCID: String? = nil
        if !receiptAlreadyMined {
            let parentNonce = preflightNonce
            let receiptFee  = preflightFee
            guard let parentBalance = try await fetchJSON("\(rpc)/api/balance/\(buyer)?chainPath=\(parentQuery)")["balance"] as? UInt64 else {
                printError("Cannot read balance for \(buyer) on parent chain"); throw ExitCode.failure
            }

            func buildReceiptBody(fee: UInt64) -> TransactionBody {
                // ReceiptAction.netAccountDeltas auto-debits buyer by amountDemanded and credits
                // seller. The fee is a separate conservation requirement: the miner collects it,
                // so the buyer must also explicitly debit themselves the fee amount.
                return TransactionBody(
                    accountActions: [AccountAction(owner: buyer, delta: -Int64(fee))],
                    actions: [], depositActions: [], genesisActions: [],
                    receiptActions: [ReceiptAction(withdrawer: buyer, nonce: nonce, demander: seller, amountDemanded: amountDemanded, directory: directory)],
                    withdrawalActions: [],
                    signers: [buyer], fee: fee, nonce: parentNonce, chainPath: parentPath
                )
            }
            guard parentBalance >= amountDemanded + receiptFee else {
                printError("Insufficient parent-chain balance: have \(parentBalance), need \(amountDemanded + receiptFee)")
                throw ExitCode.failure
            }
            let receiptBody = buildReceiptBody(fee: receiptFee)
            let receiptHeader = try HeaderImpl<TransactionBody>(node: receiptBody)
            guard let receiptSig = TransactionSigning.sign(body: receiptBody, bodyCID: receiptHeader.rawCID, privateKeyHex: privateKey) else {
                printError("Signing receipt failed"); throw ExitCode.failure
            }
            guard let receiptBodyData = receiptBody.toData() else { printError("Serialization failed"); throw ExitCode.failure }
            let receiptPayload: [String: Any] = [
                "signatures": [publicKey: receiptSig],
                "bodyCID": receiptHeader.rawCID,
                "bodyData": receiptBodyData.map { String(format: "%02x", $0) }.joined(),
                "chainPath": parentPath,
            ]
            let receiptJSON = try JSONSerialization.data(withJSONObject: receiptPayload)
            let receiptResp = try await postJSON("\(rpc)/api/transaction", body: receiptJSON)
            guard receiptResp["accepted"] as? Bool == true else {
                printError("Receipt tx rejected: \(receiptResp["error"] as? String ?? "unknown error")"); throw ExitCode.failure
            }
            receiptTxCID = receiptResp["txCID"] as? String
            if let txid = receiptTxCID, !txid.isEmpty { printKeyValue("Receipt txCID", txid) }
            printSuccess("Receipt submitted")
        }

        // ── Step 3: poll parent until receipt is mined ────────────────────────
        if !receiptAlreadyMined {
            print("[3/5] Waiting for receipt to be mined on parent…")
            let receiptMined = try await pollUntil(timeout: receiptTimeout, interval: 2) {
                let s = try await self.queryReceiptState(rpc: self.rpc, demander: seller, amount: amountDemanded, nonce: nonce, destinationPath: childPath)
                return s["exists"] as? Bool == true && s["withdrawer"] as? String == buyer
            }
            guard receiptMined else {
                printError("Timed out waiting for receipt to mine (waited \(receiptTimeout)s).")
                printWarning("The receipt tx was submitted and may still be pending. Do NOT rerun without first checking — a rerun while the receipt is unconfirmed can submit a second receipt and charge you again.")
                printWarning("Run `swap status --swap-id \"\(swapId)\"` to check current state. Once the receipt is mined, rerun to resume at withdrawal.")
                throw ExitCode.failure
            }
            printSuccess("Receipt confirmed on parent")
        }

        // Resolve the EXACT parent block height the receipt mined in. On the fresh path
        // we have the receipt txCID → /api/receipt/{txCID}.blockHeight. On resume we
        // don't (signatures aren't reproducible), so fall back to the current parent tip
        // height — a safe upper bound, since an existing receipt is at or below the tip.
        let childCPStr = childPath.joined(separator: "/")
        let childQuery = childCPStr.addingPercentEncoding(withAllowedCharacters: cpAllowed) ?? childCPStr
        var receiptBlockHeight: UInt64? = nil
        if let txid = receiptTxCID, !txid.isEmpty {
            let r = try await fetchJSON("\(rpc)/api/receipt/\(txid)?chainPath=\(parentQuery)")
            receiptBlockHeight = r["blockHeight"] as? UInt64
        }
        let effectiveReceiptHeight: UInt64
        if let h = receiptBlockHeight {
            effectiveReceiptHeight = h
        } else {
            let info = try await fetchJSON("\(rpc)/api/chain/info")
            let chs = info["chains"] as? [[String: Any]] ?? []
            guard let h = chs.first(where: { ($0["chainPath"] as? [String]) == parentPath })?["height"] as? UInt64 else {
                printError("Parent chain '\(parentCPStr)' not found in chain/info — cannot resolve receipt height. Aborting.")
                throw ExitCode.failure
            }
            effectiveReceiptHeight = h
        }

        // Reorg-safety gate: wait until the receipt is buried under minConfirmations parent
        // blocks (height >= receiptBlock + minConfirmations), then re-verify it still exists
        // and is ours. Fails closed.
        if minConfirmations > 0 {
            let receiptTarget = effectiveReceiptHeight + UInt64(minConfirmations)
            print("[3/5] Waiting for \(minConfirmations) parent confirmation(s) (height ≥ \(receiptTarget))…")
            let confirmationTimeout = max(receiptTimeout, Int(minConfirmations) * 3_600)
            let receiptConfirmed = try await pollUntil(timeout: confirmationTimeout, interval: 10) {
                let info = try await fetchJSON("\(self.rpc)/api/chain/info")
                let ch = info["chains"] as? [[String: Any]] ?? []
                let h = (ch.first(where: { ($0["chainPath"] as? [String]) == parentPath })?["height"] as? UInt64) ?? 0
                return h >= receiptTarget
            }
            guard receiptConfirmed else {
                printError("Timed out waiting for \(minConfirmations) parent confirmation(s). Aborting.")
                throw ExitCode.failure
            }
            let receiptRecheck = try await queryReceiptState(rpc: rpc, demander: seller, amount: amountDemanded, nonce: nonce, destinationPath: childPath)
            guard receiptRecheck["exists"] as? Bool == true, receiptRecheck["withdrawer"] as? String == buyer else {
                printError("Receipt no longer exists or belongs to a different withdrawer after \(minConfirmations) confirmation(s) — likely reorged or raced. Aborting.")
                throw ExitCode.failure
            }
            printSuccess("Receipt confirmed at parent height ≥ \(receiptTarget)")
        }

        // Child-visibility gate (Contract 2): the withdrawal validates against the child
        // block's `parentState`, which exposes parent post-state only up to the child
        // carrier's height minus one. A receipt in parent block R is therefore visible
        // once the child's visibleStateHeight >= R. Wait for that before submitting, or
        // the withdrawal is admitted-then-unbuildable.
        print("[3/5] Waiting for child to see parent receipt (visibleStateHeight ≥ \(effectiveReceiptHeight))…")
        let childSawReceipt = try await pollUntil(timeout: receiptTimeout, interval: 5) {
            let ph = try await self.fetchJSON("\(self.childRpc)/api/chain/parent-height?chainPath=\(childQuery)")
            // Prefer the explicit visibleStateHeight; fall back to parentHeight-1 for older nodes.
            if let vis = ph["visibleStateHeight"] as? UInt64 { return vis >= effectiveReceiptHeight }
            let carrier = ph["parentHeight"] as? UInt64 ?? 0
            return carrier > effectiveReceiptHeight
        }
        guard childSawReceipt else {
            printError("Timed out waiting for the child to see the parent receipt (needs visibleStateHeight ≥ \(effectiveReceiptHeight)). The receipt is mined; retry once the child's parent view catches up.")
            throw ExitCode.failure
        }

        // ── Step 4: submit withdrawal on child ────────────────────────────────
        print("[4/5] Submitting withdrawal on child chain…")

        // Compute stable fee estimate from a probe body (nonce doesn't affect size).
        let withdrawFeeProbeBody = TransactionBody(
            accountActions: [AccountAction(owner: buyer, delta: 0)],
            actions: [], depositActions: [], genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: buyer, nonce: nonce, demander: seller, amountDemanded: amountDemanded, amountWithdrawn: amountDeposited)],
            signers: [buyer], fee: 1, nonce: 0, chainPath: childPath
        )
        let withdrawBaseSize = UInt64(withdrawFeeProbeBody.toData()?.count ?? 512) + 16
        let (withdrawFee, withdrawFeeOverflow) = withdrawBaseSize.multipliedReportingOverflow(by: effectiveFeeRate)
        guard !withdrawFeeOverflow else {
            printError("Effective fee rate \(effectiveFeeRate) overflows the withdrawal fee calculation"); throw ExitCode.failure
        }

        var withdrawSubmitted = false
        var withdrawTxCID: String? = nil
        for attempt in 1...max(1, withdrawTimeout / 3) {
            // Re-fetch the buyer's child nonce on each attempt: a competing tx from the
            // buyer can advance the nonce between retries, making a cached value stale.
            guard let childNonce = try await fetchJSON("\(childRpc)/api/nonce/\(buyer)?chainPath=\(childQuery)")["nonce"] as? UInt64 else {
                if attempt < withdrawTimeout / 3 { try await Task.sleep(nanoseconds: 3_000_000_000) }
                continue
            }
            let wb = TransactionBody(
                accountActions: [AccountAction(owner: buyer, delta: Int64(amountDeposited) - Int64(withdrawFee))],
                actions: [], depositActions: [], genesisActions: [], receiptActions: [],
                withdrawalActions: [WithdrawalAction(withdrawer: buyer, nonce: nonce, demander: seller, amountDemanded: amountDemanded, amountWithdrawn: amountDeposited)],
                signers: [buyer], fee: withdrawFee, nonce: childNonce, chainPath: childPath
            )
            let wh = try HeaderImpl<TransactionBody>(node: wb)
            guard let ws = TransactionSigning.sign(body: wb, bodyCID: wh.rawCID, privateKeyHex: privateKey) else { break }
            guard let wd = wb.toData() else { break }
            let wp: [String: Any] = [
                "signatures": [publicKey: ws],
                "bodyCID": wh.rawCID,
                "bodyData": wd.map { String(format: "%02x", $0) }.joined(),
                "chainPath": childPath,
            ]
            let wj = try JSONSerialization.data(withJSONObject: wp)
            let wr = try await postJSON("\(childRpc)/api/transaction", body: wj)
            if wr["accepted"] as? Bool == true {
                withdrawSubmitted = true
                withdrawTxCID = wr["txCID"] as? String
                printSuccess("Withdrawal submitted (attempt \(attempt))")
                break
            }
            if attempt < withdrawTimeout / 3 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard withdrawSubmitted else {
            printWarning("Could not submit withdrawal — child node may not yet reference the parent receipt in its parentState.")
            printWarning("Rerun `swap buy --yes --swap-id \"\(swapId)\"` after a few more parent blocks. Receipt is already mined; you will not be charged again.")
            throw ExitCode.failure
        }

        // ── Step 5: confirm withdrawal mined via tx receipt ──────────────────
        // Confirming by deposit-disappearance is ambiguous (reorg, wrong RPC path).
        // Confirm via the exact withdrawal txCID when available; fall back to deposit
        // disappearance only if the submission response did not include a txCID.
        print("[5/5] Waiting for withdrawal to be mined on child…")
        let withdrawMined: Bool
        if let txCID = withdrawTxCID {
            withdrawMined = try await pollUntil(timeout: withdrawTimeout, interval: 2) {
                let r = try await self.fetchJSON("\(self.childRpc)/api/receipt/\(txCID)?chainPath=\(childQuery)")
                return r["blockHash"] != nil
            }
        } else {
            withdrawMined = try await pollUntil(timeout: withdrawTimeout, interval: 2) {
                let s = try await self.queryDepositState(rpc: self.childRpc, demander: seller, amount: amountDemanded, nonce: nonce, chainPath: childPath)
                return s["exists"] as? Bool == false
            }
        }
        if withdrawMined {
            printSuccess("Swap complete! Received \(amountDeposited) child-coin.")
        } else {
            // Contract 5 (reorg-safety): the withdrawal didn't confirm in time. Distinguish
            // "still pending" from "the receipt was reorged out" — in the latter case the
            // seller was NOT paid either and the withdrawal can never mine as-is. Re-check
            // the receipt is still on-chain and ours before telling the buyer to retry.
            let receiptStillThere = try await queryReceiptState(rpc: rpc, demander: seller, amount: amountDemanded, nonce: nonce, destinationPath: childPath)
            if receiptStillThere["exists"] as? Bool == true, receiptStillThere["withdrawer"] as? String == buyer {
                printWarning("Withdrawal submitted but not yet mined; the parent receipt is still confirmed. Run `ln swap status --swap-id \"\(swapId)\"` or rerun to resume — you will not be charged again.")
            } else {
                printError("Withdrawal did not mine AND the parent receipt is no longer confirmed for you — the parent likely reorged. The seller was not paid either; re-run `swap buy` to re-establish the receipt before withdrawing.")
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - swap status

struct SwapStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current state of a swap (deposit exists? receipt exists? withdrawal done?)"
    )

    @Option(help: "Child-chain node base URL (without /api suffix)")
    var childRpc: String

    @Option(help: "Parent-chain node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Swap ID printed by `ln swap sell` (directory:nonce:seller:amountDemanded:amountDeposited)")
    var swapId: String

    func run() async throws {
        let fields = swapId.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5,
              let nonce = UInt128(fields[1]),
              CryptoUtils.isValidAddress(fields[2]),
              let amountDemanded = UInt64(fields[3]),
              let amountDeposited = UInt64(fields[4]) else {
            printError("Invalid swap-id format. Expected: directory:nonce:seller:amountDemanded:amountDeposited")
            throw ExitCode.failure
        }
        guard nonce <= UInt128(UInt64.max) else {
            printError("Invalid swap-id: nonce exceeds UInt64.max and is not serializable")
            throw ExitCode.failure
        }
        let directory = fields[0]
        let seller    = fields[2]

        let childInfo = try await fetchJSON("\(childRpc)/api/chain/info")
        let childPath = (childInfo["chains"] as? [[String: Any]])?.first.flatMap { $0["chainPath"] as? [String] } ?? [directory]
        let parentInfo = try await fetchJSON("\(rpc)/api/chain/info")
        let parentPath = (parentInfo["chains"] as? [[String: Any]])?.first.flatMap { $0["chainPath"] as? [String] } ?? []

        let depositState  = try await queryDepositState(rpc: childRpc, demander: seller, amount: amountDemanded, nonce: nonce, chainPath: childPath)
        let receiptState  = try await queryReceiptState(rpc: rpc, demander: seller, amount: amountDemanded, nonce: nonce, destinationPath: childPath)
        let parentHeight  = try await fetchJSON("\(childRpc)/api/chain/parent-height?chainPath=\(childPath.joined(separator: "/"))")["parentHeight"] as? UInt64

        printHeader("Swap status")
        printKeyValue("Swap ID",         swapId)
        printKeyValue("Directory",       directory)
        printKeyValue("Seller",          seller)
        printKeyValue("Nonce",           nonce.description)
        printKeyValue("amountDeposited", String(amountDeposited))
        printKeyValue("amountDemanded",  String(amountDemanded))
        print("")
        // Treat nil (RPC error / missing "exists" key) as unknown rather than false.
        let depositExists: Bool? = depositState["exists"] as? Bool
        let receiptExists: Bool? = receiptState["exists"] as? Bool
        if let err = depositState["error"] as? String  { printWarning("Deposit query error: \(err)") }
        if let err = receiptState["error"] as? String  { printWarning("Receipt query error: \(err)") }
        if depositExists == true {
            printKeyValue("Deposit (child)", "exists — escrowed \(depositState["amountDeposited"] as? UInt64 ?? amountDeposited)")
        } else if depositExists == false {
            printKeyValue("Deposit (child)", "not found on chain")
        } else {
            printKeyValue("Deposit (child)", "unknown (query error)")
        }
        if receiptExists == true {
            printKeyValue("Receipt (parent)", "exists — withdrawer \(receiptState["withdrawer"] as? String ?? "?")")
        } else if receiptExists == false {
            printKeyValue("Receipt (parent)", "not yet created")
        } else {
            printKeyValue("Receipt (parent)", "unknown (query error)")
        }
        if let ph = parentHeight {
            printKeyValue("Child sees parent at height", String(ph))
        }
        print("")
        let phase: String
        if depositExists == false && receiptExists == true {
            // Contract 5: deposit-missing + receipt-present is NOT positive proof the
            // withdrawal mined. A missing deposit can also reflect a child reorg or a
            // wrong child RPC/path. `swap status` is stateless (the swap-ID carries no
            // buyer address or withdrawal txCID), so it cannot positively confirm the
            // claim — report it as likely-but-unverified rather than "Complete".
            phase = "Likely complete (UNVERIFIED) — child deposit is gone and the receipt is present, but without the withdrawal txCID this cannot be positively confirmed. Verify the buyer's child balance, or re-check from the machine that ran `swap buy`."
        } else if depositExists == true && receiptExists == true {
            phase = "Waiting for child to advance past parent receipt so withdrawal can be mined"
        } else if depositExists == true && receiptExists == false {
            phase = "Waiting for buyer to create receipt on parent chain"
        } else if depositExists == false && receiptExists == false {
            // No positive signal — could be a typo, unmined deposit, or RPC error.
            phase = "Not found — deposit not on chain (not yet mined, wrong swap-ID, or never submitted)"
        } else {
            phase = "Unknown — one or more state queries failed"
        }
        printKeyValue("Phase", phase)
    }
}

// MARK: - shared helpers

extension SwapSellCommand: SwapHTTPHelpers {}
extension SwapBuyCommand:  SwapHTTPHelpers {}
extension SwapStatusCommand: SwapHTTPHelpers {}

protocol SwapHTTPHelpers {}

extension SwapHTTPHelpers {
    func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var req = URLRequest(url: url)
        #if canImport(FoundationNetworking)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        #endif
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func postJSON(_ urlString: String, body: Data) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        #if canImport(FoundationNetworking)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        #endif
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // GET /api/deposit?demander=&amount=&nonce=<hex>&chainPath=<path>
    func queryDepositState(rpc: String, demander: String, amount: UInt64, nonce: UInt128, chainPath: [String]) async throws -> [String: Any] {
        let path = chainPath.joined(separator: "/")
        let nonceHex = String(nonce, radix: 16)
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+")
        let pathEnc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return try await fetchJSON("\(rpc)/api/deposit?demander=\(demander)&amount=\(amount)&nonce=\(nonceHex)&chainPath=\(pathEnc)")
    }

    // GET /api/receipt-state?demander=&amount=&nonce=<hex>&chainPath=<destinationPath>
    func queryReceiptState(rpc: String, demander: String, amount: UInt64, nonce: UInt128, destinationPath: [String]) async throws -> [String: Any] {
        let path = destinationPath.joined(separator: "/")
        let nonceHex = String(nonce, radix: 16)
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+")
        let pathEnc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return try await fetchJSON("\(rpc)/api/receipt-state?demander=\(demander)&amount=\(amount)&nonce=\(nonceHex)&chainPath=\(pathEnc)")
    }

    func pollUntil(timeout: Int, interval: Int, condition: @escaping () async throws -> Bool) async throws -> Bool {
        var elapsed = 0
        while elapsed < timeout {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            elapsed += interval
        }
        return try await condition()
    }
}
