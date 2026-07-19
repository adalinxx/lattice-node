# Process trust model

## One process, one chain

Each process owns one absolute Nexus-inclusive chain path. External
orchestration decides which processes run; a node starts and supervises no
descendant processes.

The process topology follows direct chain relationships without collapsing
them into one runtime:

```text
Nexus process  ── authenticated facts ──▶  Nexus/Payments process
```

The parent owns only its own chain. The child owns only its own chain. Neither
process grants the other access to local consensus state or storage.

## Configured parent authority

A non-Nexus process must be started with both:

- its complete path, such as `Nexus/Payments`; and
- its immediate parent fact endpoint, such as
  `<nexus-process-key>@parent.example:4002`.

The configured process public key pins which authenticated Ivy peer may provide
parent facts. A path claim by itself is not authority. Nexus rejects a parent
configuration because it is the single root.

## Verify content independently

Parent authorization and content validity answer different questions:

- The configured key answers: "which process is allowed to speak as my
  immediate parent?"
- CIDs, proof of work, child-inclusion proofs, state continuity, and consensus
  validation answer: "are these facts valid?"

The first never bypasses the second. A correctly authenticated parent can
provide availability and lineage facts, but cannot force invalid bytes into
child state or dictate the child's fork choice.

## Separate planes

Same-chain overlay traffic and parent/child facts use separate Ivy instances.
The hierarchy plane disables relay and carries only direct relationship facts.
This prevents a public overlay peer from becoming a parent merely by claiming a
path.

Direct children authenticate and advertise their absolute path on the hierarchy
plane. The parent may request a candidate or publish a proof only for an
immediate child whose path equals `parentPath + [directory]`.

## Genesis authority

Nexus has no parent, so its one unsigned genesis is compiled and pinned by CID:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

Every child genesis is ordinary content bound to a parent state. A prepared
child intent becomes authoritative only after a separately signed parent
`GenesisAction` transaction is accepted in a carrier and the child verifies the
resulting parent genesis link.

## Operational consequence

Treat `--parent` as security configuration, not discovery. Changing it changes
who may supply parent facts. Keep process identity keys stable, restrict the
fact-plane port to intended relationships, and back up identity separately from
wipeable chain storage.
