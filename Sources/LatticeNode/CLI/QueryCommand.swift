import ArgumentParser
import Foundation
import Lattice

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Query persisted chain state"
    )

    @Argument(help: "Query: height, tip, blocks [limit], or balance <address>")
    var expression: [String] = []

    @Option(help: "Storage directory")
    var storagePath: String = "/tmp/lattice-devnet"

    @Option(help: "Storage namespace path")
    var directory: String = "Nexus"

    func run() async throws {
        guard !expression.isEmpty else {
            printError("No query expression provided")
            print("")
            print("  Usage:")
            print("    \(Style.dim)lattice-node query height\(Style.reset)")
            print("    \(Style.dim)lattice-node query tip\(Style.reset)")
            print("    \(Style.dim)lattice-node query blocks [limit]\(Style.reset)")
            throw ExitCode.failure
        }

        let command = expression[0]

        let persister = ChainStatePersister(
            storagePath: URL(fileURLWithPath: storagePath),
            directory: directory
        )

        guard let state = try await persister.load() else {
            printError("No chain state at \(storagePath)/\(directory)")
            throw ExitCode.failure
        }

        switch command {
        case "height":
            if let highest = state.blocks.max(by: { $0.blockHeight < $1.blockHeight }) {
                print("\(highest.blockHeight)")
            } else {
                print("0")
            }

        case "tip":
            print(state.chainTip)

        case "blocks":
            let sorted = state.blocks.sorted(by: { $0.blockHeight < $1.blockHeight })
            let limit = expression.count > 1 ? (Int(expression[1]) ?? 20) : 20
            let blocks = sorted.suffix(limit)
            printHeader("Blocks (last \(blocks.count))")
            for block in blocks {
                let hash = String(block.blockHash.prefix(24)) + "..."
                let prev = block.parentBlockHash.map { String($0.prefix(12)) + "..." } ?? "genesis"
                print("  #\(block.blockHeight)  \(hash)  prev=\(prev)")
            }

        case "balance":
            guard expression.count > 1 else {
                printError("Usage: lattice-node query balance <address>")
                throw ExitCode.failure
            }
            printWarning("Balance queries require a running node with resolved state.")
            printWarning("Use the RPC endpoint: GET /api/balance/<address>")

        default:
            printError("Unknown query: \(command)")
            print("")
            print("  Available queries: height, tip, blocks, balance")
            throw ExitCode.failure
        }
    }
}
