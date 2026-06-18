import Lattice
import Foundation
import cashew
import UInt256

public enum NexusGenesis {

    // MARK: - Premine Owner

    public static let ownerPublicKeyHex =
        "ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d"

    public static let ownerAddress = CryptoUtils.createAddress(from: ownerPublicKeyHex)

    // MARK: - Chain Specification
    //
    // Economics:
    //   initialReward        = 2^20 = 1,048,576 tokens/block
    //   halvingInterval      = 876,600 blocks (100 years at 1h blocks: 365.25d × 24h × 100)
    //   totalSupply          ≈ 2 × halvingInterval × initialReward = 1,839,579,033,600
    //   premine              = halvingInterval / 5 = 175,320 blocks worth
    //   premineAmount        = premine × initialReward = 183,836,344,320 (~10%)
    //
    //   targetBlockTime      = 3,600,000 ms (1 hour)
    //   maxTransactions/block = 5,000
    //   maxStateGrowth       = 3 MB per block
    //   maxBlockSize         = 1 MB
    //   retargetWindow       = 120 blocks (~5 days)

    public static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 5000,
        maxStateGrowth: 3_000_000,
        maxBlockSize: 1_000_000,
        premine: 175_320,
        targetBlockTime: 3_600_000,
        initialReward: 1_048_576,
        halvingInterval: 876_600,
        retargetWindow: 120
    )

    // MARK: - Genesis Identity
    //
    // Frozen genesis identity. This CID is the deterministic rawCID of the genesis
    // built from `config` — the 100-year halving economics, the 1 MB maxBlockSize,
    // the premine owner, and the fixed timestamp below (0 = epoch, so the genesis
    // hash is fully reproducible and not tied to any wall-clock launch instant; the
    // directory is positional and no longer part of the spec). Any change to the
    // Nexus genesis spec, premine owner, or timestamp shifts this CID and MUST
    // update it here. verifyGenesis() enforces the built genesis matches it.

    public static let expectedBlockHash: String? = "bafyreiesbc6tau5vbvon5fjpotqswlbep6v7wlww3hho5zl4cw32vfsanu"

    // MARK: - Genesis Configuration

    // Timestamp reset to 0 (epoch): deterministic, launch-date-independent genesis.
    public static let genesisTimestamp: Int64 = 0

    public static let config = GenesisConfig(
        spec: spec,
        timestamp: genesisTimestamp,
        target: UInt256.max
    )

    public static func verifyGenesis(_ result: GenesisResult) -> Bool {
        if let expected = expectedBlockHash {
            return result.blockHash == expected
        }
        return true
    }

    // MARK: - Genesis Builder (for LatticeNode.init)

    public static func buildGenesisBlock(config: GenesisConfig, fetcher: Fetcher) async throws -> Block {
        let premineAmount = spec.premineAmount()
        let accountAction = AccountAction(
            owner: ownerAddress,
            delta: Int64(premineAmount)
        )
        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [ownerAddress],
            fee: 0,
            nonce: 0
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        let transaction = Transaction(
            signatures: [ownerPublicKeyHex: "genesis"],
            body: bodyHeader
        )
        return try await BlockBuilder.buildGenesis(
            spec: config.spec,
            transactions: [transaction],
            timestamp: config.timestamp,
            target: config.target,
            fetcher: fetcher
        )
    }

    // MARK: - Genesis Creation

    public static func create(fetcher: Fetcher) async throws -> GenesisResult {
        let block = try await buildGenesisBlock(config: config, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        let chainState = ChainState.fromGenesis(block: block, retentionDepth: DEFAULT_RETENTION_DEPTH)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }
}
