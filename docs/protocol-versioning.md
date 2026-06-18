# Protocol Versioning and Upgrades

## Version Fields

### Protocol Version
Included in every `ChainAnnounceData` message exchanged between peers. Allows nodes to detect incompatible peers before exchanging blocks.

```
Current: 2
Min supported: 2
```

Nodes reject peers with `protocolVersion < minSupportedVersion`.

### Node Version
Software version string (semver). Informational — does not affect consensus.

```
Current: 0.1.0
```

## Fork Activation

Forks are activated at a specific block height. Each fork has:

| Field | Type | Description |
|-------|------|-------------|
| name | String | Human-readable fork name |
| version | UInt16 | Protocol version this fork requires |
| activationHeight | UInt64 | Block height at which rules take effect |
| description | String | What changes |

### Current Forks

| Name | Version | Activation | Description |
|------|---------|------------|-------------|
| genesis | 1 | 0 | Initial protocol with PoW consensus, merged mining, CAS storage |
| child-block-proof-envelope | 2 | 0 | childBlock carries canonical proof envelopes |

### Adding a New Fork

1. Define the fork in `ProtocolVersion.swift`:
```swift
ForkActivation(
    name: "cascade",
    version: 2,
    activationHeight: 100_000,
    description: "Per-account nonces, EIP-1559 fee market"
)
```

2. Increment `LatticeProtocol.version` to 2
3. Add version-gated logic in validators:
```swift
if LatticeProtocol.activeForks(atHeight: height).contains(where: { $0.name == "cascade" }) {
    // New validation rules
}
```

4. Nodes running version 1 will reject blocks from version 2 peers after the activation height, prompting them to upgrade.

## Upgrade Types

### Soft Fork (Backward Compatible)
Tightens rules — old nodes may accept blocks that new nodes reject, but new blocks are valid under old rules. Example: reducing max block size.

### Hard Fork (Breaking)
Changes rules incompatibly — old nodes reject new blocks. Requires all nodes to upgrade before activation height. Example: new transaction types, changed PoW algorithm.

### Coordinated Upgrade Process

1. Release new node version with fork activation at future height
2. Communicate upgrade deadline to all node operators
3. Monitor upgrade adoption via `/api/peers` (check peer protocol versions)
4. Fork activates at the specified height
5. Nodes that didn't upgrade are left on the old chain
