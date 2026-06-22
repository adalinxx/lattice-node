import Foundation
import Lattice
import cashew

public struct RegisterChainRPCRequestBody: Decodable, Equatable {
    public let chainPath: [String]
    public let endpoint: String
    public let authToken: String?
}

public struct ChainTemplateRequestBody: Decodable, Equatable {
    public let chain: String?
    public let chainPath: [String]?
    public let childNodes: [String]?
    public let childNodeAuth: [String: String]?
    public let rewardAddress: String?

    public init(
        chain: String?,
        chainPath: [String]?,
        childNodes: [String]?,
        childNodeAuth: [String: String]?,
        rewardAddress: String? = nil
    ) {
        self.chain = chain
        self.chainPath = chainPath
        self.childNodes = childNodes
        self.childNodeAuth = childNodeAuth
        self.rewardAddress = rewardAddress
    }
}

public struct ChainCandidateVolumeBody: Decodable, Equatable {
    public let root: String
    public let entries: [String: String]
}

public struct ChainCandidateRequestBody: Decodable, Equatable {
    public let chain: String?
    public let chainPath: [String]?
    public let parentBlockHex: String?
    public let parentHomesteadVolume: ChainCandidateVolumeBody?
    public let childNodes: [String]?
    public let childNodeAuth: [String: String]?
    public let timestampMs: Int64?
    public let rewardAddress: String?
}

public struct SubmitTransactionRequestBody: Decodable, Equatable {
    public let signatures: [String: String]
    public let bodyCID: String
    public let bodyData: String?
    public let chainPath: [String]?
    public let chain: String?
}

public struct PrepareAccountActionInput: Decodable, Equatable {
    public let owner: String
    public let delta: Int64
}

public struct PrepareDepositInput: Decodable, Equatable {
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let amountDeposited: UInt64
}

public struct PrepareReceiptInput: Decodable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let directory: String
}

public struct PrepareWithdrawalInput: Decodable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let amountWithdrawn: UInt64
}

public struct PrepareGeneralActionInput: Decodable, Equatable {
    public let key: String
    public let oldValue: String?
    public let newValue: String?
}

public struct PrepareTransactionRequestBody: Decodable, Equatable {
    public let nonce: UInt64
    public let signers: [String]
    public let fee: UInt64
    public let accountActions: [PrepareAccountActionInput]
    public let actions: [PrepareGeneralActionInput]?
    public let depositActions: [PrepareDepositInput]?
    public let receiptActions: [PrepareReceiptInput]?
    public let withdrawalActions: [PrepareWithdrawalInput]?
    public let chainPath: [String]?
}

public struct DeployChainRequestBody: Decodable {
    public let directory: String
    public let parentDirectory: String
    public let chainPath: [String]?
    public let targetBlockTime: UInt64
    public let initialReward: UInt64
    public let halvingInterval: UInt64
    public let premine: UInt64
    public let maxTransactionsPerBlock: UInt64
    public let maxStateGrowth: Int
    public let maxBlockSize: Int
    public let retargetWindow: UInt64
    public let wasmPolicies: [WasmPolicyRef]?
    public let transactionFilters: [String]?
    public let actionFilters: [String]?
    public let premineRecipient: String?
}

public enum RPCRequestBodyCodecs {
    public static let maxInputBytes = 1 << 20
    public static let maxChainCandidateInputBytes = 4_194_304
    private static let decoder = JSONDecoder()

    public static func decodeRegisterChainRPC(_ data: Data) -> RegisterChainRPCRequestBody? {
        guard data.count <= 4_096 else { return nil }
        return try? decoder.decode(RegisterChainRPCRequestBody.self, from: data)
    }

    public static func decodeChainTemplate(_ data: Data) -> ChainTemplateRequestBody? {
        guard data.count <= 65_536 else { return nil }
        return try? decoder.decode(ChainTemplateRequestBody.self, from: data)
    }

    public static func decodeChainCandidate(_ data: Data) -> ChainCandidateRequestBody? {
        guard data.count <= maxChainCandidateInputBytes else { return nil }
        return try? decoder.decode(ChainCandidateRequestBody.self, from: data)
    }

    public static func decodeSubmitTransaction(_ data: Data) -> SubmitTransactionRequestBody? {
        guard data.count <= maxInputBytes else { return nil }
        return try? decoder.decode(SubmitTransactionRequestBody.self, from: data)
    }

    public static func decodePrepareTransaction(_ data: Data) -> PrepareTransactionRequestBody? {
        guard data.count <= maxInputBytes else { return nil }
        return try? decoder.decode(PrepareTransactionRequestBody.self, from: data)
    }

    public static func decodeDeployChain(_ data: Data) -> DeployChainRequestBody? {
        guard data.count <= 131_072 else { return nil }
        return try? decoder.decode(DeployChainRequestBody.self, from: data)
    }

    public static func exerciseParserSurface(_ data: Data) {
        if let body = decodeRegisterChainRPC(data) {
            _ = validLoopbackHTTPBaseURL(body.endpoint)
            _ = body.chainPath.joined(separator: "/")
            _ = body.authToken?.isEmpty
        }
        if let body = decodeChainTemplate(data) {
            _ = body.childNodes?.allSatisfy(validLoopbackHTTPBaseURL)
        }
        if let body = decodeChainCandidate(data) {
            _ = body.chainPath?.joined(separator: "/")
            _ = body.childNodes?.allSatisfy(validLoopbackHTTPBaseURL)
            _ = body.parentHomesteadVolume?.entries.keys.contains(body.parentHomesteadVolume?.root ?? "")
            if let hex = body.parentBlockHex, let raw = Data(hex: hex) {
                _ = Block(data: raw)
            }
        }
        if let body = decodeSubmitTransaction(data) {
            if let hex = body.bodyData, let raw = Data(hex: hex), let parsed = TransactionBody(data: raw) {
                // known-valid local node; CID cannot fail
                _ = try! HeaderImpl<TransactionBody>(node: parsed).rawCID == body.bodyCID
            }
        }
        if let body = decodePrepareTransaction(data) {
            for action in body.depositActions ?? [] {
                _ = UInt128(action.nonce, radix: 16)
            }
            for action in body.receiptActions ?? [] {
                _ = UInt128(action.nonce, radix: 16)
            }
            for action in body.withdrawalActions ?? [] {
                _ = UInt128(action.nonce, radix: 16)
            }
        }
        if let body = decodeDeployChain(data) {
            _ = ChainSpec(
                maxNumberOfTransactionsPerBlock: body.maxTransactionsPerBlock,
                maxStateGrowth: body.maxStateGrowth,
                maxBlockSize: body.maxBlockSize,
                premine: body.premine,
                targetBlockTime: body.targetBlockTime,
                initialReward: body.initialReward,
                halvingInterval: body.halvingInterval,
                retargetWindow: body.retargetWindow,
                wasmPolicies: body.wasmPolicies ?? []
            ).isValid
        }
    }

    public static func validHTTPBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty,
              url.user(percentEncoded: false) == nil,
              url.password(percentEncoded: false) == nil,
              url.query(percentEncoded: false) == nil,
              url.fragment(percentEncoded: false) == nil,
              isSafeBasePath(url.path(percentEncoded: true)) else {
            return false
        }
        return true
    }

    /// A base URL may carry a simple path prefix (e.g. "/api"): merged-mining
    /// child nodes are addressed as "<base>/api" and the template handler then
    /// appends "/chain/info" / "/chain/candidate" to that base via string
    /// concatenation. Accept empty, "/", or a *canonical* "/seg[/seg...]" path:
    /// each segment non-empty and limited to [A-Za-z0-9_-]. Validated against the
    /// percent-ENCODED path so any "%" (e.g. "%2F", "%2e%2e") is rejected
    /// outright, which — together with the segment charset excluding "." — rules
    /// out traversal. Trailing and double slashes are rejected so concatenation
    /// can't produce "//chain/info" or other non-canonical routes.
    private static func isSafeBasePath(_ rawPath: String) -> Bool {
        if rawPath.isEmpty || rawPath == "/" { return true }
        guard rawPath.hasPrefix("/"), !rawPath.hasSuffix("/") else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let segments = rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    public static func validLoopbackHTTPBaseURL(_ raw: String) -> Bool {
        guard validHTTPBaseURL(raw),
              let host = URL(string: raw)?.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum RPCRequestFuzzTarget {
    public static let maxInputBytes = RPCRequestBodyCodecs.maxChainCandidateInputBytes

    public static func exercise(_ payload: Data) {
        guard payload.count <= maxInputBytes else { return }
        if let text = String(data: payload, encoding: .utf8) {
            _ = GenesisHexCodec.parseHex(text, maxPayloadBytes: maxInputBytes)
        }
        _ = GenesisHexCodec.parsePayload(payload, maxPayloadBytes: maxInputBytes)
        RPCRequestBodyCodecs.exerciseParserSurface(payload)
    }
}
