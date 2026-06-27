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

```bash
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build -c release   # binary at .build/release/LatticeNode
```

CI and tagged releases build on **Swift 6.1** with full `-O`. On a **Swift 6.3**
toolchain (e.g. macOS 26, whose only SDK ships 6.3.x) you must build a different
way — `swift build -c release` produces a binary that **crash-loops ~28s after
startup** with `freed pointer was not the last allocation`. That is the Swift 6.3
`-O` optimizer miscompiling the node's `Task { … Task.sleep … }` background loops
(peer refresh, reconnect, health monitor) into an out-of-order `swift_task_dealloc`
that corrupts the task allocator. It hits every node (root and child) and is *not*
a node bug. Two reliable options:

```bash
# A) Build native + unoptimized (sidesteps the optimizer bug). Use `xcrun` so the
#    compiler matches the installed SDK.
xcrun swift build -c release -Xswiftc -Onone     # or: xcrun swift build   (debug)

# B) Use Docker (below) — the published image is built on an unaffected toolchain.
```

> **Toolchain must match the SDK.** Don't "fix" the 6.3 crash by pinning an older
> compiler: a 6.1 `.xctoolchain` on `PATH` can't build against a 6.3 SDK and fails
> with `failed to build module 'Darwin' … select a toolchain which matches the SDK`.
> `xcrun swift build` uses Xcode's default toolchain, which always matches the SDK.

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

### Send Funds & Transact

These talk to a running node's RPC — point `--rpc` at any node serving the API.

```bash
# Simple transfer. --fee defaults to 1; --chain-path defaults to Nexus.
lattice-node send <recipient-address> 1000 --key my-key.json --rpc http://localhost:8080

# The general tx builder: a transfer with an auto-computed fee (clears the per-byte floor)...
lattice-node tx --key my-key.json --to <recipient-address> --amount 1000 --rpc http://localhost:8080

# ...or a key/value write on a chain that allows it (repeat --set for multiple keys):
lattice-node tx --key my-key.json --set greeting=hello --rpc http://localhost:8080
```

`send`/`tx` fetch the signer's nonce and balance, sign locally with the key file, and
submit through `/api/transaction`. The transaction is mined by whichever miner includes
it; balances update once a block carries it (`lattice-node query balance` or
`curl /api/balance/<addr>` to confirm).

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

Deploying a child is two steps — **seed it**, then **announce it** so other nodes
discover it. The `chain deploy` command does both in one signed call and prints the
command to start the child process:

```bash
# Seeds the child genesis, submits the genesisAction announce tx (signed by --key),
# and prints the `lattice-node node ...` start command. --key must be a FUNDED key.
# Add --wait to poll until the announce tx is mined.
lattice-node chain deploy \
  --rpc http://localhost:8080 --cookie-file ~/.lattice/.cookie --key my-key.json \
  --directory Etch --parent-directory Nexus \
  --target-block-time 3600000 --initial-reward 1048576

# Then fetch a child's staged genesis, or register/unregister a running child's RPC
# endpoint with the parent (privileged):
lattice-node chain genesis --rpc http://localhost:8080 --chain-path Nexus/Etch
lattice-node chain attach  --rpc http://localhost:8080 --cookie-file ~/.lattice/.cookie \
  --chain-path Nexus/Etch --child-rpc http://localhost:8081 --child-cookie-file ./etch-data/.cookie
lattice-node chain detach  --rpc http://localhost:8080 --cookie-file ~/.lattice/.cookie \
  --chain-path Nexus/Etch
```

<details>
<summary>Equivalent raw RPC (what <code>chain deploy</code> does under the hood)</summary>

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

</details>

The announcement is an ordinary mempool transaction, so it gossips and **any** miner can
include it — the child becomes discoverable even if your node never wins a block. Until a
block carries the genesis action, the child exists only locally. See
[Protocol §2.6](./protocol.md) for the creation/discovery model.

### Join & Merge-Mine an Existing Child Chain

To run and merge-mine a child that **already exists** (deployed by someone else, announced
on-chain) — say `Nexus/toy` — you don't redeploy it. Lattice is process-per-chain: you run
a separate node process for `toy` that extracts toy's blocks from your Nexus node's gossip
and verifies them itself (it doesn't trust the parent), then point one mining coordinator
at both chains. There is no "subscribe" verb — joining *is* running that process.

Because you didn't deploy `toy`, the one thing you must obtain is its **genesis bytes** (a
child process can't boot without them).

```bash
# 1. Fetch toy's genesis from any node that already tracks it (the deployer, a seed, or
#    your own node if you deployed it) -> { genesisHex, genesisHash, chainP2PAddress }.
lattice-node chain genesis --rpc http://<node-with-toy>:8080 --chain-path Nexus/toy

#    Your Nexus node's P2P address (the --subscribe-p2p value below) is its p2pAddress:
curl http://localhost:8080/api/chain/info

# 2. Run the toy process, subscribed to your Nexus. --subscribe-p2p makes it extract toy's
#    blocks from Nexus gossip and sync to the current tip; --peer (another toy node) is
#    optional and only speeds historical backfill.
lattice-node \
  --genesis-hex <toyGenesisHex> \
  --chain-directory toy --chain-path Nexus/toy \
  --subscribe-p2p <nexusPubKey@host:port> \
  --peer <anotherToyNode@host:port> \
  --port 4002 --rpc-port 8081 --data-dir ./toy-data

# 3. Register toy's RPC with your Nexus so the parent can deliver a mined toy block back
#    to the toy process. (Skip and the parent mines valid toy blocks with nowhere to put
#    them.) See operations.md "Merge-Mining Child Chains".
curl -s -X POST http://localhost:8080/api/chain/register-rpc \
  -H "Authorization: Bearer $(cat ~/.lattice/.cookie)" -H 'Content-Type: application/json' \
  -d '{"chainPath":["Nexus","toy"],"endpoint":"http://localhost:8081/api","authToken":"'"$(cat ./toy-data/.cookie)"'"}'

# 4. Merge-mine Nexus + toy with ONE coordinator. The Nexus node builds the merged block
#    template (Nexus block + toy candidate, via state access); the coordinator only does
#    PoW + submit-work. One solution advances BOTH chains. Repeat --child-node per child.
#    WAIT first: both nodes must answer `POST /api/chain/template` with 200 (warmup gate) —
#    starting the coordinator against a still-warming node hangs it. See operations.md
#    "Wait for ready, not just up".
LatticeMiningCoordinatorTool \
  --node       http://localhost:8080/api --rpc-cookie-file       ~/.lattice/.cookie \
  --child-node http://localhost:8081/api --child-rpc-cookie-file ./toy-data/.cookie \
  --worker-executable .build/debug/LatticeMiner --workers 2
```

`/api/chain/genesis` serves the genesis from a tracking node's deployed-children records,
or transparently proxies to toy's registered RPC endpoint. Merged mining is opt-in — you
choose which existing children to carry, and a child out-running its own hashrate is the
operator's choice, not a consensus gap. See
[Mining role boundaries](./design/mining-role-boundaries.md) for the node/coordinator/worker
split and [operations.md](./operations.md) for the full mining stack (incl. GPU workers).

### Cross-Chain Swaps

Atomically trade child-coin for parent-coin with no trusted intermediary. The flow is
deposit → receipt → withdrawal: the **seller** escrows child-coin, the **buyer** pays the
seller on the parent (minting a receipt), then the buyer withdraws the escrow on the child
by proving that receipt. The CLI drives all three legs.

```bash
# 1. Seller escrows child-coin and demands parent-coin in return. Prints the swap-id.
lattice-node swap sell --rpc http://localhost:8081 --key seller-key.json \
  --deposit 1000 --demand 100
# -> swap-id: Etch:<nonce>:<seller>:100:1000

# 2. Buyer pays the seller on the PARENT, waits for the receipt to be visible to the
#    child, then withdraws the escrow on the child — all from the one swap-id.
#    The payment is irreversible: --yes skips the confirmation prompt.
lattice-node swap buy --child-rpc http://localhost:8081 --rpc http://localhost:8080 \
  --key buyer-key.json --swap-id "Etch:<nonce>:<seller>:100:1000" --yes

# 3. Inspect a swap's progress at any time (deposit / receipt / withdrawal legs).
lattice-node swap status --child-rpc http://localhost:8081 --rpc http://localhost:8080 \
  --swap-id "Etch:<nonce>:<seller>:100:1000"
```

`swap buy` sizes the child withdrawal fee from the child's fee policy automatically; pass
`--withdrawal-fee-rate` only to override it (it must stay at or above the child's
`--min-fee-rate`, or the withdrawal is rejected *after* the irreversible payment). See
[Protocol](./protocol.md) for the deposit/receipt/withdrawal model.

### Query the Chain

A couple of canonical reads to confirm the node is up:

```bash
# Chain status (height, tip, target)
curl http://localhost:8080/api/chain/info

# Account balance
curl http://localhost:8080/api/balance/<address>
```

You can also read **persisted state directly off disk** — no running node — with the
offline subcommands (point `--storage-path` at the node's `--data-dir`):

```bash
lattice-node status --storage-path ~/.lattice --directory Nexus   # tip, height, block counts
lattice-node query height --storage-path ~/.lattice               # just the height
lattice-node query tip    --storage-path ~/.lattice               # the tip CID
lattice-node identity --data-dir ~/.lattice --public-key-only      # the node's identity key
```

(`query balance` is intentionally a no-op offline — it points you at a running node's
`/api/balance/<address>`, since balances need resolved state.)

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
- [Deployment](../README.md#deployment) — production deployment, including cloud/NAT nodes
