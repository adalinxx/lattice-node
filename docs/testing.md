# Testing

Run the complete node, daemon, coordinator, and worker suite with:

```sh
swift test
```

The architecture tests are grouped by boundary:

- `NodeStoreTests`: atomic admission, crash recovery, and retained hierarchy evidence.
- `ChainProcessTests`: one-path admission, restart, child bootstrap, and proof composition.
- `NetworkTrustTests`: overlay/fact-plane separation, bounded wire input, and hierarchy-only recovery.
- `ChainServiceTests`: transaction, child-deploy, template, and work-submission behavior.
- `DaemonHTTPTests`: real loopback HTTP route contracts.
- `LatticeMinerCoreTests` and `LatticeMiningCoordinatorTests`: nonce search, work allocation, staleness, subprocess cancellation, and current RPC payloads.

Consensus validation and signature compatibility live in the Lattice dependency and are tested in that repository. Storage and transport primitives are likewise tested in VolumeBroker, cashew, Ivy, and Tally. A coordinated release is green only when those dependency suites and this suite all pass from the exact pinned revisions.
