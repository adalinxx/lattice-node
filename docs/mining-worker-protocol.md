# Mining Worker Protocol

A **mining worker** searches one immutable nonce range for a proof-of-work
solution and reports the result. The node never mines; a **coordinator**
(`lattice-mining-coordinator`) fetches block templates, splits the nonce space,
and drives one or more workers via `--worker-executable`. This document is the
normative contract a worker must implement — in any language. The reference
worker is `lattice-miner` (CPU, Swift); `lattice-miner-gpu` (Metal/CUDA)
implements the same contract.

A conformant worker needs only **SHA-256** and this document. It does **not**
need to parse Lattice blocks or link any Lattice code.

## Proof of work

A nonce solves the work iff:

```
SHA256( prefix || nonce_be64 )  ≤  target
```

- `prefix` — the **nonce-independent PoW preimage prefix**, supplied as
  `--prefix-hex`. The coordinator computes it once per template
  (`Block.makeProofOfWorkPreimagePrefix`); the worker treats it as opaque bytes.
- `nonce_be64` — the 64-bit nonce encoded as **8 bytes, big-endian**. Fixed
  width: the preimage length is constant across nonces, so the SHA-256 padding
  and block count never change (clean midstate reuse, no GPU divergence).
- `SHA256(...)` — a single SHA-256 (not double). The 32-byte digest is
  interpreted as a **256-bit big-endian integer**.
- `target` — a 256-bit value, supplied as `--target` (big-endian hex). Lower
  target ⇒ harder. The comparison is unsigned `digest ≤ target`.

Optimization (non-normative): hash `prefix` once into a SHA-256 **midstate**,
then per nonce resume from the midstate over the final block(s) containing
`nonce_be64` + padding. This is what makes the search GPU-efficient.

## CLI contract

The coordinator invokes the worker executable with:

| Flag | Meaning |
|---|---|
| `--work-id <string>` | Opaque work identifier; echo it back in the result. |
| `--prefix-hex <hex>` | The PoW preimage prefix (preferred). |
| `--block-hex <hex>` | Serialized nonce-0 block (legacy fallback; requires Lattice to derive the prefix). A worker may ignore this if `--prefix-hex` is present. |
| `--target <hex>` | 256-bit PoW target, big-endian hex. |
| `--start-nonce <u64>` | First nonce in this assignment (decimal). |
| `--count <u64>` | Number of nonces to search: `[start, start+count)`. |

The coordinator always sends both `--prefix-hex` and `--block-hex`; a
non-Lattice worker uses only `--prefix-hex`.

## Result

The worker prints **exactly one** JSON object to stdout (then exits 0):

```json
{ "workId": "...", "status": "found", "nonce": 12345,
  "hash": "00ff…", "rangeStart": 0, "rangeCount": 1000000 }
```

- `status` — `"found"` if a nonce in the range satisfies the PoW, else
  `"exhausted"`.
- `nonce` — the winning nonce (`null` when exhausted). Return the **first** hit.
- `hash` — the winning digest as 64-char big-endian hex (`null` when exhausted).
- `rangeStart` / `rangeCount` — echo of the assignment.

Non-zero exit or unparseable stdout is treated as worker failure.

## Conformance checklist

1. Reproduce a known `(prefix, nonce) → hash` vector bit-for-bit.
2. With an easy `target`, find the same first nonce a brute-force scan finds.
3. Driven by the coordinator against a node, produce a block the node accepts.
