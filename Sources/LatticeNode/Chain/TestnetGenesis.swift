import Lattice
import Foundation
import cashew
import UInt256

public enum TestnetGenesis {
    // MARK: - Premine Owner
    //
    // Faucet keypair — generated with `LatticeNode keys generate`.
    // The private key must NEVER be committed to source control.
    // Provide it at runtime via your deployment's secret store (never commit it).

    public static let ownerPublicKeyHex =
        "ed012379ebdca02a0e1b6803c44308fa7be2987f1d9035d91565f04f103d018c754c"

    public static let ownerAddress = CryptoUtils.createAddress(from: ownerPublicKeyHex)

    // MARK: - Chain Specification
    //
    // Economics are now IDENTICAL to mainnet (NexusGenesis.spec) — testnet shares
    // the exact same spec, so the only difference between the testnet and mainnet
    // genesis blocks is the faucet premine owner (and therefore the genesis CID).
    // The spec is referenced directly from NexusGenesis so the two cannot drift.

    public static let spec = NexusGenesis.spec

    // MARK: - Genesis Identity
    //
    // Frozen genesis identity. The deterministic rawCID of the genesis built from
    // `config` (the Nexus-identical spec, the faucet premine owner, and the fixed
    // timestamp 0 below). Distinct from the Nexus genesis only via the faucet owner.
    // Any change to the spec, premine owner, or timestamp shifts this CID and MUST
    // update it here. verifyGenesis() enforces the match.

    public static let expectedBlockHash: String? = "bafyreigazmtn3pffzsrdhqag5qw2vphcnu3krpk2tgpiddgekgoj5yv4ca"

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

    // MARK: - Genesis Builder

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
