# Release Verification

Lattice Node release archives are published with three operator-verifiable artifacts:

- `*.tar.gz`: release binaries for `LatticeNode`, `LatticeMiningCoordinatorTool`, and `LatticeMiner`.
- `*.tar.gz.sha256`: SHA-256 checksum for the archive.
- `*.spdx.json`: SBOM generated from `Package.resolved`.
- `*.artifacts.json`: manifest binding the archive path/name, checksum path, digest, and SBOM path produced by CI.

For tagged releases, CI also publishes signed GitHub artifact attestations for the archive provenance and SBOM. Operators can verify a release with:

```sh
shasum -a 256 -c lattice-node-<version>-<platform>.tar.gz.sha256
gh attestation verify lattice-node-<version>-<platform>.tar.gz --repo adalinxx/lattice-node
gh attestation verify lattice-node-<version>-<platform>.tar.gz --repo adalinxx/lattice-node --predicate-type https://spdx.dev/Document/v2.3
```

The provenance attestation binds the exact archive path emitted by packaging to the GitHub workflow identity for `adalinxx/lattice-node`. The SBOM attestation binds that same archive path to the SPDX dependency inventory generated during the same workflow run. The checksum catches transfer corruption; the manifest records the archive name, checksum subject name, archive digest, and SBOM path so release verification does not depend on adjacent filename conventions.
