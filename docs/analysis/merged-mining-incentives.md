# Merged-Mining Incentive & Centralization Analysis

> **Status:** design analysis (docs-only). This document describes the mechanism
> as it exists in the code and reasons about its incentive and centralization
> properties. It does **not** return a final economic launch verdict — the
> economic values enumerated in §5 are **node- and chain-level configuration**
> set by a human/operator (per-chain `ChainSpec` + reference-node defaults),
> **not** Lattice consensus invariants.
>
> **Supersedes:** the prior draft (lattice-node #139), which was written on
> the OLD nexus-anchored model ("one PoW at the nexus secures everything and
> propagates down"). That model was **withdrawn by the project owner on
> 2026-06-03**. This document is rebuilt from scratch on the CORRECTED model.

## 0. The corrected model in one paragraph

A single proof-of-work solution is validated **independently per chain** against
**each chain's own `target`**. Chain participation is **opt-in**: an
operator/miner chooses which children to subscribe to and carry; nobody is
forced to participate in any chain. The miner searches to the **easiest
(largest) target** among the chains it is mining; whatever solution it finds is
a valid block for **whatever chains it actually clears** — the easy ones always,
the harder ones (including the nexus) only when the hash qualifies. A child
*harder* than its root is **not** precluded; it simply needs its own (harder)
PoW solved. Security comes from **per-chain independent PoW validation +
voluntary subscription**, NOT from "one PoW at the nexus secures everything." A
trivially-easy child **cannot** ease the nexus or any other chain (each chain
re-validates the shared PoW solution against its own target) and is accepted
**only by its own subscribers**, so it harms no one else.

## 1. Where this lives in the code (grounding loci)

Line numbers drift; the named symbols are the stable anchors. Verified against
`main` at the time of writing.

- **Easiest-target search (miner is pointed at the easiest, not the nexus).**
  `BlockProducer` builds the parent template and then searches with the maximum
  (= easiest) target across the whole registered subtree:
  `Sources/LatticeNode/Mining/BlockProducer.swift` —
  ```
  // Merged-mining target: search with the EASIEST target across
  // the entire registered chain tree (nexus + all descendants).
  var target = max(max(previousBlock.nextTarget, ChainSpec.minimumTarget),
                   childResult.maxSubtreeTarget)
  ```
  `maxSubtreeTarget` is folded up the subtree in the same file (the
  `*SubtreeResult` builders and `if subtree.maxSubtreeTarget > maxTarget`
  reductions). The "first nonce that satisfies this max target might only pass a
  child/grandchild's PoW" case is handled by the per-level acceptance path.
- **Per-chain independent PoW validation (the real security binding).**
  `LatticeNode.isBlockPoWValid` in
  `Sources/LatticeNode/Chain/LatticeNode+BlockValidation.swift`: every accepted
  block must satisfy `validateProofOfWork` **and**, when the parent is known,
  `block.target == cachedNextTarget(for: parentCID)`. This runs per chain at
  gossip-accept (`LatticeNode+Blocks.swift` calls `isBlockPoWValid` on the
  ingest path). A peer claiming `target = .max` to clear the hash check
  trivially is rejected because the claimed target must equal that chain's own
  re-derived `nextTarget`.
- **Template `effectiveTarget` advertised to the local miner.**
  `Sources/LatticeNode/RPC/RPCServer+TemplateRoutes.swift`:
  `let effectiveTarget = childTargets.reduce(target) { max($0, max($1, ChainSpec.minimumTarget)) }`.
  This advertises the **easiest** target among the chains the node actually
  builds candidates for — advisory to the local miner only; it is not a security
  boundary. The binding still happens at gossip-accept via `isBlockPoWValid`.
- **Target floor / direction.** `ChainSpec.minimumTarget` is the **hardest**
  floor (a *smaller* target is harder work). `target` is a
  **target**, not work: **larger target == easier**. `max(...)` therefore
  selects the **easiest** target. This direction is the crux of the correction and is load-bearing throughout this analysis.
- **Mining role split.** `docs/design/mining-role-boundaries.md`: the node owns
  effective-target calculation, child-candidate embedding, and per-level
  solution validation; the worker is a pure nonce-search over a single
  easiest target it is handed.

## 2. Incentives — why mine each chain

### 2.1 Each chain pays its own miners

Each chain has its own block reward (subsidy) and its own fee pool. A miner who
subscribes to and carries chain *C* earns *C*'s coinbase reward plus *C*'s
in-block fees **when its solution clears C's target**. There is no protocol-level
cross-subsidy: the nexus does not pay child miners, and a child does not pay the
nexus. Mining chain *C* is rational exactly when the expected value of *C*'s
reward+fees, scaled by the probability that a given solution clears *C*'s target,
exceeds the marginal cost of carrying *C* (state, bandwidth, validation,
candidate construction).

Because participation is opt-in, the per-chain miner set is whoever finds *C*
worth carrying. Nothing forces a nexus miner to carry any particular child, and
nothing forces a child miner to carry the nexus.

### 2.2 The easiest-target search is nearly free to add a chain

The miner does a single nonce search at the **easiest** target among its
subscribed chains. Every hash it computes is simultaneously a candidate for
**every** chain whose target that hash clears — the harder chains are cleared by
the subset of hashes that happen to be small enough. This is the core
merged-mining efficiency property: adding a second (or hundredth) chain to your
subscription set costs you the marginal carrying cost of that chain
(state/bandwidth/validation), **not** a second independent hashing run. The
hashpower is reused; the per-chain acceptance is independent.

Consequence for incentives: the marginal hashpower cost of mining one *more*
chain is ~0, so a miner will rationally subscribe to any chain whose
reward+fees exceed its **carrying** cost, even if that chain is individually
small. This is what lets small/new child chains attract real hashpower without
having to outbid the nexus for dedicated miners.

### 2.3 Fee market = block-space auction, per chain

Each chain's block space is a scarce resource auctioned by fee rate. The node
enforces a node-local minimum fee rate (`minFeeRate`,
`Sources/LatticeNode/Config/LatticeNodeConfig.swift`; CLI default
`NodeCommand.minFeeRate = 1`) as an anti-dust / anti-spam floor, consistent with
the locked **node-min-fee** decision (per the even-epic spec decisions:
node-local minimum fee, no dust). Above that floor, transactions compete for
inclusion by fee rate within each chain's block-space budget. Critically, the
auction is **per chain**: a fee paid on chain *C* buys inclusion in *C* only and
accrues to whoever mines *C*. There is no shared fee pool that one chain's
congestion can drain from another.

### 2.4 Post-halving security budget

As each chain's subsidy halves over time, its security budget converges on its
own fee market. Under the corrected model this is a **per-chain** question, not a
system-wide one: a chain whose fees do not eventually cover the hashpower it
wants is under-secured **for itself**, and that does not propagate to its
parent or siblings (each re-validates the shared PoW against its own target).
The merged-mining efficiency (§2.2) softens this: because adding a chain to a
miner's subscription set is nearly free in hashpower, a chain with modest fees
can still attract the hashpower of large miners who are already hashing for
other chains — its security budget is effectively "fees + whatever spare
clearing-probability it gets from miners already running." Whether that is
*enough* for a given chain is a human/economic judgment (§5), because the
acceptable cost-to-attack target cannot be derived from the repo.

## 3. Centralization risk

### 3.1 Does merged mining centralize hashpower?

The headline concern with merged mining (the AuxPoW/Namecoin worry, §3.3) is
that reusing one chain's hashpower to secure another concentrates control of the
secondary chain in the hands of the primary chain's miners. Under the corrected
model this concern is **structurally weaker** for three reasons:

1. **Opt-in, independent miner sets.** Each chain's miner set is whoever
   *voluntarily* subscribes to it. There is no "you mine the parent, therefore
   you mine the child" coupling. A child's miner set is independent of the
   nexus's miner set; overlap happens only to the extent that the same operators
   *choose* to carry both.
2. **Independent per-chain validation.** A block is accepted on chain *C* iff it
   clears *C*'s own target (`isBlockPoWValid`: `block.target ==
   cachedNextTarget(for: parentCID)`). No external chain's hashpower or
   difficulty can lower *C*'s bar or admit a block *C* would otherwise reject.
3. **Easiest-target search, not nexus-anchored search.** Because the miner
   searches the easiest target and each solution is independently graded per
   chain, a child is *not* gated on clearing the nexus. Small chains can be
   secured by miners who never clear (or never carry) the nexus at all.

So: merged mining **enables** hashpower *reuse* (good for small-chain security),
but it does **not** *force* hashpower *concentration*. Concentration on any
given chain is bounded by that chain's own miner set, which is set by voluntary
subscription, not by the topology.

### 3.2 Can a dominant nexus miner coerce children? — No.

Suppose one entity controls a majority of nexus hashpower. The OLD nexus-anchored
model would have made this entity a chokepoint for every child ("one PoW at the
nexus secures everything"). Under the corrected model it cannot coerce a child it
does not itself mine:

- **It cannot ease a child.** A child only accepts blocks that clear the child's
  own target, re-validated by the child's own subscribers. A nexus miner
  advertising or producing a trivially-easy child target changes nothing for
  anyone who has not subscribed to that child; non-subscribers never see it, and
  subscribers re-derive the child's canonical target independently. (This is
  exactly the trust-boundary kernel: a node must not republish
  an *advertised* target taken verbatim from an untrusted remote child — but
  that is "don't trust unverified remote input," not "the nexus is the binding
  search target.")
- **It cannot block a child it does not mine.** A child the dominant miner does
  not carry is mined and validated entirely by that child's own subscribers; the
  dominant nexus miner has no inclusion control there.
- **Where it *does* have inclusion control** is only over a child it *itself*
  mines, and only to the same degree any majority miner has over any chain it
  mines — which is the generic 51% problem of *that* chain, not a merged-mining
  artifact. The remedy is the same as for any chain: more independent hashpower
  voluntarily subscribing to that child.

The distinction that matters: shared-root PoW gives a parent block producer the
ability to **embed** a child candidate in a solution it found, but **not** the
ability to **force** that child to accept anything the child's own validators
would reject, nor to **ease** the child's target. Inclusion control over a child
is bounded by being a subscriber/miner of that specific child.

### 3.3 Contrast with AuxPoW / Namecoin

AuxPoW (Namecoin's merged mining with Bitcoin) is the canonical cautionary tale:
because almost all Namecoin hashpower came from Bitcoin pools merge-mining it as
a near-free add-on, Namecoin's security and its block production became highly
concentrated in a few Bitcoin pools, and Namecoin hashpower tracked Bitcoin's
miner distribution rather than any independent Namecoin constituency.

How this model differs:

- **No designated parent every child must attach to.** AuxPoW has a fixed
  "parent" (Bitcoin) whose miners are the only realistic source of work. Here
  any chain can be a root for the chains beneath it, participation is opt-in per
  edge, and a child is not required to be secured by the nexus's miners — it is
  secured by whoever subscribes to it.
- **Independent per-chain target binding is enforced, not advisory.** A child's
  acceptance is gated on its *own* re-derived target at every validating node;
  the parent cannot relax it. In AuxPoW the auxiliary chain's difficulty is its
  own, but the *miner population* is structurally the parent's; here the miner
  population is whoever opts in, which can be — and is intended to be — broader
  than any single parent's pool set.
- **The "easy child = grinding/DoS hole" premise is void.** In the old
  nexus-anchored framing, an easy child was a worry because it might "ease the
  nexus." Here it cannot: an easy child is accepted only by its own subscribers
  and cannot lower any other chain's bar. So there is no incentive-compatible way
  for an attacker to spin up a junk child to weaken the system.

The honest residual: merged mining's *efficiency* (near-free hashpower reuse)
still means that, in practice, large existing miners are the cheapest marginal
suppliers of hashpower to any new child, so **realized** decentralization of a
given child depends on whether independent operators choose to carry it. The
model removes the *structural* coercion of AuxPoW but does not by itself
*guarantee* a broad miner set for any particular chain — that is a function of
that chain's economics and the human-gated thresholds in §5.

## 4. What this analysis does and does not establish

**Established (code-derivable / mechanism-level):**

- The miner is pointed at the easiest subscribed-chain target, and each solution
  is independently graded per chain (`BlockProducer` easiest-target search +
  `isBlockPoWValid` per-chain binding).
- An easy/junk child cannot ease the nexus or any other chain and is accepted
  only by its own subscribers.
- A dominant nexus miner cannot ease or coerce a child it does not itself mine;
  inclusion control over a child is bounded by being a subscriber/miner of that
  child.
- Each chain pays its own miners (reward + per-chain fee auction above the
  node-local min-fee floor); adding a chain to a miner's subscription set costs
  marginal carrying cost, not a second hashing run.

**NOT established here (human-gated economic judgment — §5):**

- Whether any *particular* chain's reward+fees draw *enough* independent
  hashpower to meet a target cost-to-attack.
- Whether the realized (as opposed to structural) miner distribution of a given
  child is acceptably decentralized.
- The final launch go/no-go economic soundness verdict.

## 5. Node- and chain-level configuration decisions (not consensus invariants)

Lattice consensus is **economically neutral**: the protocol rule is heaviest-chain
by accumulated work with per-chain independent PoW validation, and it dictates no
economics. Every value below is therefore a **node- or chain-deployment
configuration** decision — set per chain in its `ChainSpec`, or as a reference-node
default / operator policy — **not** a Lattice consensus invariant and **not** a
protocol launch-gate. The mechanism is sound and code-derivable; these are the
deployment knobs a human/operator sets per chain. They supersede and re-frame the
three values in the AC, which were stated on the old nexus-anchored model.

1. **Target cost-to-attack, per chain.** What adversary hashrate / dollar cost
   must each chain (nexus and each child tier) be able to withstand? Under the
   corrected model this is a **per-chain** parameter, because each chain is
   secured by its own opt-in miner set, not by the nexus. There is no single
   system-wide number.

2. **Minimum-viable security for a launched child — acceptance policy.** Does the
   project accept launching a child whose security rests on the spare
   clearing-probability of miners already hashing for other chains (i.e.
   merged-mining reuse), or does a child require a demonstrated *independent*
   constituency / a reward split / subsidy before it may launch? This is the
   corrected analogue of the old "child security = root security without
   per-child incentive?" question — but now framed as "is opt-in reuse-driven
   security sufficient, or is an independent miner set required per launched
   child?"

3. **Acceptable centralization threshold, per chain.** What concentration of a
   single chain's hashpower (or of the operators who carry it) is tolerable
   before that chain is considered unsafe? Because miner sets are independent and
   opt-in, this must be evaluated **per chain** (especially per child), not once
   for the whole tree. Note the structural coercion of AuxPoW is removed, but
   realized concentration is still an empirical, per-chain question.

4. **Subsidy/fee schedule and the post-halving floor, per chain.** What block
   reward schedule and halving curve does each chain ship with, and what fee
   market is assumed to backfill the security budget post-halving? The node-local
   min-fee floor (locked: node-local minimum fee, no dust) sets an anti-spam
   floor but not a security-budget target; the latter is a human economic
   choice.

5. **Default subscription / carrying policy for node operators.** Which children
   should the reference node carry by default, and what is the operator guidance
   for when to subscribe to a child? Because security and decentralization of a
   child are downstream of how many independent operators opt in, the default
   posture is an economic/ops lever, not just a config default.

Values (1)–(5) are configured per chain (in `ChainSpec`) or as reference-node /
operator defaults — independently, chain by chain — **not** decided once for the
protocol. This artifact describes the mechanism, the AuxPoW/Namecoin contrast, and
the incentive/centralization properties; the economic values themselves are
deployment configuration set per chain by a human/operator, and are intentionally
**not** Lattice consensus invariants.

## 6. Cross-references

- **Corrected miner-target polarity** — point the miner at the EASIEST
  subscribed-chain target, not the nexus; authoritative statement of the
  corrected model.
- **Trust-boundary kernel** — "don't republish an advertised target taken
  verbatim from an untrusted remote child."
- **Locked Model-A / node-min-fee decisions** — node-local minimum fee, no dust
  (even-epic spec decisions); the per-chain fee-auction floor referenced in
  §2.3 / §5.4.
- **[docs/design/mining-role-boundaries.md](../design/mining-role-boundaries.md)**
  — the node/coordinator/worker contract (node owns effective-target calc,
  child-candidate embedding, and per-level solution validation; worker is a pure
  nonce search).
- **[docs/design/consensus-fork-choice.md](../design/consensus-fork-choice.md)**
  — node-side realization of the consensus model (per-chain acceptance
  chokepoint, inherited-weight wiring).
