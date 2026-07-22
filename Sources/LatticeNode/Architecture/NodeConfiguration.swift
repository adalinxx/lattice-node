import Crypto
import Foundation
import Ivy
import Lattice
import UInt256

public struct ChainAddress: Hashable, Sendable, CustomStringConvertible {
    public static let nexus = "Nexus"
    public static let maximumComponents = Int(UInt16.max)
    public static let maximumComponentBytes = Int(UInt16.max)

    public let components: [String]

    public init?(_ components: [String]) {
        guard components.first == Self.nexus,
              components.count <= Self.maximumComponents,
              components.allSatisfy(Self.isCanonicalComponent) else {
            return nil
        }
        self.components = components
    }

    public init?(string: String) {
        self.init(string.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    public var key: String { components.joined(separator: "/") }
    public var parent: ChainAddress? { ChainAddress(Array(components.dropLast())) }
    public var directory: String { components.last! }
    public var isNexus: Bool { components.count == 1 }
    public var description: String { key }

    private static func isCanonicalComponent(_ component: String) -> Bool {
        let bytes = component.utf8
        return !bytes.isEmpty
            && bytes.count <= maximumComponentBytes
            && !component.contains("/")
    }
}

public struct ParentEndpoint: Codable, Hashable, Sendable {
    public let publicKey: String
    public let host: String
    public let port: UInt16

    public init(publicKey: String, host: String, port: UInt16) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
    }

    var ivy: PeerEndpoint {
        PeerEndpoint(publicKey: publicKey, host: host, port: port)
    }
}

public enum NodeConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidChainPath
    case invalidMinimumRootWork
    case invalidPrivateKey
    case invalidPorts
    case invalidParentEndpoint
    case missingParentEndpoint
    case unexpectedParentEndpoint

    public var description: String {
        switch self {
        case .invalidChainPath:
            "chain path must be absolute, start with Nexus, and fit the setup wire frame"
        case .invalidMinimumRootWork: "minimum root work must be nonzero"
        case .invalidPrivateKey: "process private key must be a 32-byte Ed25519 key"
        case .invalidPorts: "overlay, fact-plane, and RPC ports must be nonzero and distinct"
        case .invalidParentEndpoint: "the parent endpoint must have a valid peer key, host, and port"
        case .missingParentEndpoint: "a child process requires its authenticated immediate-parent endpoint"
        case .unexpectedParentEndpoint: "the Nexus process has no parent endpoint"
        }
    }
}

/// Immutable setup and process identity for exactly one absolute chain path.
public struct NodeConfiguration: Sendable {
    public let address: ChainAddress
    public let minimumRootWork: UInt256
    public let storagePath: URL
    private let signingKeyBytes: [UInt8]
    public let processPublicKey: String
    public let listenPort: UInt16
    public let factListenPort: UInt16
    public let rpcPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let parentEndpoint: ParentEndpoint?
    public let minPeerKeyBits: Int

    public init(
        chainPath: [String],
        minimumRootWork: UInt256,
        storagePath: URL,
        privateKeyHex: String,
        listenPort: UInt16 = 4001,
        factListenPort: UInt16 = 4002,
        rpcPort: UInt16 = 8080,
        bootstrapPeers: [PeerEndpoint] = [],
        parentEndpoint: ParentEndpoint? = nil,
        minPeerKeyBits: Int = 0
    ) throws {
        guard let address = ChainAddress(chainPath) else {
            throw NodeConfigurationError.invalidChainPath
        }
        guard minimumRootWork > .zero else {
            throw NodeConfigurationError.invalidMinimumRootWork
        }
        guard (try? ChainHello(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components,
            minimumRootWorkHex: minimumRootWork.toHexString()
        ).encode()) != nil else {
            throw NodeConfigurationError.invalidChainPath
        }
        guard let bytes = Self.hexData(privateKeyHex),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
            throw NodeConfigurationError.invalidPrivateKey
        }
        guard listenPort != 0,
              factListenPort != 0,
              rpcPort != 0,
              Set([listenPort, factListenPort, rpcPort]).count == 3 else {
            throw NodeConfigurationError.invalidPorts
        }
        if address.isNexus, parentEndpoint != nil {
            throw NodeConfigurationError.unexpectedParentEndpoint
        }
        if !address.isNexus, parentEndpoint == nil {
            throw NodeConfigurationError.missingParentEndpoint
        }
        let normalizedParentEndpoint: ParentEndpoint?
        if let parentEndpoint {
            let host = parentEndpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = try? PeerKey(parentEndpoint.publicKey),
                  !host.isEmpty,
                  parentEndpoint.port != 0 else {
                throw NodeConfigurationError.invalidParentEndpoint
            }
            normalizedParentEndpoint = ParentEndpoint(
                publicKey: key.hex,
                host: host,
                port: parentEndpoint.port
            )
        } else {
            normalizedParentEndpoint = nil
        }

        self.address = address
        self.minimumRootWork = minimumRootWork
        self.storagePath = storagePath
        self.signingKeyBytes = Array(bytes)
        self.processPublicKey = try! PeerKey(
            rawRepresentation: signingKey.publicKey.rawRepresentation
        ).hex
        self.listenPort = listenPort
        self.factListenPort = factListenPort
        self.rpcPort = rpcPort
        self.bootstrapPeers = bootstrapPeers
        self.parentEndpoint = normalizedParentEndpoint
        self.minPeerKeyBits = minPeerKeyBits
    }

    public var chainPath: [String] { address.components }
    public var nexusGenesisCID: String { NexusGenesis.expectedBlockHash }
    public var signingKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyBytes)
    }
    public var runtimeContext: ChainRuntimeContext {
        get throws {
            try ChainRuntimeContext(path: chainPath, minimumRootWork: minimumRootWork)
        }
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var result = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
