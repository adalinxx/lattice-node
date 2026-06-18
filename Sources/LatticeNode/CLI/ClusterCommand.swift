import ArgumentParser
import Foundation
import Lattice
import UInt256

struct ClusterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cluster",
        abstract: "Run a multi-node mining cluster"
    )

    @Option(help: "Number of nodes to spawn (1-64)")
    var nodes: Int = 3

    @Option(help: "Base P2P port (each node increments by 1)")
    var basePort: UInt16 = 4001

    @Option(name: .long, help: "Comma-separated chain directories to mine (e.g. Nexus,AppChain)")
    var mine: String?

    @Option(help: "Target block time in milliseconds")
    var blockTime: UInt64 = 1000

    @Option(help: "Base storage directory")
    var storagePath: String = "/tmp/lattice-cluster"

    @Option(help: "Max transactions per block")
    var maxTx: UInt64 = 100

    @Option(help: "Status update interval in seconds")
    var statusInterval: UInt64 = 5

    func run() async throws {
        printLogo()
        printHeader("Starting Lattice Cluster")

        guard nodes >= 1 && nodes <= 64 else {
            printError("Node count must be between 1 and 64")
            throw ExitCode.failure
        }

        printKeyValue("Nodes", "\(nodes)")
        printKeyValue("Ports", "\(basePort)–\(basePort + UInt16(nodes) - 1)")
        printKeyValue("Storage", storagePath)
        printKeyValue("Block Time", "\(blockTime)ms")
        let miningChains = mine?.split(separator: ",").map(String.init) ?? []
        printKeyValue("Mining", miningChains.isEmpty ? "disabled" : miningChains.joined(separator: ", "))

        let fm = FileManager.default
        if !fm.fileExists(atPath: storagePath) {
            try fm.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        }

        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: maxTx,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: blockTime,
            initialReward: 1024,
            halvingInterval: 210_000
        )

        let genesisConfig = GenesisConfig.standard(spec: spec)
        let client = MultiNodeClient(
            genesisConfig: genesisConfig,
            baseStoragePath: URL(fileURLWithPath: storagePath)
        )

        printHeader("Spawning Nodes")

        let ids = try await client.spawnNodes(count: nodes, basePort: basePort)
        for id in ids {
            printSuccess("Created \(id)")
        }

        printHeader("Starting Network")

        for id in ids {
            try await client.startNode(id: id)
            let status = try await client.nodeStatus(id: id)
            printSuccess("\(id) listening on port \(status.port)")
        }

        if !miningChains.isEmpty {
            printHeader("Starting Miners")
            for id in ids {
                for chain in miningChains {
                    try await client.startMining(nodeId: id, directory: chain)
                    printSuccess("\(id) mining \(chain)")
                }
            }
        }

        printHeader("Cluster Running (\(nodes) nodes)")
        print("  Status updates every \(statusInterval)s. Press Ctrl+C to stop.")
        print("")

        let shutdown = AsyncStream<Void> { continuation in
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler {
                continuation.finish()
            }
            src.resume()
        }

        let statusTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(statusInterval))
                if Task.isCancelled { break }
                await printClusterStatus(client: client, ids: ids)
            }
        }

        for await _ in shutdown {}

        statusTask.cancel()

        print("")
        printWarning("Shutting down cluster...")
        await client.stopAll()
        printSuccess("All \(nodes) nodes stopped")
    }

    func printClusterStatus(client: MultiNodeClient, ids: [String]) async {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        print("\(Style.dim)── \(timestamp) ──\(Style.reset)")

        for id in ids {
            guard let node = await client.getNode(id: id) else { continue }
            let chains = await node.chainStatus()
            let miningCount = chains.filter(\.mining).count
            let miningLabel = miningCount > 0
                ? "\(Style.green)\(miningCount) chain\(miningCount == 1 ? "" : "s")\(Style.reset)"
                : "\(Style.dim)idle\(Style.reset)"

            print("  \(Style.bold)\(id)\(Style.reset)  \(miningLabel)")

            for c in chains {
                let tip = String(c.tip.prefix(16)) + "..."
                let status = c.mining
                    ? "\(Style.green)mining\(Style.reset)"
                    : "\(Style.dim)--\(Style.reset)"
                print("    \(Style.cyan)\(c.directory)\(Style.reset)"
                    + "  h=\(Style.green)\(c.height)\(Style.reset)"
                    + "  tip=\(Style.dim)\(tip)\(Style.reset)"
                    + "  mempool=\(c.mempoolCount)"
                    + "  \(status)")
            }
        }
        print("")
    }
}
