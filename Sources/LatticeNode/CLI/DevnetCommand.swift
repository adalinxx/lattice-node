import ArgumentParser
import Foundation
import Lattice
import UInt256

struct DevnetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devnet",
        abstract: "Start a local development network"
    )

    @Option(help: "P2P listen port")
    var port: UInt16 = 4001

    @Flag(help: "Enable auto-mining")
    var mining: Bool = false

    @Option(help: "Target block time in milliseconds")
    var blockTime: UInt64 = 1000

    @Option(help: "Storage directory")
    var storagePath: String = "/tmp/lattice-devnet"

    @Option(help: "Max transactions per block")
    var maxTx: UInt64 = 100

    @Option(help: "RPC port (enables HTTP API)")
    var rpcPort: UInt16?

    @Option(name: .long, parsing: .singleValue, help: "Additional chain directories to mine (comma-separated)")
    var mine: [String] = []

    func run() async throws {
        printLogo()
        printHeader("Starting Lattice Devnet")

        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)

        printKeyValue("Public Key", String(keyPair.publicKey.prefix(32)) + "...")
        printKeyValue("Address", address)
        printKeyValue("Storage", storagePath)
        printKeyValue("P2P Port", "\(port)")
        printKeyValue("Block Time", "\(blockTime)ms")
        printKeyValue("Mining", mining ? "enabled" : "disabled")

        let fm = FileManager.default
        if !fm.fileExists(atPath: storagePath) {
            try fm.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        }

        let identityJSON = "{\"publicKey\":\"\(keyPair.publicKey)\",\"privateKey\":\"\(keyPair.privateKey)\"}"
        let identityPath = storagePath + "/identity.json"
        try identityJSON.write(toFile: identityPath, atomically: true, encoding: .utf8)
        #if !os(Windows)
        chmod(identityPath, 0o600)
        #endif

        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: maxTx,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: blockTime,
            initialReward: 1024,
            halvingInterval: 210_000
        )

        let genesisConfig = GenesisConfig.standard(spec: spec)
        let nodeConfig = LatticeNodeConfig(
            publicKey: keyPair.publicKey,
            privateKey: keyPair.privateKey,
            listenPort: port,
            storagePath: URL(fileURLWithPath: storagePath),
            enableLocalDiscovery: true,
            // Local dev network: random throwaway identities on a trusted local
            // topology. The mainnet peer-key-PoW gate (defaultMinPeerKeyBits)
            // would reject every dev peer's unground key, so opt out explicitly.
            minPeerKeyBits: 0
        )

        printHeader("Initializing Node")

        let node = try await LatticeNode(config: nodeConfig, genesisConfig: genesisConfig)
        let genesisHash = node.genesisResult.blockHash

        printKeyValue("Genesis CID", String(genesisHash.prefix(32)) + "...")
        printKeyValue("Reward", "\(spec.initialReward) tokens/block")
        printKeyValue("Halving", "every \(spec.halvingInterval) blocks")

        try await node.start()
        printSuccess("Node started on port \(port)")

        var rpcServer: RPCServer? = nil
        var rpcTask: Task<Void, any Error>? = nil
        if let rpcPort = rpcPort {
            let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "http://127.0.0.1")
            rpcServer = server
            rpcTask = Task { try await server.run() }
            printSuccess("RPC server on http://localhost:\(rpcPort)/api/chain/info")
        }

        // Devnet drives block production with a background producer rather than
        // an in-node miner. Each process is a single chain, so `--mine`'s extra
        // directories no longer apply; any non-empty mining flag just enables
        // production on this node's own chain.
        var producer: BackgroundBlockProducer? = nil
        if mining || !mine.isEmpty {
            let p = BackgroundBlockProducer(node: node)
            await p.start()
            producer = p
            printSuccess("Producing blocks")
        }

        printHeader("Devnet Running")
        print("  Press Ctrl+C to stop")
        print("")

        let keepAlive = AsyncStream<Void> { continuation in
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler {
                continuation.finish()
            }
            src.resume()
        }

        for await _ in keepAlive {}

        print("")
        printWarning("Shutting down...")
        await producer?.stop()
        await rpcServer?.shutdown()
        rpcTask?.cancel()
        await node.stop()
        printSuccess("Devnet stopped")
    }
}
