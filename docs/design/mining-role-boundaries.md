# Mining Role Boundaries

This document is the mining contract. It defines the boundary between the
node, a coordinator, and nonce-search workers.

## Roles

`LatticeNode` is the authority for chain state. It owns block template
construction, transaction selection, coinbase/reward material, effective target
calculation, child-chain candidate embedding, merged-mining proof handling,
solution validation, block acceptance, persistence, and gossip publication.

`MiningCoordinator` owns work lifecycle outside the node. It fetches or
subscribes to node work, detects stale work, cancels old assignments, allocates
non-overlapping nonce ranges, collects worker results, resolves result races,
and submits the winning result to the node-owned solution API.

`LatticeMiner` is a worker. A worker receives a serialized nonce-0 `Block` node
assignment, deserializes it locally, searches the assigned nonce range, and
returns a nonce result or no result. It does not construct blocks, choose
transactions, resolve block content roots, know child-chain topology, gossip
blocks, generate child proofs, publish to Ivy, or hold or send coinbase keys.
Workers and coordinators must not hold or send coinbase private keys to the node.
It must not gossip blocks.

## Worker Protocol

Worker input is an immutable assignment:

| Field | Owner | Description |
| --- | --- | --- |
| `workId` | Node or coordinator | Stable identifier for the node template/work version. |
| `blockHex` | Node | Hex-encoded serialized nonce-0 `Block` node. The worker may deserialize it and derive the canonical PoW midstate locally; it must not resolve sub-CIDs or mutate/submit the block. |
| `target` | Node | Effective proof-of-work target for the parent plus embedded child candidates. |
| `nonceRange` | Coordinator | Inclusive start nonce and count assigned to this worker; ranges for one `workId` must not overlap. |
| `batchSize` | Coordinator | Local search chunk size used for cancellation checks and scheduling. |
| `staleToken` | Coordinator | Cancellation marker or generation number. If it changes, the worker stops returning results for the old work. |

Worker output is:

| Field | Description |
| --- | --- |
| `workId` | Work assignment the result belongs to. |
| `nonce` | Winning nonce, if found. |
| `hash` | Hash produced from the assigned `Block` node with the winning nonce, used by the coordinator for cheap sanity checks. |
| `range` | Range that produced the result. |
| `status` | `found`, `exhausted`, `cancelled`, or `stale`. |

Workers may also expose local progress counters, but those counters are not
consensus inputs and are not submitted to the node.

## Ownership Matrix

| Responsibility | Owner |
| --- | --- |
| Template and candidate construction | `LatticeNode` |
| Coinbase/reward address material | `LatticeNode` input contract; never a worker private key |
| Effective target calculation | `LatticeNode` |
| Merged-mining child proof generation and verification | `LatticeNode` |
| Block sealing from accepted solution | `LatticeNode` |
| Block acceptance, persistence, and gossip publication | `LatticeNode` |
| Stale-work detection and cancellation | `MiningCoordinator` |
| Nonce-range allocation and de-duplication | `MiningCoordinator` |
| Worker retry/backoff and result race resolution | `MiningCoordinator` |
| Proof-of-work nonce search | `LatticeMiner` worker |

## Submission Contract

The coordinator submits a result to the node, not a sealed block to peers. The
node validates that `workId` still names current work for the addressed chain,
that the nonce/hash satisfies the node-computed target, and that the submission
has not already been accepted. Stale, malformed, wrong-chain, wrong-target, and
duplicate submissions are rejected without mutating canonical state or
publishing a block.

After a valid submission, the node seals the block with the submitted nonce,
generates any required merged-mining proof material, accepts and persists the
block through the normal block-acceptance path, and publishes the accepted block
through the chain's `ChainNetwork`.

## Private-Key Boundary

Workers and coordinators must not send `minerPrivateKey` or any coinbase private
key material to the node in template/work requests. The node may receive
non-secret payout/address material according to the API contract. Any signing
that requires a private key must happen outside the worker submission path, or
inside a node-local wallet/identity path where the key is already node-owned and
never received from the miner over RPC.

This document is the role-boundary contract. RPC enforcement of the legacy
`minerPrivateKey` boundary is handled by the RPC admission mechanism, not by
these contract-presence tests.

## SOTA Basis

The contract follows the role split used by modern proof-of-work mining
protocols:

- [Stratum V2 Mining Protocol](https://stratumprotocol.org/specification/05-mining-protocol/)
  separates Mining Devices from upstream job/template roles. Mining devices
  receive work/search space and submit proof-of-work results.
- [Stratum V2 Job Declaration](https://stratumprotocol.org/specification/06-Job-Declaration-Protocol/)
  and [Template Distribution](https://stratumprotocol.org/specification/07-template-distribution-protocol/)
  separate template construction from downstream hash devices and allow an
  upstream role to coordinate valid work.
- [BIP22](https://github.com/bitcoin/bips/blob/master/bip-0022.mediawiki) /
  Bitcoin Core's [`getblocktemplate`](https://bitcoincore.org/en/doc/0.21.0/rpc/mining/getblocktemplate/)
  and [`submitblock`](https://developer.bitcoin.org/reference/rpc/submitblock.html)
  pattern keeps template construction and final block validation on the
  node/pool side while external mining software searches for proof-of-work.
- [AuxPoW / merged mining](https://en.bitcoin.it/wiki/Merged_mining_specification)
  keeps auxiliary proof material at the chain/protocol layer. Hash workers
  should not need child-chain topology or proof-generation responsibilities.

## Implementation Rule

Mining code must stay on the matrix above. `Sources/LatticeMiner` is a nonce
search worker target only. Node RPC transport, stale-work handling, child-node
orchestration, and solution submission live in the coordinator layer/tool. No Ivy
gossip, child proof generation, child-node orchestration, or miner-private-key
submission may exist in the worker target.
