import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import Ivy
import Lattice
import LatticeNode
import UInt256

@main
struct LatticeNodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "Run one Lattice chain process"
    )

    @Option(help: "Absolute slash-separated path, always beginning with Nexus")
    var chainPath = "Nexus"

    @Option(help: "Storage directory; defaults to ~/.lattice/chains/<chain-path>")
    var dataDirectory: String?

    @Option(help: "Process identity key file; created with mode 0600 when absent")
    var identityKey: String?

    @Option(help: "Minimum accepted Nexus-root work, as hexadecimal")
    var minimumRootWork = "1"

    @Option(help: "Same-chain overlay listen port")
    var listenPort: UInt16 = 4001

    @Option(help: "Private parent/child fact-plane listen port")
    var factListenPort: UInt16 = 4002

    @Option(help: "Loopback HTTP API port")
    var rpcPort: UInt16 = 8080

    @Option(help: "HTTP bind address; only loopback addresses are accepted")
    var rpcBind = "127.0.0.1"

    @Option(parsing: .upToNextOption, help: "Overlay peer as public-key@host:port")
    var peer: [String] = []

    @Option(help: "Immediate parent fact endpoint as public-key@host:port")
    var parent: String?

    @Option(help: "Minimum overlay peer-key work bits")
    var minimumPeerKeyBits = 0

    mutating func run() async throws {
        guard let address = ChainAddress(string: chainPath) else {
            throw ValidationError("--chain-path must be absolute and begin with Nexus")
        }
        guard let rootWork = UInt256.fromHexString(minimumRootWork), rootWork > .zero else {
            throw ValidationError("--minimum-root-work must be nonzero hexadecimal")
        }
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }

        let storage = try storageURL(for: address)
        let keyURL = identityKey.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent("process.key")
        let privateKeyHex = try loadOrCreateIdentity(at: keyURL)
        let parentEndpoint = try parent.map(parseParentEndpoint)
        let overlayPeers = try peer.map(parsePeerEndpoint)

        let configuration = try NodeConfiguration(
            chainPath: address.components,
            minimumRootWork: rootWork,
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            listenPort: listenPort,
            factListenPort: factListenPort,
            rpcPort: rpcPort,
            bootstrapPeers: overlayPeers,
            parentEndpoint: parentEndpoint,
            minPeerKeyBits: minimumPeerKeyBits
        )

        let network = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: network.remoteContentSource
        )
        let service = ChainService(
            process: process,
            childCandidateProvider: { [weak network] context in
                guard let network else { return [] }
                return await network.directChildCandidates(context)
            },
            childProofPublisher: { [weak network] publication in
                guard let network else { throw CancellationError() }
                _ = try await network.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    child: publication.childBlock
                )
            },
            acceptedBlockPublisher: { [weak network] blockCID in
                guard let network else { throw CancellationError() }
                try await network.publishAcceptedBlock(blockCID)
            },
            acceptedTransactionPublisher: { [weak network] rootCID in
                guard let network else { throw CancellationError() }
                try await network.publishTransaction(rootCID)
            }
        )
        try await service.restoreLocalTransactions()
        await network.installChildCandidateBuilder { [weak service, weak network] context in
            guard let service, let network else { return nil }
            return try await service.miningCandidate(
                parentCarrier: context.parentCarrier,
                parentContentSource: network.hierarchyContentSource,
                rewards: context.rewards,
                mode: context.mode
            )
        }
        await network.installAdmissionHandler {
            [weak service] header,
            package,
            directories in
            guard let service else { throw CancellationError() }
            return try await service.admitNetworkCandidate(
                header,
                authenticatedChildPackage: package,
                preparingChildDirectories: directories
            )
        }
        await network.installInheritedWorkHandler { [weak service] snapshot, key in
            guard let service else { throw CancellationError() }
            return try await service.applyInheritedWorkSnapshot(
                snapshot,
                from: key
            )
        }
        await network.installParentReadinessHandler { [weak service] ready in
            await service?.setParentConsensusReady(ready)
        }
        await network.installTransactionHandler {
            [weak service] transaction in
            guard let service else { throw CancellationError() }
            return try await service.submitNetworkTransaction(transaction)
        }
        await network.installTransactionInventoryProvider { [weak service] in
            guard let service else { return [] }
            return await service.transactionInventoryRoots()
        }
        try await network.start(process: process)
        let app = makeApplication(
            service: service,
            host: rpcBind,
            port: Int(rpcPort)
        )

        print("lattice-node \(address.key)")
        print("  process: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort)")

        let maintenance = Task {
            await runPeriodicMaintenance(every: .seconds(60)) {
                do {
                    _ = try await process.evictUnretainedVolumes()
                } catch is CancellationError {
                    return
                } catch {
                    FileHandle.standardError.write(Data(
                        "volume maintenance failed: \(error)\n".utf8
                    ))
                }
            }
        }
        do {
            try await app.runService()
        } catch {
            maintenance.cancel()
            await maintenance.value
            await network.stop()
            throw error
        }
        maintenance.cancel()
        await maintenance.value
        await network.stop()
    }

    private func storageURL(for address: ChainAddress) throws -> URL {
        var url: URL
        if let dataDirectory {
            url = URL(fileURLWithPath: dataDirectory)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lattice/chains", isDirectory: true)
            for component in address.components {
                url = url.appendingPathComponent(
                    storageComponent(component),
                    isDirectory: true
                )
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

func runPeriodicMaintenance(
    every interval: Duration,
    operation: @escaping @Sendable () async -> Void
) async {
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: interval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await operation()
    }
}

private func storageComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
}

private func loadOrCreateIdentity(at url: URL) throws -> String {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw ValidationError("identity key permissions must not grant group or other access")
        }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64,
              Data(hex: value) != nil else {
            throw ValidationError("identity key must contain exactly 32 hexadecimal bytes")
        }
        return value.lowercased()
    }

    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    let value = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    try Data((value + "\n").utf8).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return value
}

private func parsePeerEndpoint(_ value: String) throws -> PeerEndpoint {
    let parsed = try parseEndpoint(value)
    return PeerEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseParentEndpoint(_ value: String) throws -> ParentEndpoint {
    let parsed = try parseEndpoint(value)
    return ParentEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseEndpoint(_ value: String) throws -> (key: String, host: String, port: UInt16) {
    guard let separator = value.firstIndex(of: "@"),
          separator != value.startIndex else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    let key = String(value[..<separator])
    let address = String(value[value.index(after: separator)...])
    guard let colon = address.lastIndex(of: ":"),
          let port = UInt16(address[address.index(after: colon)...]),
          port != 0 else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    var host = String(address[..<colon])
    if host.first == "[", host.last == "]" {
        host.removeFirst()
        host.removeLast()
    }
    guard !host.isEmpty else {
        throw ValidationError("endpoint host must be nonempty")
    }
    return (key, host, port)
}

func makeApplication(
    service: ChainService,
    host: String,
    port: Int
) -> Application<RouterResponder<LatticeRequestContext>> {
    let router = Router(context: LatticeRequestContext.self)

    router.get("health") { request, context in
        let status = await service.status()
        var response = try json(status, request: request, context: context)
        if !status.mempoolAvailable {
            response.status = .serviceUnavailable
        }
        return response
    }
    router.get("v1/status") { request, context in
        try json(await service.status(), request: request, context: context)
    }
    router.get("v1/blocks/:cid") { request, context in
        let cid = try context.parameters.require("cid")
        return try await serviceCall(request: request, context: context) {
            try await service.acceptedBlock(cid)
        }
    }
    router.get("v1/transactions/:cid") { request, context in
        let cid = try context.parameters.require("cid")
        return try await serviceCall(request: request, context: context) {
            try await service.transaction(cid)
        }
    }
    router.get("v1/accounts/:address/proof") { request, context in
        let address = try context.parameters.require("address")
        return try await serviceCall(request: request, context: context) {
            try await service.accountProof(address: address)
        }
    }
    router.post("v1/transactions") { request, context in
        let input: SubmitTransactionRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitTransaction(input)
        }
    }
    router.post("v1/mining/templates") { request, context in
        let input: MiningTemplateRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.miningTemplate(input)
        }
    }
    router.post("v1/mining/work") { request, context in
        let input: SubmitWorkRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitWork(input)
        }
    }
    router.post("v1/children/intents") { request, context in
        let input: ChildDeployIntentRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.createChildDeployIntent(input)
        }
    }

    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

struct LatticeRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        coreContext = .init(source: source)
    }

    var maxUploadSize: Int { ChainServiceLimits.maximumPayloadBytes }
}

private func decode<Value: Decodable, Context: RequestContext>(
    _ request: Request,
    context: Context
) async throws -> Value {
    do {
        return try await request.decode(as: Value.self, context: context)
    } catch let error as any HTTPResponseError {
        throw error
    } catch {
        throw HTTPError(.badRequest)
    }
}

private func serviceCall<Value: Encodable, Context: RequestContext>(
    request: Request,
    context: Context,
    operation: () async throws -> Value
) async throws -> Response {
    do {
        return try json(
            try await operation(),
            request: request,
            context: context
        )
    } catch ChainServiceError.resourceNotFound {
        throw HTTPError(.notFound)
    } catch ChainServiceError.childIntentLimitReached {
        throw HTTPError(.tooManyRequests)
    } catch ChainServiceError.noDeploymentAvailable {
        throw HTTPError(.conflict)
    } catch ChainServiceError.mempoolUnavailable,
            ChainServiceError.parentUnavailable {
        throw HTTPError(.serviceUnavailable)
    } catch is ChainServiceError {
        throw HTTPError(.badRequest)
    } catch TransactionPoolError.full {
        throw HTTPError(.tooManyRequests)
    } catch is TransactionPoolError {
        throw HTTPError(.badRequest)
    } catch is MiningTemplateError {
        throw HTTPError(.badRequest)
    } catch ChainProcessError.chainNotBootstrapped {
        throw HTTPError(.conflict)
    }
}

private func json<Value: Encodable, Context: RequestContext>(
    _ value: Value,
    request: Request,
    context: Context
) throws -> Response {
    try context.responseEncoder.encode(value, from: request, context: context)
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
