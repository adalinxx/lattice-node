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

        guard to != nil || !generalActions.isEmpty || !genesisActions.isEmpty else {
            printError("Nothing to do. Provide --to/--amount, --set, and/or --create-chain.")
            throw ExitCode.failure
        }

        printHeader("Submitting transaction")
        printKeyValue("Signer", signer)
        if let to { printKeyValue("Transfer", "\(transferAmount) -> \(to)") }
        for a in generalActions { printKeyValue("Set", "\(a.key)=\(a.newValue ?? "null")") }
        for g in genesisActions { printKeyValue("Create chain", "\(g.directory) @ \(g.blockCID)") }

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

        // Conservation: debits == credits + fee. The signer is debited the transfer
        // amount plus the fee; the recipient (if any) is credited the amount.
        func buildBody(fee: UInt64) -> TransactionBody {
            var account: [AccountAction] = [AccountAction(owner: signer, delta: -Int64(transferAmount + fee))]
            if let to, transferAmount > 0 { account.append(AccountAction(owner: to, delta: Int64(transferAmount))) }
            return TransactionBody(
                accountActions: account,
                actions: generalActions,
                depositActions: [],
                genesisActions: genesisActions,
                receiptActions: [],
                withdrawalActions: [],
                signers: [signer],
                fee: fee,
                nonce: nonce,
                chainPath: path
            )
        }

        // Fee must clear a per-byte floor; size the body once, then cover it.
        let probeSize = UInt64(buildBody(fee: 1).toData()?.count ?? 512)
        let finalFee = max(fee ?? 0, probeSize + 16)
        guard transferAmount <= UInt64(Int64.max), finalFee <= UInt64(Int64.max),
              transferAmount + finalFee <= UInt64(Int64.max) else {
            printError("Amount + fee overflows"); throw ExitCode.failure
        }
        guard balance >= transferAmount + finalFee else {
            printError("Insufficient balance: have \(balance), need \(transferAmount + finalFee)")
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
