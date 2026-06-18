import ArgumentParser
import Foundation
import Lattice
import cashew
import UInt256

struct DiagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag",
        abstract: "Diagnose genesis block serialization (cross-platform)"
    )

    @Flag(name: .long, help: "Diagnose the testnet genesis instead of the mainnet Nexus genesis")
    var testnet: Bool = false

    private struct NullFetcher: Fetcher {
        func fetch(rawCid: String) async throws -> Data {
            throw NSError(domain: "DiagCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "NullFetcher"])
        }
    }

    func run() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        print("=== Genesis Serialization Diagnostic ===\n")

        // 1. Empty MerkleDictionary
        let emptyDict = MerkleDictionaryImpl<UInt64>()
        let emptyDictHeader = try HeaderImpl<MerkleDictionaryImpl<UInt64>>(node: emptyDict)
        let emptyDictJSON = emptyDict.toData().flatMap { String(data: $0, encoding: .utf8) } ?? "ERROR"
        print("1. Empty MerkleDictionary<UInt64>")
        print("   JSON: \(emptyDictJSON)")
        print("   CID:  \(emptyDictHeader.rawCID)\n")

        print("Chain: \(testnet ? "TESTNET" : "MAINNET (Nexus)")\n")

        // 2. ChainSpec
        let spec = testnet ? TestnetGenesis.spec : NexusGenesis.spec
        let specHeader = try VolumeImpl<ChainSpec>(node: spec)
        let specJSON = spec.toData().flatMap { String(data: $0, encoding: .utf8) } ?? "ERROR"
        print("2. ChainSpec")
        print("   JSON: \(specJSON)")
        print("   CID:  \(specHeader.rawCID)\n")

        // 3. UInt256.max encoding
        let targetData = try encoder.encode(UInt256.max)
        let targetJSON = String(data: targetData, encoding: .utf8) ?? "ERROR"
        print("3. UInt256.max encoded: \(targetJSON)\n")

        // 4. Build genesis block (same path as production NodeCommand)
        let fetcher = NullFetcher()
        let block = try await (testnet
            ? TestnetGenesis.buildGenesisBlock(config: TestnetGenesis.config, fetcher: fetcher)
            : NexusGenesis.buildGenesisBlock(config: NexusGenesis.config, fetcher: fetcher))

        // 5. Block field CIDs
        print("4. Block field CIDs:")
        print("   transactions:    \(block.transactions.rawCID)")
        print("   spec:            \(block.spec.rawCID)")
        print("   parentHomestead: \(block.parentState.rawCID)")
        print("   homestead:       \(block.prevState.rawCID)")
        print("   frontier:        \(block.postState.rawCID)")
        print("   childBlocks:     \(block.children.rawCID)")
        print("   previousBlock:   \(block.parent?.rawCID ?? "nil")\n")

        // 6. Full block JSON and CID
        let blockJSON = block.toData().flatMap { String(data: $0, encoding: .utf8) } ?? "ERROR"
        let blockHeader = try VolumeImpl<Block>(node: block)
        print("5. Genesis Block")
        print("   JSON: \(blockJSON)")
        print("   CID:  \(blockHeader.rawCID)\n")

        let expected = testnet ? TestnetGenesis.expectedBlockHash : NexusGenesis.expectedBlockHash
        print("Expected: \(expected ?? "nil")")
        print("Computed: \(blockHeader.rawCID)")
        print("Match:    \(blockHeader.rawCID == expected)")
    }
}
