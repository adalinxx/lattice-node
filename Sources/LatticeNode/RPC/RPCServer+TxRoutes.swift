import Lattice
import LatticeNodeRPCFuzzSupport
import Foundation
import Hummingbird
import HTTPTypes
import cashew
import UInt256

// Transaction & mempool RPC command services for RPCServer.
// Behavior-preserving extraction : /transaction, /transaction/prepare,
// /mempool, /fee/*, and /nonce route bodies. Pure relocation; no logic change.

extension RPCRoutes {
    static func submitTransaction(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 1_048_576) else {
            return jsonError("Invalid transaction format. Expected: {signatures, bodyCID, bodyData}")
        }
        let requestData = Data(buffer: buffer)
        guard let sub = RPCRequestBodyCodecs.decodeSubmitTransaction(requestData) else {
            return jsonError("Invalid transaction format. Expected: {signatures, bodyCID, bodyData}")
        }
        if sub.chain != nil {
            return jsonError("Use chainPath: [\"Nexus\", ...]; bare chain is no longer supported", status: .badRequest)
        }
        var parsedBody: TransactionBody?
        if let hex = sub.bodyData, let raw = Data(hex: hex) {
            guard let parsed = TransactionBody(data: raw) else {
                return jsonError("Invalid bodyData: cannot deserialize")
            }
            parsedBody = parsed
            let computedCID = try HeaderImpl<TransactionBody>(node: parsed).rawCID
            guard computedCID == sub.bodyCID else {
                return jsonError("CID mismatch: bodyData hashes to \(computedCID), not \(sub.bodyCID)")
            }
        }
        let chainPath: [String]
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: sub.chainPath ?? parsedBody?.chainPath) {
        case .success(let resolved): chainPath = resolved
        case .failure(let response): return response
        }
        if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: chainPath, body: requestData) {
            return proxied
        }
        if let unavailable = await chainUnavailableResponse(node: node, chainPath: chainPath) {
            return unavailable
        }
        guard let net = await node.network(forPath: chainPath) else {
            return jsonError("Unknown chain path: \(chainPath.joined(separator: "/"))", status: .notFound)
        }
        let body: TransactionBody?
        if let parsedBody {
            body = parsedBody
        } else {
            body = try? await HeaderImpl<TransactionBody>(rawCID: sub.bodyCID).resolve(fetcher: net.fetcher).node
        }
        guard let body else {
            return jsonError("Transaction body not found. Provide bodyData or ensure bodyCID is in the CAS.")
        }
        let tx = Transaction(signatures: sub.signatures, body: try HeaderImpl<TransactionBody>(node: body))
        let result = await node.submitTransactionWithReason(chainPath: chainPath, transaction: tx)
        struct R: Encodable { let accepted: Bool; let txCID: String; let error: String? }
        switch result {
        case .success: return json(R(accepted: true, txCID: sub.bodyCID, error: nil))
        case .failure(let r):
            log.info("Transaction rejected (\(sub.bodyCID)): \(r)")
            return json(R(accepted: false, txCID: sub.bodyCID, error: r), status: .badRequest)
        }
    }

    // MARK: - Transaction Preparation

    static func prepareTransaction(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 1_048_576) else {
            return jsonError("Invalid request body")
        }
        let requestData = Data(buffer: buffer)
        guard let body = RPCRequestBodyCodecs.decodePrepareTransaction(requestData) else {
            return jsonError("Invalid request body")
        }

        let accountActions = body.accountActions.map { AccountAction(owner: $0.owner, delta: $0.delta) }
        // General key-value state changes (e.g. timestamping/anchoring). These
        // apply to the isolated GeneralState dictionary, never to balances.
        let generalActions = (body.actions ?? []).map { Action(key: $0.key, oldValue: $0.oldValue, newValue: $0.newValue) }
        var depositActions: [DepositAction] = []
        for d in (body.depositActions ?? []) {
            guard let nonce = UInt128(d.nonce, radix: 16) else { return jsonError("Invalid deposit nonce hex: \(d.nonce)") }
            depositActions.append(DepositAction(nonce: nonce, demander: d.demander, amountDemanded: d.amountDemanded, amountDeposited: d.amountDeposited))
        }
        var receiptActions: [ReceiptAction] = []
        for r in (body.receiptActions ?? []) {
            guard let nonce = UInt128(r.nonce, radix: 16) else { return jsonError("Invalid receipt nonce hex: \(r.nonce)") }
            receiptActions.append(ReceiptAction(withdrawer: r.withdrawer, nonce: nonce, demander: r.demander, amountDemanded: r.amountDemanded, directory: r.directory))
        }
        var withdrawalActions: [WithdrawalAction] = []
        for w in (body.withdrawalActions ?? []) {
            guard let nonce = UInt128(w.nonce, radix: 16) else { return jsonError("Invalid withdrawal nonce hex: \(w.nonce)") }
            withdrawalActions.append(WithdrawalAction(withdrawer: w.withdrawer, nonce: nonce, demander: w.demander, amountDemanded: w.amountDemanded, amountWithdrawn: w.amountWithdrawn))
        }

        let chainPath: [String]
        if let bodyChainPath = body.chainPath {
            switch await resolveRequestedChainPath(node: node, request: request, chainPath: bodyChainPath) {
            case .success(let resolvedPath): chainPath = resolvedPath
            case .failure(let response): return response
            }
        } else {
            switch await resolveRequestedChainPath(node: node, request: request) {
            case .success(let resolvedPath): chainPath = resolvedPath
            case .failure(let response): return response
            }
        }
        if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: chainPath, body: requestData) {
            return proxied
        }
        if let unavailable = await chainUnavailableResponse(node: node, chainPath: chainPath) {
            return unavailable
        }
        let txBody = TransactionBody(
            accountActions: accountActions,
            actions: generalActions,
            depositActions: depositActions,
            genesisActions: [],
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: body.signers,
            fee: body.fee,
            nonce: body.nonce,
            chainPath: chainPath
        )

        let header = try HeaderImpl<TransactionBody>(node: txBody)
        guard let data = txBody.toData() else {
            return jsonError("Failed to serialize transaction body", status: .internalServerError)
        }

        struct R: Encodable { let bodyCID: String; let bodyData: String; let signingPreimage: String }
        return json(R(
            bodyCID: header.rawCID,
            bodyData: data.map { String(format: "%02x", $0) }.joined(),
            signingPreimage: TransactionSigning.preimage(body: txBody, bodyCID: header.rawCID)
        ))
    }

    // MARK: - Chain Deployment

    static func mempool(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        guard let net = await node.network(forPath: chain.path) else { return jsonError("Unknown chain path: \(chain.key)", status: .notFound) }
        struct R: Encodable { let count: Int; let totalFees: UInt64; let chain: String }
        return json(R(count: await net.nodeMempool.count, totalFees: await net.nodeMempool.totalFees(), chain: chain.directory))
    }

    static func feeEstimate(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let targetStr = request.uri.queryParameters["target"].map(String.init) ?? "5"
        let target = Int(targetStr) ?? 5
        let estimator = await node.feeEstimator(forPath: chain.path)
        let fee = await estimator.estimate(confirmationTarget: target)
        struct R: Encodable { let fee: UInt64; let target: Int; let chain: String }
        return json(R(fee: fee, target: target, chain: chain.directory))
    }

    static func feeHistogram(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let estimator = await node.feeEstimator(forPath: chain.path)
        let histogram = await estimator.histogram()
        struct Bucket: Encodable { let range: String; let count: Int }
        struct R: Encodable { let buckets: [Bucket]; let blockCount: Int; let chain: String }
        let blockCount = await estimator.blockCount
        return json(R(buckets: histogram.map { Bucket(range: $0.range, count: $0.count) }, blockCount: blockCount, chain: chain.directory))
    }

    // MARK: - Nonce

    static func getNonce(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        do {
            let nonce = try await node.getNonce(address: address, chainPath: chain.path)
            struct R: Encodable { let address: String; let nonce: UInt64; let chain: String }
            return json(R(address: address, nonce: nonce, chain: chain.directory))
        } catch {
            log.error("Nonce query failed for \(address): \(error)")
            return jsonError("Failed to query nonce", status: .internalServerError)
        }
    }

    // MARK: - Light Client
}
