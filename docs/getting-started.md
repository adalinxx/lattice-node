# Getting Started with Lattice Node

## Installation

### Docker (recommended — no build, any platform)

The published image is multi-arch (`linux/amd64` + `linux/arm64`), so this just downloads and runs:

```bash
docker run -d --name lattice-node --pull always --user root \
  -p 127.0.0.1:8080:8080 -v lattice-data:/data \
  ghcr.io/adalinxx/lattice-node:main \
  lattice-node --rpc-bind 0.0.0.0 --data-dir /data --min-peer-key-bits 16 --autosize
```

Then `curl http://localhost:8080/api/chain/info`. Notes: `--user root` lets the node
write the named volume; `--min-peer-key-bits 16` is **required** to peer with the live
network (see *Run a Node*).

### From source

Requires **Swift 6.1** — the toolchain the network is built and run on.

```bash
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build -c release   # binary at .build/release/LatticeNode
```

> **macOS 26 caveat:** macOS 26's only SDK is paired with Swift 6.3.2, which has a
> concurrency bug that aborts the node during chain sync. Until it's fixed upstream,
> run via **Docker** on macOS; build natively only on Linux with Swift 6.1.

## Quick Start

### Run a Node

```bash
# Join the Nexus (mainnet). --min-peer-key-bits 16 is required to peer with the seeds.
lattice-node --autosize --rpc-port 8080 --min-peer-key-bits 16

# Or with explicit resource settings
lattice-node --memory 0.5 --disk 20 --rpc-port 8080 --min-peer-key-bits 16
```

> **First boot grinds an identity key** (anti-Sybil PoW) before the RPC binds — at
> the 24-bit default this takes minutes and can look like a hang. The live seed
> nodes use 16-bit identities, so a joining node must set `--min-peer-key-bits 16`
> (this also sets your own grind difficulty). Without it the node connects but
> rejects the seeds and never syncs.

#### Resource footprint

A node runs to an explicit budget — it does not grow without bound:

| Flag | Default | Meaning |
|---|---|---|
| `--memory <GB>` | `0.25` | in-memory CAS/cache budget |
| `--disk <GB>` | `1.0` | on-disk CAS budget (bounded, evicting) |
| `--autosize` | — | size budgets to the host, capped by `--max-memory` / `--max-disk` |
| `--stateless` | off | force the disk CAS budget to `0` |

Storage is bounded and evicting: when the budget fills, data is dropped and
**refetched from peers on demand** (CAS is content-addressed, so any peer can
serve it and the result is self-verifying). This is why the footprint stays
small even as the chain grows.

**Stateless nodes are first-class.** `--stateless` keeps *no* local chain data,
yet the node still **both validates and mines** — it fetches the state subtrees
it needs from peers on demand, exactly as it validates. Combined with external
mining (below), a contributor can run and mine the Nexus on minimal hardware.

Throughput-heavy workloads don't change this: they run on **child chains** with
their own (faster/larger) `ChainSpec`, whose cost is borne only by that child's
participants — the Nexus node stays light.

The node will:
1. Generate a keypair (Ed25519, stored in `~/.lattice/identity.json`)
2. Connect to bootstrap peers
3. Sync the chain

The node does **not** run a nonce-search loop. Run the external coordinator
against the node's RPC address; it fans nonce ranges out to `lattice-miner`
worker processes when given `--worker-executable`:

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080/api \
  --rpc-cookie-file ~/.lattice/.cookie \
  --worker-executable "$(command -v lattice-miner)" \
  --workers 2 \
  --batch-size 128 \
  --once
```

`--worker-executable` is the seam for **any** miner implementing the
[Mining Worker Protocol](./mining-worker-protocol.md). The bundled `lattice-miner`
is a CPU worker; for GPU mining point it at
[`lattice-miner-gpu`](https://github.com/adalinxx/lattice-miner-gpu) (Apple
Silicon / Metal) and raise `--batch-size` so each GPU dispatch is large.

### Generate Keys

```bash
# Generate a new keypair
lattice-node keys generate

# Save to file
lattice-node keys generate --output my-key.json

# Derive address from public key
lattice-node keys address <public-key-hex>
```

### Local Development Network

```bash
# Start a single-node devnet with fast blocks
lattice-node devnet --mining --block-time 1000 --rpc-port 8080

# Start a 3-node cluster
lattice-node cluster --nodes 3 --mine Nexus --base-port 4001
```

> `devnet`/`cluster` `--mining`/`--mine` run a **local test-only** embedded miner
> for convenience. The production target is the E15 role split: node-owned
> seal/publish/validation, coordinator-owned work scheduling, and
> `LatticeMiner` workers that only search assigned nonces. See
> [Mining role boundaries](./design/mining-role-boundaries.md).

> **Note:** `--block-time 1000` (1 second) is for local devnet only. The Nexus
> production block-time target is 1 hour (`3600000` ms). Child chains run
> per-process and inherit their own cadence.

### Deploy & Announce a Child Chain

Deploying a child is two steps — **seed it**, then **announce it** so other nodes discover it.

```bash
# 1. Deploy (privileged) — seeds the child locally, returns its genesis.
#    maxBlockSize must be <= the node's --max-frame-size (default 4 MiB) - 1024.
curl -X POST http://localhost:8080/api/chain/deploy \
  -H "Authorization: Bearer $(cat ~/.lattice/.cookie)" -H 'Content-Type: application/json' \
  -d '{"directory":"Etch","parentDirectory":"Nexus","targetBlockTime":3600000,
       "initialReward":1048576,"halvingInterval":876600,"premine":0,
       "maxTransactionsPerBlock":5000,"maxStateGrowth":3000000,
       "maxBlockSize":1000000,"retargetWindow":120}'
# -> { "genesisHash": "<child-genesis-CID>", "genesisHex": "...", "chainP2PAddress": "..." }

# 2. Announce it into the parent. This is a NORMAL transaction that carries a
#    genesisAction (genesisActions is just an action type, like accountActions) — the
#    same prepare -> sign -> submit flow as any tx. Use a FUNDED key; replace <addr>/<pubkey>.

#  2a. Build the unsigned body. fee >= 1 per serialized byte (~400 here); the matching
#      negative accountAction debits it so balances conserve; signers is the ADDRESS.
curl -s "http://localhost:8080/api/nonce/<addr>?chainPath=Nexus"          # -> {"nonce": N}
curl -s -X POST http://localhost:8080/api/transaction/prepare -H 'Content-Type: application/json' -d '{
  "nonce": N, "signers": ["<addr>"], "fee": 400,
  "accountActions": [{"owner": "<addr>", "delta": -400}],
  "genesisActions": [{"directory": "Etch", "blockCID": "<genesisHash>"}],
  "chainPath": ["Nexus"] }'                                              # -> {bodyCID, bodyData, signingPreimage}

#  2b. Sign  "lattice-tx-v1:" + signingPreimage  with your ed25519 key, then submit:
curl -s -X POST http://localhost:8080/api/transaction -H 'Content-Type: application/json' -d '{
  "signatures": {"<pubkey>": "<sig-hex>"}, "bodyCID": "<bodyCID>",
  "bodyData": "<bodyData>", "chainPath": ["Nexus"] }'

# 3. Run the child process; it boots from the seeded genesis and subscribes to the parent.
lattice-node node --genesis-hex "<genesisHex>" --chain-directory Etch \
  --chain-path Nexus/Etch --subscribe-p2p "<chainP2PAddress>" \
  --port 4002 --rpc-port 8081 --data-dir ./etch-data
```

The announcement is an ordinary mempool transaction, so it gossips and **any** miner can
include it — the child becomes discoverable even if your node never wins a block. Until a
block carries the genesis action, the child exists only locally. See
[Protocol §2.6](./protocol.md) for the creation/discovery model.

### Query the Chain

A couple of canonical reads to confirm the node is up:

```bash
# Chain status (height, tip, target)
curl http://localhost:8080/api/chain/info

# Account balance
curl http://localhost:8080/api/balance/<address>
```

Other real endpoints include `/api/proof`, `/api/deposit` / `/api/deposits`,
and `/api/chain/deploy`. There is no order book / DEX API. See
[rpc-api.md](./rpc-api.md) for the full API reference.

## CLI Reference

The full command and flag listing lives in the
[README "CLI reference"](../README.md#cli-reference). Environment variables and
operational tuning are documented in [operations.md](./operations.md).

## Data Directory

```
~/.lattice/
├── identity.json          # Node keypair (Ed25519)
├── peers.json             # Known peers
├── anchors.json           # Anchor peers for eclipse protection
├── mempool.json           # Persisted pending transactions
├── .cookie                # RPC auth token for privileged endpoints
├── volumes.sqlite         # Shared content-addressed store (CAS) for all chains
└── Nexus/
    ├── chain_state.json   # Chain consensus state
    └── state.db           # Per-chain state SQLite database
```

## Next Steps

- [rpc-api.md](./rpc-api.md) — full HTTP/RPC API reference
- [design/mining-role-boundaries.md](./design/mining-role-boundaries.md) — node/coordinator/worker mining contract
- [operations.md](./operations.md) — running, monitoring, and tuning a node
- [development.md](./development.md) — building and contributing
- [deploy/README.md](../deploy/README.md) — production deployment
