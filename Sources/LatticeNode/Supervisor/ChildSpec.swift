import Foundation

/// The lattice-node-specific description of a child chain process to spawn.
/// Every field is derived by the parent at deploy time — deterministic ports,
/// the genesis it just built, its own P2P address — so a supervised child needs
/// no manual port/genesis/peer wiring. The argument vector mirrors what the
/// SmokeTests harness builds today (`lib/lattice.mjs spawnChild`), so a
/// supervised child is boot-identical to a manually-launched one.
public struct ChildSpec: Sendable, Equatable {
    public let directory: String
    public let chainPath: [String]
    public let genesisHex: String
    /// Parent chain P2P address for block extraction: `<pubkey>@host:port`.
    public let subscribeP2P: String
    /// Parent chain gossip endpoint to bootstrap the child's own gossip (`--peer`).
    public let bootstrapPeer: String?
    /// Child chain P2P port (deterministic from the parent base port + directory).
    public let port: UInt16
    /// Child RPC port (deterministic from the parent RPC base + directory).
    public let rpcPort: UInt16
    public let dataDir: String
    /// Public payout address to credit in the child's block-template coinbase, inherited from
    /// the parent node's `--coinbase-address`. nil → the child mines an empty-reward template
    /// (forfeiting its block reward), so this must be set for a child to earn its reward.
    public let coinbaseAddress: String?
    /// Config the child inherits from the parent (e.g. `--min-peer-key-bits`),
    /// already expressed as argv pairs.
    public let inheritedArguments: [String]
    /// The child's spawn-cert chain (root→…→child), base64-encoded JSON, ISSUED by this
    /// parent (its own chain extended with a cert for the provisioned child identity).
    /// Passed as `--spawn-cert-chain` so the child presents it and ancestors can classify
    /// it as a spawn-tree member and SERVE it consensus queries (inherited weight,
    /// parent-state continuity). nil ⇒ the child boots federated.
    public let spawnCertChainBase64: String?
    /// The child's provisioned p2p private key (hex), delivered via `LATTICE_PRIVATE_KEY`
    /// so the child's identity is the one this parent issued the cert for. nil ⇒ the child
    /// self-generates (and cannot be certified, since the parent wouldn't know its key).
    public let provisionedPrivateKeyHex: String?

    public init(
        directory: String,
        chainPath: [String],
        genesisHex: String,
        subscribeP2P: String,
        bootstrapPeer: String?,
        port: UInt16,
        rpcPort: UInt16,
        dataDir: String,
        coinbaseAddress: String? = nil,
        inheritedArguments: [String] = [],
        spawnCertChainBase64: String? = nil,
        provisionedPrivateKeyHex: String? = nil
    ) {
        self.directory = directory
        self.chainPath = chainPath
        self.genesisHex = genesisHex
        self.subscribeP2P = subscribeP2P
        self.bootstrapPeer = bootstrapPeer
        self.port = port
        self.rpcPort = rpcPort
        self.dataDir = dataDir
        self.coinbaseAddress = coinbaseAddress
        self.inheritedArguments = inheritedArguments
        self.spawnCertChainBase64 = spawnCertChainBase64
        self.provisionedPrivateKeyHex = provisionedPrivateKeyHex
    }

    /// The argument vector (excluding argv[0]) for `lattice-node`. Leads with the
    /// explicit `node` subcommand to match the harness invocation exactly rather
    /// than relying on it being the default subcommand. `inheritedArguments`
    /// carries the parent's namespace-independent policy (`--no-dns-seeds`,
    /// `--min-fee-rate`, `--min-peer-key-bits`). `--coinbase-address` is passed so the child
    /// claims its block reward (without it the child mines empty-reward templates).
    public func arguments() -> [String] {
        var args: [String] = [
            "node",
            "--genesis-hex", genesisHex,
            "--chain-directory", directory,
            "--chain-path", chainPath.joined(separator: "/"),
            "--subscribe-p2p", subscribeP2P,
            "--port", String(port),
            "--rpc-port", String(rpcPort),
            "--data-dir", dataDir,
        ]
        if let bootstrapPeer { args += ["--peer", bootstrapPeer] }
        if let coinbaseAddress { args += ["--coinbase-address", coinbaseAddress] }
        if let spawnCertChainBase64 { args += ["--spawn-cert-chain", spawnCertChainBase64] }
        args += inheritedArguments
        return args
    }

    // MARK: - Child environment (process-per-chain isolation)

    /// A supervised child is a separate OS process with its own chain identity.
    /// Process-per-chain isolation means it must NOT inherit the parent's ambient
    /// environment: deploy tokens, cloud credentials, and API keys that happen to
    /// live in the parent's env are unrelated to running a child chain, and
    /// copying the whole environment leaks them to every recursively-spawned
    /// descendant. Instead the child environment is built from an explicit
    /// ALLOWLIST — the loader/runtime/TLS variables the executable needs, plus the
    /// node's own documented tuning knobs — with the child-specific identity key
    /// injected separately. Anything not on the allowlist is dropped.

    /// Loader/runtime/TLS variables copied from the parent IF present. These are
    /// needed for the child executable to launch, find its dynamic libraries, and
    /// establish TLS connections. Absent keys are skipped.
    static let inheritedRuntimeKeys: [String] = [
        "PATH", "HOME", "TMPDIR", "TERM", "LANG", "LC_ALL", "LC_CTYPE",
        "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH",
        "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]

    /// Node tuning/operational knobs the child intentionally inherits. Every key
    /// here is read via `ProcessInfo.processInfo.environment` somewhere in
    /// LatticeNode (supervisor limits, logging, retention/pinning/eviction, and
    /// the `NodeTuning.fromEnvironment` sync/gossip/mempool knobs). These are
    /// configuration, not secrets — with the one deliberate exception of
    /// `LATTICE_KEY_PASSWORD`, inherited so the child can unlock its provisioned
    /// identity key. Be inclusive of documented knobs, but never blanket-copy.
    static let inheritedTuningKeys: [String] = [
        // Supervisor limits
        "LATTICE_SUPERVISE_RECONCILE_SECONDS",
        "LATTICE_MAX_SUPERVISED_CHILDREN",
        "LATTICE_MAX_SUPERVISE_DEPTH",
        // Identity-key unlock (needed to decrypt the provisioned key)
        "LATTICE_KEY_PASSWORD",
        // Logging
        "LOG_LEVEL",
        // Retention / pinning / eviction
        "RETENTION_DEPTH",
        "PIN_ANNOUNCE_EXPIRY",
        "REANNOUNCE_INTERVAL",
        "EVICTION_INTERVAL",
        "EVICT_GRACE_SECONDS",
        // NodeTuning.fromEnvironment knobs
        "SYNC_TIMEOUT_SECONDS",
        "SYNC_CATCHUP_THRESHOLD",
        "SYNC_SHALLOW_THRESHOLD",
        "FETCH_DEADLINE_SECONDS",
        "FETCH_POLL_MILLIS",
        "TX_DEDUP_WINDOW_SECONDS",
        "PIN_ANNOUNCE_DEDUP_WINDOW_SECONDS",
        "MAX_RECENT_TX_CIDS",
        "MAX_RECENT_PIN_ANNOUNCES",
        "MAX_RECENT_PEER_BLOCKS",
        "MAX_CONCURRENT_BLOCK_VALIDATIONS",
        "MAX_PENDING_GOSSIP_TASKS",
        "MAX_PENDING_CHAIN_ANNOUNCE_TASKS",
        "MEMPOOL_GOSSIP_CAPACITY",
        "MEMPOOL_GOSSIP_REFILL_PER_SEC",
        "MEMPOOL_FULL_BAN_THRESHOLD",
        "HARD_FAULT_BAN_THRESHOLD",
        "EXTRACTOR_MAX_PENDING_TASKS",
        "MEMPOOL_TX_EXPIRY_SECONDS",
    ]

    /// The environment a supervised child is launched with: an explicit allowlist
    /// drawn from `parentEnvironment` (defaults to this process's environment),
    /// plus the child-specific provisioned identity key when set. NEVER a copy of
    /// the whole parent environment — see the allowlists above. Exposed as its own
    /// method (rather than inlined into `launch()`) so the isolation guarantee is
    /// unit-testable without spawning a process.
    public func childEnvironment(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in Self.inheritedRuntimeKeys + Self.inheritedTuningKeys {
            if let value = parentEnvironment[key] { environment[key] = value }
        }
        if let provisionedPrivateKeyHex {
            environment["LATTICE_PRIVATE_KEY"] = provisionedPrivateKeyHex
        }
        return environment
    }

    /// Build the generic launch description for the supervisor. The child is
    /// launched with an allowlisted environment (see `childEnvironment()`) rather
    /// than a copy of the parent's, so unrelated parent secrets never leak into
    /// supervised children. When the parent provisioned the child's identity, its
    /// private key is delivered via `LATTICE_PRIVATE_KEY`.
    public func launch(nodeExecutable: URL) -> SupervisedLaunch {
        return SupervisedLaunch(
            label: directory,
            executableURL: nodeExecutable,
            arguments: arguments(),
            environment: childEnvironment()
        )
    }
}
