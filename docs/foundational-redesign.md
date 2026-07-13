# Foundational redesign integration

This branch is the top-level integration gate for the coordinated architecture series across Lattice, cashew, VolumeBroker, Tally, and Ivy.

## Meaning boundary

The node must preserve these distinctions from Lattice through every transport:

- `canonicalized`: valid and selected by this chain;
- `acceptedSide`: valid and retained, but not canonical;
- `duplicate`: already known valid evidence;
- `unavailable`: required complete Volumes/evidence are not currently obtainable;
- `invalid`: complete evidence violated protocol rules;
- `storageFailed`: local durability failed.

Only `invalid` may become remote invalid-evidence attribution. Availability and local storage failure must not penalize a peer. Only `canonicalized` may publish a new canonical tip.

`NodeConsensusDecision` locks this mapping down with unit tests while the larger block-processing path migrates to Lattice's chain-local admission API.

## Integration gate

`Package.swift` temporarily pins all coordinated branches so this PR's build and test workflows validate the whole stack together. Branch pins must be replaced with released versions before merge.

## Larger migration

This PR deliberately establishes the semantic and dependency boundary first. Follow-up implementation work should:

1. route gossip, sync, mining, extraction, rescue, and restart through the chain-local Lattice API;
2. carry child validation packages through durable-before-commit;
3. use Ivy pinned topology for parent-evidence sessions;
4. emit typed Tally observations at attribution points;
5. preserve complete-Volume storage throughout.
