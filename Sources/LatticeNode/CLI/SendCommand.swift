import ArgumentParser
import Foundation
import Lattice
import cashew
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send tokens to an address"
    )

    @Argument(help: "Recipient address")
    var to: String

    @Argument(help: "Amount to send")
    var amount: UInt64

    @Option(help: "Path to sender key JSON file")
    var key: String

    @Option(help: "Node base URL, e.g. http://127.0.0.1:8080 (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Transaction fee")
    var fee: UInt64 = 1

    @Option(help: "Chain path (default: Nexus)")
    var chainPath: String = "Nexus"

    func run() async throws {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: String],
              let publicKey = keyJSON["publicKey"],
              let privateKey = keyJSON["privateKey"] else {
            printError("Invalid key file. Expected: {publicKey, privateKey}")
            throw ExitCode.failure
        }

        let senderAddress = CryptoUtils.createAddress(from: publicKey)

        printHeader("Sending \(amount) tokens")
        printKeyValue("From", senderAddress)
        printKeyValue("To", to)
        printKeyValue("Amount", "\(amount)")
        printKeyValue("Fee", "\(fee)")

        let balance = try await fetchJSON("\(rpc)/api/balance/\(senderAddress)")["balance"] as? UInt64 ?? 0

        let (totalCost, costOverflow) = amount.addingReportingOverflow(fee)
        guard !costOverflow else {
            printError("Amount + fee overflows UInt64")
            throw ExitCode.failure
        }
        guard balance >= totalCost else {
            printError("Insufficient balance: have \(balance), need \(totalCost)")
            throw ExitCode.failure
        }

        let nonce = try await fetchJSON("\(rpc)/api/nonce/\(senderAddress)")["nonce"] as? UInt64 ?? 0

        let chainInfo = try await fetchJSON("\(rpc)/api/chain/info")
        guard let chains = chainInfo["chains"] as? [[String: Any]],
              let _ = chains.first?["height"] as? UInt64 else {
            printError("Could not fetch chain height")
            throw ExitCode.failure
        }

        guard totalCost <= UInt64(Int64.max), amount <= UInt64(Int64.max) else {
            printError("Amount exceeds maximum token value")
            throw ExitCode.failure
        }
        guard !to.isEmpty else {
            printError("Invalid recipient address: must not be empty")
            throw ExitCode.failure
        }
        // Validate the recipient with the shared address rule (the same CID
        // structural check the faucet uses) rather than a bare prefix match, so
        // tokens can't be sent to a malformed/non-canonical address nobody can
        // spend from.
        guard CryptoUtils.isValidAddress(to) else {
            printError("Invalid recipient address: expected a canonical Lattice address CID")
            throw ExitCode.failure
        }

        let senderAction = AccountAction(
            owner: senderAddress,
            delta: -Int64(totalCost)
        )
        let recipientAction = AccountAction(
            owner: to,
            delta: Int64(amount)
        )

        let body = TransactionBody(
            accountActions: [senderAction, recipientAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [senderAddress],
            fee: fee,
            nonce: nonce,
            chainPath: chainPath.split(separator: "/").map(String.init)
        )

        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(body: body, bodyCID: bodyHeader.rawCID, privateKeyHex: privateKey) else {
            printError("Signing failed")
            throw ExitCode.failure
        }

        guard let bodyData = body.toData() else {
            printError("Serialization failed")
            throw ExitCode.failure
        }

        let txPayload: [String: Any] = [
            "signatures": [publicKey: signature],
            "bodyCID": bodyHeader.rawCID,
            "bodyData": bodyData.map { String(format: "%02x", $0) }.joined(),
            "chainPath": chainPath.split(separator: "/").map(String.init)
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
