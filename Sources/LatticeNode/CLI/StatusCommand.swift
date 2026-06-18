import ArgumentParser
import Foundation
import Lattice

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show persisted chain status"
    )

    @Option(help: "Storage directory")
    var storagePath: String = "/tmp/lattice-devnet"

    @Option(help: "Storage namespace path")
    var directory: String = "Nexus"

    func run() async throws {
        printHeader("Chain Status")

        let persister = ChainStatePersister(
            storagePath: URL(fileURLWithPath: storagePath),
            directory: directory
        )

        guard let state = try await persister.load() else {
            printError("No persisted state found at \(storagePath)/\(directory)")
            print("")
            print("  Start a devnet first:")
            print("  \(Style.dim)lattice-node devnet --mining\(Style.reset)")
            throw ExitCode.failure
        }

        printKeyValue("Directory", directory)
        printKeyValue("Storage", storagePath)
        printKeyValue("Chain Tip", String(state.chainTip.prefix(32)) + "...")
        printKeyValue("Main Chain", "\(state.mainChainHashes.count) blocks")
        printKeyValue("Total Blocks", "\(state.blocks.count)")

        if !state.missingBlockHashes.isEmpty {
            printKeyValue("Missing Blocks", "\(state.missingBlockHashes.count)")
        }

        if let highest = state.blocks.max(by: { $0.blockHeight < $1.blockHeight }) {
            printKeyValue("Height", "\(highest.blockHeight)")
        }

        print("")

        if state.blocks.count > 0 {
            let recent = state.blocks.sorted(by: { $0.blockHeight > $1.blockHeight }).prefix(5)
            print("  \(Style.bold)Recent blocks:\(Style.reset)")
            for block in recent {
                let hash = String(block.blockHash.prefix(20)) + "..."
                let children = block.childHashes.isEmpty ? "" : " children=\(block.childHashes.count)"
                print("    #\(block.blockHeight) \(Style.dim)\(hash)\(children)\(Style.reset)")
            }
        }
    }
}
