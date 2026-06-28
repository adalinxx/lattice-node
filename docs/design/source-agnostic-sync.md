# Source-Agnostic Header Sync

## Context

Headers-first sync fetches a child chain's blocks (and their `ChildBlockProof`s)
from peers, then verifies and adopts them. This document covers **which peer the
node asks** and **what happens when a peer misbehaves** — the realization, for the
sync/replace path, of the proof-availability principle in
[Consensus & Fork Choice](consensus-fork-choice.md): *the source does not make the
data authoritative.*

The per-header content-addressing check (a CID names bytes; received bytes must
re-hash to the requested CID) is specified in
[Bulk Header Content-Addressing](bulk-header-content-addressing.md). This document
builds on it: because every block is locally verified, the **source is
irrelevant**, so sync must not couple liveness to any one peer.

## Principle: peers are interchangeable byte-providers

Authority comes from content-addressing, proof-of-work, and the path-bound
`ChildBlockProof` — never from peer identity. Two consequences:

- **No single "source peer."** A designated source peer that *must* serve, and a
  sync that fails closed if it doesn't, recreates the trusted-master coupling the
  proof-availability model exists to remove. Any Tally-allowed connected peer is an
  equally valid byte-provider.
- **Verify, then it doesn't matter who served it.** A spliced, wrong-fork, or
  forged batch fails CID re-derivation, PoW, or proof-binding and is rejected
  locally. The node never adopts unverified bytes regardless of source.

## Design

**Candidate set.** Child sync builds a bounded, shuffled set of Tally-allowed
connected peers (`maxSyncCandidatePeers`), Tally-filtered *before* the bound so a
few disallowed peers in the shuffle can't shrink the window. A gossip "source hint"
(the peer that announced the heaviest tip) is tried first for locality only — it
carries no authority.

**Rotate past a bad peer — never abort.** For each batch the node walks the
candidate set:

- An **empty** response (peer is behind, pruned the range, or flaky) → rotate to
  the next candidate.
- A **non-empty but invalid** batch (a *lying* peer) → roll back any partial
  accept, **penalize the peer**, and rotate to the next candidate.

The walk **fails closed only when no candidate produced an accepted batch** — never
because one peer was absent or malicious. A single peer, silent or lying, must
never wedge sync. (Earlier code aborted the whole sync on the first invalid batch;
one Tally-allowed liar could then stall every retry — the documented anti-pattern.)

**Rollback must be complete.** A rejected batch's partial state is fully rolled
back before rotating — accumulated headers, cumulative work, retained proofs, *and*
the derived tip height. A liar's (small) tip height must not bleed into an honest
peer's accept; the progress delta is unsigned and would otherwise underflow-trap.
Blocks a liar already stored are content-addressed and harmless: an honest batch
for the same cursor re-derives identical CIDs.

## Penalize the peer, not the content

A failed or invalid download is the **peer's** fault, not the tip's:

- The lying peer is penalized in reputation (`recordInvalidHeaderBatch` →
  `Tally.recordFailure`), so it is deprioritized — and filtered out — on subsequent
  attempts.
- The (honest) tip CID is **not** blacklisted. Blacklisting content because a peer
  lied about it locks honest peers out of serving it too. When a first batch's
  candidates all fail and at least one lied, sync signals
  `allCandidatesServedInvalid` so the caller skips the tip blacklist and a
  reshuffled retry re-reaches the same tip through other peers. A genuinely
  unreachable tip (every candidate empty, none lying) is still treated as such.

## Invariants (load-bearing)

1. **Every adopted header is locally verified** — CID re-derivation + PoW +
   path-bound `ChildBlockProof` — before it affects state or fork choice. Source
   agnosticism changes *who* we ask, never *what* we accept.
2. **No single peer can wedge sync.** Empty and invalid batches both rotate; the
   walk ends only on all-candidates-failed.
3. **Penalize peers, never content.** Reputation deprioritizes a faulty peer; an
   honest tip hash is never blacklisted on a peer's failure.
4. **Fail closed only when no peer serves a valid proof.** With no candidate able
   to provide a verifiable batch, sync stops rather than adopt unanchored blocks.

## State of the art

This is the established design for trustless multi-peer sync, corroborated across
PoW chains, merge-mined chains, and content-addressed storage:

- **Bitcoin** headers-first IBD downloads from multiple peers in parallel and no
  longer depends on selecting one good sync peer (Bitcoin Core PR #2964); a
  stalling sync peer is disconnected and sync continues, and invalid data raises a
  per-*peer* misbehavior score — never a per-block ban.
- **go-ethereum** snap-sync responses are self-verifying (Merkle proofs); an
  invalid response drops the peer and continues.
- **IPFS/Bitswap** fetches content by CID from a set of peers simultaneously —
  content-addressed, source-agnostic, verify-not-trust.
- **AuxPoW** (Namecoin, Dogecoin, RSK) proofs are self-contained: the parent chain
  need not be aware and parent/auxiliary propagation are independent, so any peer
  can serve the self-verifying bytes of a block anchored to a
  not-necessarily-canonical parent block.
- The **data-availability-vs-validity** separation (fraud proofs; Celestia/Avail
  data-availability sampling) draws the same boundary: storage/transport make
  content available; local verification decides whether it can affect state.

## References

- [Consensus & Fork Choice](consensus-fork-choice.md) — the proof-availability
  principle this realizes for the sync path.
- [Bulk Header Content-Addressing](bulk-header-content-addressing.md) — the
  per-header CID-validation invariant sync builds on.
- [Same-chain peer bootstrap](same-chain-peer-bootstrap.md) — how the candidate
  peers for a child chain are discovered (`getChildPeers`).
- [Content-addressed ingress](content-addressed-ingress.md) — the general invariant.
