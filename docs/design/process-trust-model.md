# Process Trust Model — the spawn tree

This document states the **process-level** organizing principle: how the chain
tree is realized as a tree of OS processes, and what one process is allowed to
trust about another. It is the trust-and-authority companion to
[fractal-structure.md](fractal-structure.md) (the securing relationship) and the
node-mechanics companion to [Per-Process Topology](../architecture.md#per-process-topology).

## Two trees, one shape

In production the chain tree spans operating-system processes: Nexus runs in the
root process; each child chain runs as its own `LatticeNode` started with
`--genesis-hex --chain-directory --subscribe-p2p`. **The process tree mirrors the chain tree** — there is one
process per chain, and a process's parent in the spawn tree is the process for
its chain's parent. The self-similarity of the chain tree
([fractal-structure.md](fractal-structure.md)) therefore repeats at the process
layer: every parent→child edge is the same kind of edge, all the way down.

```
Nexus process ──spawns──▶ Nexus/Payments process ──spawns──▶ Nexus/Payments/Rollups process
   (root)                      (child)                              (grandchild)
```

## Single root: Nexus

There is exactly **one** root in the spawn tree, the Nexus process. A chain that
is conceptually a "root chain" of its own subtree is still, in the realized
topology, a **child** spawned under some parent — only Nexus has no parent
process. This is the deliberate retirement of the *federated skeleton*: we do not
support non-Nexus root chains that bootstrap their own independent securing
frame. Every chain enters the tree by being spawned beneath Nexus (directly or
transitively), and inherits its place in the single global securing relationship
from that lineage. (The *addressing* relativity of
[chain-addressing.md](chain-addressing.md) is unchanged — a process still knows
only "my parent" and "my child edges"; single-root constrains the *realized*
topology, not the relative naming model.)

## The spawn relationship

A child process exists because a parent process **spawned** it. Concretely
([architecture.md](../architecture.md#per-process-topology)):

1. **Deploy** — `POST /api/chain/deploy` on the parent builds the child genesis
   and returns `genesisHex` + the parent P2P endpoint.
2. **Spawn** — an orchestrator launches the child with that genesis and a
   `--subscribe-p2p` link back to the parent.
3. **Extract** — the child opens a dedicated link to the parent, and accepts
   `parent.children[directory]` blocks via a root-anchored `ChildBlockProof`
   validated against the parent's proof-of-work root hash.
4. **Register** — the child calls `POST /api/chain/register-rpc`, so `GET
   /api/chain/map` can resolve any chain path to a direct RPC URL.

The spawn is what makes a chain a chain in this tree: its genesis, its directory
edge label, and its securing parent are all fixed at spawn time by the parent.

## The chain of trust — what "trust" means here

A child process **trusts its parent because the parent spawned it.** The parent
is the authority that minted the child's genesis and is the source of the
proof-carrying ancestor blocks the child needs for consensus. That trust is
**lineage authorization**, established by a verifiable spawn chain from Nexus
down to the child.

It is critical to be precise about scope, because this model sits next to the
opposite principle for *data*:

- **Trusted (authorization / scope):** *which* process is the legitimate parent
  for a given chain directory, and therefore which process may act as that
  chain's consensus provider and what authority scope it carries. This is
  attested by the spawn chain — a child does not re-derive from scratch whether
  its parent is "allowed to be" its parent; the spawn lineage says so.
- **Never trusted (availability / content):** the *bytes* any peer serves. Block
  content, parent blocks, and volume data are always cryptographically verified
  on use — `ChildBlockProof` against the parent PoW root, CID-matching on every
  ingressed object, JIT completeness checks during resolution. As
  [protocol.md](../protocol.md) puts it, the source that serves the bytes is not
  trusted; it only provides availability. The availability/serving model is in
  [block-content-storage.md](block-content-storage.md) and
  [content-addressed-ingress.md](content-addressed-ingress.md).

So the spawn chain of trust **composes with**, and never replaces, content
verification. It answers *"is this the right parent, and what is it authorized to
speak for?"* — not *"can I skip checking these bytes?"* The answer to the second
question is always no.

## Spawn certificates

The lineage is made verifiable by **spawn certificates** (an Ivy primitive). A
parent issues a signed certificate attesting that it spawned a given child
directory under a given genesis; a chain of such certificates from Nexus to a
target chain is the cryptographic witness of that chain's place in the tree.

- `SpawnCertificate` — one parent→child attestation.
- `SpawnCertificateChain.verify` — checks an unbroken, correctly-signed lineage
  from a trusted root (Nexus) down to the leaf identity, with canonicalized
  identity keys so issuer/child keys compare unambiguously across the chain. The
  `leaf` **must** be the connection's possession-proven public key — never a key
  lifted out of the presented chain — or the proof attests nothing about the peer
  you are actually talking to.
- `verifiedScope` — the chain-path scope the verified lineage confers on the
  leaf (which chain path it legitimately speaks for), used to **bound** what a
  process is allowed to assert or serve as that chain. Callers must enforce the
  returned scope, not merely check that `verify` succeeded.

A certificate chain lets any party confirm a chain's lineage and scope **without
trusting the messenger** — it is verify-not-trust applied to *authority* the same
way `ChildBlockProof` applies it to *block content*.

## Why it matters for consensus

Consensus is Hierarchical GHOST over `trueCumWork`
([consensus-fork-choice.md](consensus-fork-choice.md)): a block's weight is its
own-chain forward subtree weight plus the inherited securing weight of its
ancestors. To evaluate that, **each chain must keep a complete GHOST view from
the Nexus root down to itself** — it subscribes to every valid ancestor block as
well as its own. The spawn tree is exactly the structure that delivers that view:
inherited weight flows *down* the spawn edges (parent → child), and the trusted
parent link is how a child obtains its ancestors' proof-carrying blocks.

The trust boundary is therefore the spawn tree: **inside** the lineage a child
relies on its parent as the authorized consensus provider for the ancestor view;
**outside** it (an unrelated chain, an unverified peer), everything is federated —
full verification, no inherited authority.

## Status

Wired today: the per-process topology (Nexus root + `--subscribe-p2p`
children), `ChildBlockProof`-gated extraction, the single-`trueCumWork` fork
choice, and the inherited-weight provider
([consensus-fork-choice.md](consensus-fork-choice.md)). The spawn certificate
primitive exists in Ivy but is not yet load-bearing in the node, so the legacy
in-process child registration remains as a compatibility/test harness
([architecture.md](../architecture.md#per-process-topology)).

## References

- [fractal-structure.md](fractal-structure.md) — the securing relationship this
  realizes at the process layer.
- [architecture.md](../architecture.md#per-process-topology) — the concrete
  deploy → spawn → extract → register mechanics.
- [consensus-fork-choice.md](consensus-fork-choice.md) — the `trueCumWork` model
  the spawn tree feeds.
- [chain-addressing.md](chain-addressing.md) — relative, route-based identity,
  unchanged by single-root.
