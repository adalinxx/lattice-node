# Coordinated foundational redesign series

The six draft PRs in this series are intended to be reviewed together:

1. **Lattice** — architectural source of truth and chain-local admission semantics.
2. **cashew** — atomic successful/aborted Volume traversal lifecycle.
3. **VolumeBroker** — complete-Volume and CID-integrity enforcement.
4. **Tally** — typed remote-versus-local peer observations.
5. **Ivy** — explicit public-overlay versus pinned-peer topology.
6. **lattice-node** — top-level dependency integration and node decision mapping.

The node branch intentionally points at the five dependency branches. It is the cross-repository build/test gate, not the final versioning strategy. Branch requirements must be replaced with released package versions before merge.
