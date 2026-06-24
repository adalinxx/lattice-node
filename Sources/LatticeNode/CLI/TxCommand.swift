import ArgumentParser
import Foundation
import Lattice
import cashew
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Build, sign, and submit an arbitrary transaction from a key file.
///
/// One generic transaction tool: a transfer, general key-value writes, and/or
/// child-chain creation (`genesisActions`) are all just actions in a normal tx.
/// Handles the rules that apply to *every* transaction so callers don't have to:
/// the signer is the account *address*, the fee is debited so balances conserve,
/// and the fee is raised to clear the node's per-byte floor.
struct TxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tx",
        abstract: "Build, sign, and submit a transaction (transfer, KV write, and/or child-chain creation)"
    )

    @Option(help: "Path to the signer key JSON file {publicKey, privateKey}")
    var key: String

    @Option(help: "Node base URL, e.g. http://127.0.0.1:8080 (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Chain path (default: Nexus)")
    var chainPath: String = "Nexus"

    @Option(help: "Fee override; default auto-computes to clear the per-byte floor")
    var fee: UInt64?

    @Option(help: "Transfer recipient address (with --amount)")
    var to: String?

    @Option(help: "Transfer amount (with --to)")
    var amount: UInt64?

    @Option(name: .long, help: "General key-value write 'key=value' (insert). Repeatable.")
    var set: [String] = []

    @Option(name: .customLong("create-chain"), help: "Create a child chain 'directory=genesisBlockCID'. Repeatable.")
    var createChain: [String] = []

    // --- Cross-chain swap actions (a chain <-> its parent) ---
    // A swap sells this CHILD chain's coin for its PARENT chain's coin:
    //   seller (demander) --deposit on child  ->  buyer (withdrawer) --receipt on
    //   parent (pays seller) + --withdraw on child (claims the escrowed coin).
    // The shared swapNonce (a UInt128) ties the three legs together.

    @Option(name: .long, help: "SELL leg, on the CHILD chain (you = seller). Lock coin in escrow: 'amountDeposited:amountDemanded:swapNonce'. Repeatable.")
    var deposit: [String] = []

    @Option(name: .long, help: "BUY leg 1, on the PARENT chain (you = buyer). Pay the seller to authorize the claim: 'sellerAddr:amountDemanded:swapNonce:childDirectory'. Repeatable.")
    var receipt: [String] = []

    @Option(name: .long, help: "BUY leg 2, on the CHILD chain (you = buyer, after --receipt is mined). Claim the escrow: 'amountWithdrawn:sellerAddr:amountDemanded:swapNonce'. Repeatable.")
    var withdraw: [String] = []

    func run() async throws {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
        // Tolerate richer key files (extra/nested fields like a derivation block) —
        // parse as [String: Any] and pull the two fields we need, rather than a
        // brittle [String: String] cast that rejects any non-string value.
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let publicKey = keyJSON["publicKey"] as? String,
              let privateKey = keyJSON["privateKey"] as? String else {
            printError("Invalid key file. Expected JSON with string publicKey + privateKey")
            throw ExitCode.failure
        }
        let signer = CryptoUtils.createAddress(from: publicKey)
        let path = chainPath.split(separator: "/").map(String.init)

        // Parse the requested actions.
        if (to == nil) != (amount == nil) {
            printError("--to and --amount must be given together")
            throw ExitCode.failure
        }
        let transferAmount = amount ?? 0
        if let to, !CryptoUtils.isValidAddress(to) {
            printError("Invalid recipient address: \(to)")
            throw ExitCode.failure
        }

        var generalActions: [Action] = []
        for entry in set {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                printError("Invalid --set '\(entry)'. Expected key=value"); throw ExitCode.failure
            }
            generalActions.append(Action(key: String(entry[..<eq]), oldValue: nil,
                                         newValue: String(entry[entry.index(after: eq)...])))
        }

        var genesisActions: [GenesisAction] = []
        for entry in createChain {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                printError("Invalid --create-chain '\(entry)'. Expected directory=genesisBlockCID"); throw ExitCode.failure
            }
            let dir = String(entry[..<eq]); let cid = String(entry[entry.index(after: eq)...])
            guard !dir.contains("/"), !cid.isEmpty else {
                printError("Invalid --create-chain '\(entry)': directory must have no '/' and CID must be non-empty"); throw ExitCode.failure
            }
            genesisActions.append(GenesisAction(directory: dir, blockCID: cid))
        }

        // Cross-chain swap actions. Fields are ':'-separated; addresses (CIDs) and
        // directory names contain no ':' so the split is unambiguous. `swapNonce`
        // is a UInt128 swap identifier, distinct from the account `nonce`.
        var depositActions: [DepositAction] = []
        var depositLockTotal: UInt64 = 0          // child coin the signer locks in escrow
        for entry in deposit {
            let f = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let dep = UInt64(f[0]), let dem = UInt64(f[1]), let n = UInt128(f[2]), dep > 0, dem > 0 else {
                printError("Invalid --deposit '\(entry)'. Expected amountDeposited:amountDemanded:swapNonce (amounts > 0)"); throw ExitCode.failure
            }
            depositActions.append(DepositAction(nonce: n, demander: signer, amountDemanded: dem, amountDeposited: dep))
            let (s, ov) = depositLockTotal.addingReportingOverflow(dep); guard !ov else { printError("--deposit total overflows"); throw ExitCode.failure }; depositLockTotal = s
        }

        var receiptActions: [ReceiptAction] = []
        var receiptDebitTotal: UInt64 = 0         // parent coin the signer pays the seller (consensus-implicit)
        for entry in receipt {
            let f = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, CryptoUtils.isValidAddress(f[0]), let dem = UInt64(f[1]), let n = UInt128(f[2]), dem > 0, !f[3].isEmpty, !f[3].contains("/") else {
                printError("Invalid --receipt '\(entry)'. Expected sellerAddr:amountDemanded:swapNonce:childDirectory (amount > 0, directory has no '/')"); throw ExitCode.failure
            }
            receiptActions.append(ReceiptAction(withdrawer: signer, nonce: n, demander: f[0], amountDemanded: dem, directory: f[3]))
            let (s, ov) = receiptDebitTotal.addingReportingOverflow(dem); guard !ov else { printError("--receipt total overflows"); throw ExitCode.failure }; receiptDebitTotal = s
        }

        var withdrawalActions: [WithdrawalAction] = []
        var withdrawCreditTotal: UInt64 = 0       // child coin the signer receives from escrow
        for entry in withdraw {
            let f = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let amt = UInt64(f[0]), CryptoUtils.isValidAddress(f[1]), let dem = UInt64(f[2]), let n = UInt128(f[3]), amt > 0, dem > 0 else {
                printError("Invalid --withdraw '\(entry)'. Expected amountWithdrawn:sellerAddr:amountDemanded:swapNonce (amounts > 0)"); throw ExitCode.failure
            }
            withdrawalActions.append(WithdrawalAction(withdrawer: signer, nonce: n, demander: f[1], amountDemanded: dem, amountWithdrawn: amt))
            let (s, ov) = withdrawCreditTotal.addingReportingOverflow(amt); guard !ov else { printError("--withdraw total overflows"); throw ExitCode.failure }; withdrawCreditTotal = s
        }

        // Every AccountAction delta is Int64. Reject amounts near the boundary up
        // front so the body-building arithmetic below can never trap; real swap
        // amounts are nowhere near this, and the headroom covers the small fee.
        let feeHeadroom: UInt64 = 1_000_000
        for (v, label) in [(transferAmount, "--amount"), (depositLockTotal, "--deposit"), (receiptDebitTotal, "--receipt"), (withdrawCreditTotal, "--withdraw")] where v > UInt64(Int64.max) {
            printError("\(label) amount too large"); throw ExitCode.failure
        }
        var grossDebit: UInt64 = 0                // transfer + deposit lock + receipt payment (pre-fee)
        for v in [transferAmount, depositLockTotal, receiptDebitTotal] {
            let (s, ov) = grossDebit.addingReportingOverflow(v)
            guard !ov, s <= UInt64(Int64.max) - feeHeadroom else { printError("Combined debit too large"); throw ExitCode.failure }
            grossDebit = s
        }

        guard to != nil || !generalActions.isEmpty || !genesisActions.isEmpty
            || !depositActions.isEmpty || !receiptActions.isEmpty || !withdrawalActions.isEmpty else {
            printError("Nothing to do. Provide --to/--amount, --set, --create-chain, --deposit, --receipt, and/or --withdraw.")
            throw ExitCode.failure
        }

        printHeader("Submitting transaction")
        printKeyValue("Signer", signer)
        if let to { printKeyValue("Transfer", "\(transferAmount) -> \(to)") }
        for a in generalActions { printKeyValue("Set", "\(a.key)=\(a.newValue ?? "null")") }
        for g in genesisActions { printKeyValue("Create chain", "\(g.directory) @ \(g.blockCID)") }
        for d in depositActions { printKeyValue("Deposit (sell)", "lock \(d.amountDeposited), demand \(d.amountDemanded) [swap \(d.nonce)]") }
        for r in receiptActions { printKeyValue("Receipt (pay)", "\(r.amountDemanded) -> \(r.demander) for '\(r.directory)' [swap \(r.nonce)]") }
        for w in withdrawalActions { printKeyValue("Withdraw (claim)", "take \(w.amountWithdrawn) from \(w.demander)'s escrow [swap \(w.nonce)]") }

        // Read the nonce + balance on the SAME chain this tx targets (not the
        // node's default chain), and fail loudly if the node can't be reached: a
        // swallowed fetch must never masquerade as "balance 0" and block a funded
        // transaction. A successful query always carries the field, so an absent
        // field means the request failed (timeout / wrong chain / node error).
        // Keep '/' (the server splits the path on it) but encode characters that
        // would otherwise be read as query syntax, since directory names are not
        // charset-constrained.
        var chainPathAllowed = CharacterSet.urlQueryAllowed
        chainPathAllowed.remove(charactersIn: "&=+")
        let chainQuery = chainPath.addingPercentEncoding(withAllowedCharacters: chainPathAllowed) ?? chainPath
        guard let nonce = try await fetchJSON("\(rpc)/api/nonce/\(signer)?chainPath=\(chainQuery)")["nonce"] as? UInt64 else {
            printError("Could not read nonce for \(signer) on chain '\(chainPath)' — node unreachable or unknown chain path?")
            throw ExitCode.failure
        }
        guard let balance = try await fetchJSON("\(rpc)/api/balance/\(signer)?chainPath=\(chainQuery)")["balance"] as? UInt64 else {
            printError("Could not read balance for \(signer) on chain '\(chainPath)' — node unreachable or unknown chain path?")
            throw ExitCode.failure
        }

        // Conservation: the signer is debited the transfer, the fee, and any
        // deposit lock, and credited any withdrawal release. A receipt's payment to
        // the seller is added by consensus (LatticeState.netAccountDeltas), so it is
        // NOT an explicit AccountAction here — only covered by the balance check.
        func buildBody(fee: UInt64) -> TransactionBody {
            let signerDelta = Int64(withdrawCreditTotal) - Int64(transferAmount) - Int64(fee) - Int64(depositLockTotal)
            var account: [AccountAction] = [AccountAction(owner: signer, delta: signerDelta)]
            if let to, transferAmount > 0 { account.append(AccountAction(owner: to, delta: Int64(transferAmount))) }
            return TransactionBody(
                accountActions: account,
                actions: generalActions,
                depositActions: depositActions,
                genesisActions: genesisActions,
                receiptActions: receiptActions,
                withdrawalActions: withdrawalActions,
                signers: [signer],
                fee: fee,
                nonce: nonce,
                chainPath: path
            )
        }

        // Fee must clear a per-byte floor; size the body once, then cover it.
        let probeSize = UInt64(buildBody(fee: 1).toData()?.count ?? 512)
        let finalFee = max(fee ?? 0, probeSize + 16)
        guard finalFee <= feeHeadroom else { printError("Fee \(finalFee) exceeds safety headroom"); throw ExitCode.failure }
        let totalDebit = grossDebit + finalFee   // safe: grossDebit <= Int64.max - feeHeadroom
        // A withdrawal release lands in this same tx, offsetting the debit.
        let (available, availOv) = balance.addingReportingOverflow(withdrawCreditTotal)
        guard !availOv, available >= totalDebit else {
            let extra = withdrawCreditTotal > 0 ? " (+\(withdrawCreditTotal) from withdrawal)" : ""
            printError("Insufficient balance: have \(balance)\(extra), need \(totalDebit)")
            throw ExitCode.failure
        }
        let body = buildBody(fee: finalFee)
        printKeyValue("Fee", "\(finalFee)")

        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(body: body, bodyCID: bodyHeader.rawCID, privateKeyHex: privateKey) else {
            printError("Signing failed"); throw ExitCode.failure
        }
        guard let bodyData = body.toData() else { printError("Serialization failed"); throw ExitCode.failure }

        let txPayload: [String: Any] = [
            "signatures": [publicKey: signature],
            "bodyCID": bodyHeader.rawCID,
            "bodyData": bodyData.map { String(format: "%02x", $0) }.joined(),
            "chainPath": path
        ]
        let txJSON = try JSONSerialization.data(withJSONObject: txPayload)
        let response = try await postJSON("\(rpc)/api/transaction", body: txJSON)
        if response["accepted"] as? Bool == true {
            let txCID = response["txCID"] as? String ?? ""
            printSuccess("Transaction submitted: \(String(txCID.prefix(32)))...")
        } else {
            let error = response["error"] as? String ?? "Unknown error"
            printError("Transaction rejected: \(error)")
            throw ExitCode.failure
        }
    }

    private func httpGet(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { return Data() }
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: url) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
        #endif
    }

    private func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        let data = try await httpGet(urlString)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ urlString: String, body: Data) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let responseData: Data
        #if canImport(FoundationNetworking)
        responseData = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: request)
        responseData = data
        #endif
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}
