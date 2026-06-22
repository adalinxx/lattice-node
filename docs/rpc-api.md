# Lattice Node RPC API

This document is the single source of truth for the node's HTTP API. For
protocol-level detail (block structure, cross-chain semantics, state model),
see the protocol spec at [./protocol.md](./protocol.md) (§8).

Base URL: `http://localhost:<rpc-port>`

Endpoints that target chain state accept an optional `?chainPath=<path>` query
parameter. The path is interpreted relative to the chain being queried; when
the queried chain is Nexus, `Nexus/Payments` is the canonical Nexus-rooted
form and `Payments` is equivalent. When omitted, the request targets the
queried node's current chain. The legacy bare `?chain=<directory>` query
parameter is rejected. Cryptography is Ed25519: an address is the CID of an account's
public key. Block header fields are `parent`, `prevState`, `postState`,
`parentState`, `children`, and `height`.

## Authentication

Nodes generate `<dataDir>/.cookie` at startup. Include that cookie token as a
bearer credential when calling privileged endpoints:
```
Authorization: Bearer <token from ~/.lattice/.cookie>
```

Public read endpoints, `/health`, `/metrics`, and `/ws` remain public. Query
tokens are not accepted as credentials for privileged RPC routes.

### Privileged endpoints

The following endpoints mutate node state and require a valid bearer cookie
credential even when the RPC listener is bound to loopback. Otherwise they
return `401 Unauthorized`:

- `POST /api/chain/deploy`
- `POST /api/chain/register-rpc`
- `POST /api/chain/template`
- `POST /api/chain/submit-work`
- `POST /api/chain/submit-child-block`
- `POST /api/chain/parent-continuity`
- `GET /api/chain/candidate`
- `POST /api/chain/candidate`

## Chain

### GET /api/chain/info
Status of all chains hosted by this node, plus genesis and P2P metadata.

```json
{
  "chains": [
    {
      "directory": "Nexus",
      "parentDirectory": null,
      "height": 1234,
      "tip": "baguqeera...",
      "mining": true,
      "mempoolCount": 5,
      "syncing": false,
      "chainP2PAddress": "<pubkey>@127.0.0.1:4001"
    }
  ],
  "genesisHash": "baguqeera...",
  "genesisTimestamp": 0,
  "nexus": "Nexus",
  "p2pAddress": "<pubkey>@127.0.0.1:4001"
}
```

### GET /api/chain/spec
Chain specification parameters. `targetBlockTime` is in milliseconds (Nexus
targets `3600000`, i.e. 1 hour).

```json
{
  "directory": "Nexus",
  "targetBlockTime": 3600000,
  "initialReward": 1048576,
  "halvingInterval": 876600,
  "maxTransactionsPerBlock": 5000,
  "maxStateGrowth": 3000000,
  "maxBlockSize": 1000000,
  "premine": 175320,
  "premineAmount": 183836344320,
  "wasmPolicies": []
}
```

### Per-process control plane

These endpoints coordinate a tree of per-process chain nodes.

#### GET /api/chain/map
Map of full chain path → RPC endpoint for every registered chain whose endpoint
has been announced. Lets clients discover the direct HTTP endpoint of any chain
in the subtree.

```json
{"Nexus": "http://127.0.0.1:8080", "Nexus/Payments": "http://127.0.0.1:8081"}
```

#### POST /api/chain/register-rpc
Called by a child node on startup to announce its RPC endpoint to its parent.
Privileged endpoint; `endpoint` must be a loopback HTTP(S) base URL.

**Request:** `{"chainPath": ["Nexus", "Payments"], "endpoint": "http://127.0.0.1:8081"}`

**Response:** `{"ok": true}`

#### GET /api/chain/genesis?chainPath=<path>
Returns the genesis block (hex-encoded payload) for a child chain so a new
process can self-bootstrap without manual genesis passing.

```json
{
  "directory": "Payments",
  "genesisHash": "baguqeera...",
  "genesisHex": "0100...",
  "chainP2PAddress": "<pubkey>@127.0.0.1:4002"
}
```

#### POST /api/chain/deploy *(privileged)*
Deploy a new child chain under an existing parent. Destructive admin operation;
see [Privileged endpoints](#privileged-endpoints).

**Request:**
```json
{
  "directory": "Payments",
  "parentDirectory": "Nexus",
  "targetBlockTime": 3600000,
  "initialReward": 1048576,
  "halvingInterval": 876600,
  "premine": 0,
  "maxTransactionsPerBlock": 5000,
  "maxStateGrowth": 3000000,
  "maxBlockSize": 10000000,
  "retargetWindow": 100
}
```

**Response:** `{"directory", "parentDirectory", "genesisHash", "genesisHex", "chainP2PAddress"}`

#### GET /api/chain/candidate · POST /api/chain/candidate
Returns this chain's pending candidate block for a parent-chain miner to embed.
`POST` accepts `{"parentBlockHex": "...", "childNodes": ["http://..."], "childNodeAuth"?: {"http://...": "<token>"}}` to set
`parentState` continuity and recursively embed grandchild candidates. `childNodeAuth`
maps each grandchild base URL to that node's RPC cookie token.
Privileged endpoint; `childNodes` must be loopback HTTP(S) base URLs because the
node performs server-side requests to them.

#### POST /api/chain/template
Returns a fully built candidate block (nonce = 0) for a miner; the node assembles
`postState`, transactions, and embedded child candidates. Body:
`{"chainPath"?: ["Nexus", "..."], "childNodes"?: [...], "childNodeAuth"?: {"http://...": "<token>"}}`.
Privileged endpoint; `childNodes` must be loopback HTTP(S) base URLs because the
node performs server-side requests to them.

The coinbase recipient comes from the node's `--coinbase-address` config, never
the request (Mechanism A). The node signs the coinbase with its
persisted local coinbase authority; the coinbase credit is authorization-free,
so the node never holds the payout address's private key and the payout account
nonce is not consumed by rewards. The legacy `minerPrivateKey` and
`minerPublicKey` template fields are removed: the request body no longer decodes
them, and any such field a legacy client still sends is ignored — workers and
coordinators must not send coinbase private keys or miner private keys to the
node. See [Mining role boundaries](./design/mining-role-boundaries.md).

Response includes `workId`, the content identifier of the nonce-0 candidate.
Coordinators submit that `workId` plus a nonce to `/api/chain/submit-work`; the
node seals, validates, accepts, persists, and publishes accepted work.

#### POST /api/chain/submit-work
Submit a nonce result for node-owned work. Body:
`{"chainPath"?: ["Nexus", "..."], "workId": "<candidate-cid>", "nonce": 123, "hash"?: "<proof-of-work-hash-hex>"}`.

The node resolves `workId` locally, verifies it still builds on the addressed
chain's current tip, applies the nonce, checks the optional hash and PoW target,
then accepts/persists/publishes through the normal chain path. Stale, malformed,
wrong-target, wrong-chain, and duplicate submissions are rejected without
mutating canonical state or publishing a block.

## Accounts

### GET /api/balance/{address}
```json
{"address": "baguqeera...", "balance": 1048576, "chainPath": "Nexus"}
```

### GET /api/nonce/{address}
Next valid nonce for the address (stored nonce + 1; `0` for fresh accounts).
```json
{"address": "baguqeera...", "nonce": 0, "chain": "Nexus"}
```

### GET /api/proof/{address}
Balance proof for light-client verification (raw proof JSON). The witness proves
the account balance/nonce against the returned block header's `stateRoot`; a
client must still verify or otherwise trust the header chain before trusting
that root.

### GET /api/state/account/{address}
Account balance, nonce, existence flag, and recent transaction history.

### GET /api/state/summary
Chain height, tip hash, and state root.

## Blocks

### GET /api/block/latest
```json
{"hash": "baguqeera...", "height": 1234, "timestamp": 1742601600000, "target": "ff...", "chain": "Nexus"}
```

### GET /api/block/{id}
Fetch by hash or height. Returns header fields and the CIDs of `transactions`,
`prevState`, `postState`, `parentState`, `spec`, and `children`.

### GET /api/block/{id}/transactions
Summaries of the transactions in a block (fee, nonce, signers, per-action counts).

Optional pagination (defaults to the full collection for backward compatibility):
`?limit=` (clamped to 1…1000) and `?offset=` page over the block's transactions.
The response always includes `total` (entries in the block), `count` (entries in
this page), `offset`, and `nextOffset` (the offset of the next page, or `null`
when the last page has been returned). Omitting `limit` returns every entry.

### GET /api/block/{id}/children
Child-chain blocks embedded in this block. Supports the same optional
`?limit=`/`?offset=` pagination and `total`/`count`/`offset`/`nextOffset` fields
as `/transactions`; omitting `limit` returns every child.

### GET /api/block/{id}/state
Post-block state section CIDs (`accountState`, `depositState`, `receiptState`,
`genesisState`, `generalState`).

### GET /api/block/{id}/state/account/{address}
Account balance as of a specific block.

## Transactions

### POST /api/transaction
Submit a signed transaction.

**Request:**
```json
{
  "signatures": {"<publicKeyHex>": "<signatureHex>"},
  "bodyCID": "<cid>",
  "bodyData": "<hex-encoded body>",
  "chainPath": ["Nexus"]
}
```

**Response:** `{"accepted": true, "txCID": "baguqeera...", "error": null}`

### POST /api/transaction/prepare
Build and serialize an unsigned transaction body from structured action inputs.
Returns `{"bodyCID", "bodyData", "signingPreimage"}` ready to sign and submit.

**Request:**
```json
{
  "nonce": 1,
  "signers": ["<address>"],
  "fee": 1,
  "accountActions": [{"owner": "<address>", "delta": -1}],
  "actions": [{"key": "<key>", "oldValue": null, "newValue": "<value>"}],
  "chainPath": ["Nexus"]
}
```
`accountActions`/`depositActions`/`receiptActions`/`withdrawalActions` are optional
financial actions. **`actions`** are general key-value state changes applied to the
chain's isolated `GeneralState` dictionary (never balances) — use them to record
arbitrary data, e.g. **timestamping / proof-of-existence** (key = a content hash):
`oldValue: null` inserts (fails if the key exists), a matching `oldValue` updates
(compare-and-set), `newValue: null` deletes.

### GET /api/transaction/{txCID}
Full decoded transaction (actions, signers, signatures, block context).

### GET /api/transactions/{address}
Transaction history for an address.

### GET /api/receipt/{txCID}
Transaction receipt derived from the CAS (block context, account deltas, status).

### GET /api/mempool
```json
{"count": 5, "totalFees": 500, "chain": "Nexus"}
```

### GET /api/finality/{height} · GET /api/finality/config
Returns the confirmation **depth** for a height and the node's **local** finality
status (`isFinal`) under its configured policy (`--finality-confirmations`).
This is a **node-local guard, not protocol finality:** the consensus rule itself
has no finality gadget — any block may be reorganized at any depth under a heavier
`trueCumWork` (Lattice library `spec.md §9`). `isFinal` means "below this node's
configured local reorg-guard horizon," which different operators may set differently.

## Fee Market

### GET /api/fee/estimate?target=N
Estimate the fee for confirmation within N blocks.
```json
{"fee": 42, "target": 5, "chain": "Nexus"}
```

### GET /api/fee/histogram
Fee distribution across recent blocks.
```json
{"buckets": [{"range": "1-10", "count": 150}], "blockCount": 100, "chain": "Nexus"}
```

## Cross-Chain Transfer

Cross-chain value movement is deposit → receipt → withdrawal (no swaps or
orders). See [./protocol.md](./protocol.md) (§8) for the full flow.

### GET /api/deposit?demander=&amount=&nonce=<hex>&chainPath=<path>
Look up a single deposit by key.
```json
{"exists": true, "amountDeposited": 1000, "chain": "Payments", "key": "<depositKey>"}
```

### GET /api/deposits?limit=&after=
List deposits on a chain (paginated; `limit` max 1000).
```json
{
  "deposits": [
    {"key": "...", "demander": "baguqeera...", "amountDemanded": 1000, "nonce": "12ab", "amountDeposited": 1000}
  ],
  "count": 1,
  "chain": "Nexus"
}
```

### GET /api/receipt-state?demander=&amount=&nonce=<hex>&chainPath=<destinationPath>
Look up the receipt (withdrawer) recorded for a cross-chain demand.
```json
{"exists": true, "withdrawer": "baguqeera...", "directory": "Payments", "chainPath": ["Nexus", "Payments"], "key": "<receiptKey>"}
```

## Light Client

### GET /api/light/headers?from=X&to=Y
Chain headers for light-client sync (max range 500 per request).

### GET /api/light/proof/{address}
Account proof with block context (header hash, height, timestamp, state root)
for independent witness verification. The proof verifier checks that the witness
is bound to the embedded header metadata; header-chain / cumulative-work
verification is the light client's responsibility.

## Mining

The node does not run a nonce-search loop and exposes no start/stop mining
control. The E15 target split is:

- `LatticeNode` owns chain state, template/work construction, effective target
  calculation, solution validation, block sealing, acceptance, persistence,
  merged-mining proof handling, and gossip publication.
- `MiningCoordinator` owns stale-work detection, retry/backoff, nonce-range
  fan-out, result collection, and node submission.
- `LatticeMiner` workers only search immutable assigned work and return
  nonce/hash results.

See [Mining role boundaries](./design/mining-role-boundaries.md). The
coordinator CLI owns node transport and result submission; `lattice-miner`
workers only search assigned nonce ranges.

### GET /api/chain/template
Returns the current candidate block (assembled coinbase + merged-mined children
+ target) plus `workId` for external nonce search. The worker submits
`workId` and nonce to `/api/chain/submit-work`.

## Network

### GET /api/peers
```json
{"count": 12, "peers": [{"publicKey": "abcd...", "host": "1.2.3.4", "port": 4001}]}
```

## Observability

### GET /health
Liveness/readiness summary (status, chain height, peer count, sync state, uptime).

### GET /metrics
Prometheus-format metrics.
```
lattice_chain_height{chain="Nexus"} 1234
lattice_mempool_size{chain="Nexus"} 5
# lattice_mining_active: work/template-serving readiness, NOT in-process nonce search
lattice_mining_active{chain="Nexus"} 1
lattice_peer_count 12
lattice_chain_count 1
lattice_uptime_seconds 86400
```

### GET /ws?events=newBlock,newTransaction
Server-Sent Events stream (EventSource). Available event types: `newBlock`,
`newTransaction`, `chainReorg`, `syncStatus`.
