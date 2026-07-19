# Lattice Node HTTP API

This is the HTTP surface of the current one-process/one-chain daemon.

Base URL: `http://127.0.0.1:<rpc-port>`

The listener is unauthenticated and therefore loopback-only. Put a
same-host authenticated proxy in front of it if another machine must call it;
the daemon itself rejects non-loopback bind addresses.

Every request targets the chain owned by that process. There is no `chainPath`
query selector. Whenever a path appears in a body or response, it is an
absolute array whose first element is `"Nexus"`; paths that omit it are rejected.

Requests are JSON. Transaction-bearing fields use a content-bound form so the
receiver can reconstruct and verify the transaction body CID:

```json
{
  "signatures": {"<public-key-hex>": "<signature-hex>"},
  "body": {
    "accountActions": [],
    "actions": [],
    "depositActions": [],
    "genesisActions": [],
    "receiptActions": [],
    "withdrawalActions": [],
    "signers": [],
    "fee": 0,
    "nonce": 0,
    "chainPath": ["Nexus"]
  }
}
```

## Status

### `GET /health`

### `GET /v1/status`

Both routes return the same chain-process status:

```json
{
  "phase": "active",
  "chainPath": ["Nexus"],
  "nexusGenesisCID": "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq",
  "tipCID": "<cid>",
  "height": 42,
  "mempoolCount": 3,
  "mempoolBytes": 2048,
  "pendingChildIntents": 0
}
```

A child reports `phase: "awaitingGenesis"`, with null tip and height, until it
receives its authenticated genesis link from its immediate parent.

## Transactions

### `POST /v1/transactions`

Submit one signed transaction whose body path exactly matches this process.

```json
{
  "transaction": {
    "signatures": {"<public-key-hex>": "<signature-hex>"},
    "body": {"chainPath": ["Nexus"], "...": "other TransactionBody fields"}
  }
}
```

Response:

```json
{
  "transactionCID": "<cid>",
  "mempoolCount": 4,
  "mempoolBytes": 2600
}
```

The unsigned premine is not a general RPC exception. It is accepted only while
constructing the exact pinned Nexus genesis block.

## Mining

Mining is an external pipeline: the node issues and later validates work,
`lattice-mining-coordinator` schedules ranges, and `lattice-miner` workers
search those ranges.

### `POST /v1/mining/templates`

Issue bounded, expiring work. This public route is Nexus-only; child candidates
are requested through the authenticated hierarchy plane while the template is
assembled.

```json
{
  "rewards": [
    {
      "chainPath": ["Nexus"],
      "transaction": {
        "signatures": {"<public-key-hex>": "<signature-hex>"},
        "body": {"chainPath": ["Nexus"], "...": "other TransactionBody fields"}
      }
    }
  ]
}
```

`rewards` may be empty. Each reward is an externally signed transaction for
one absolute chain path; process identity is never converted into wallet
identity.

Response fields:

- `workID`: CID of the nonce-zero candidate.
- `block`: the complete candidate block.
- `searchTarget`: easiest accepted target among the assembled hierarchy,
  bounded by the configured minimum Nexus-root work.
- `chainPath`: always `["Nexus"]` on this route.
- `expiresInMilliseconds`: template lifetime.

### `POST /v1/mining/work`

```json
{"workID": "<candidate-cid>", "nonce": 123456}
```

Response fields are `accepted`, `disposition`, `tipCID`,
`parentCarrierLink`, `parentGenesisLinks`, and `publishedChildProofs`.
Possible dispositions are `canonicalized`, `acceptedSide`, `carrier`,
`duplicate`, `unavailable`, `temporarilyInvalid`, `invalid`, `localFailure`,
and `storageFailed`.

## Child deployment

### `POST /v1/children/intents`

Build an ordinary direct-child genesis against the current parent state.

Request fields:

- `directory`: one non-empty direct-child edge label; it cannot contain `/`.
- `spec`: the child's `ChainSpec`.
- `genesisTransactions`: content-bound transactions for the absolute child
  path.
- `target`: child genesis target.
- `timestamp`: child genesis timestamp in milliseconds.

Response:

```json
{
  "directory": "Payments",
  "chainPath": ["Nexus", "Payments"],
  "genesisCID": "<cid>",
  "genesisBlock": {"...": "Block fields"},
  "parentStateCID": "<cid>"
}
```

The response is the content-addressed block itself, not an opaque serialized
bootstrap field.
Creating the intent does not mutate the parent chain. The caller separately
constructs and signs the parent transaction containing the matching
`GenesisAction`, submits it through `/v1/transactions`, and mines it. A child
process launched with `--chain-path Nexus/Payments` and `--parent
<parent-key>@<host>:<fact-port>` activates only after the hierarchy plane
delivers the authenticated genesis link.

## Errors and limits

- Malformed or invalid requests return `400 Bad Request`.
- Requests that require an active child before genesis return `409 Conflict`.
- A full transaction pool or child-intent capacity returns `429 Too Many
  Requests`.
- A temporarily unavailable transaction policy returns `503 Service
  Unavailable`.
- JSON transaction and child-intent payloads are bounded to 1 MiB.
