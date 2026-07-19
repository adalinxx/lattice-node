# Reproducible Builds

Lattice Linux release binaries are expected to be byte-reproducible from the
tagged source checkout and pinned `Package.resolved`.

To verify the node, coordinator, and worker binaries, run the same Docker-backed check as CI:

```bash
git checkout <release-tag>
scripts/reproducible-build.sh
```

The script archives committed `HEAD`, builds `lattice-node`,
`lattice-mining-coordinator`, and `lattice-miner` in two clean
`swift:6.1-jammy` containers at the same canonical source path, then compares
SHA-256 hashes for all three release artifacts. It fixes locale, timezone,
`SOURCE_DATE_EPOCH`, compiler prefix maps, and linker build-ID suppression. It
also strips debug-only metadata from the release copies before hashing. Swift
6.1 emits a `.swift_modhash` compiler metadata section whose bytes can vary
between clean builds even when loadable code/data are identical; the check
removes that non-runtime section before hashing. A mismatch is a
release-blocking failure.

Native macOS/Xcode builds are not the release artifact and are not part of this
gate. Docker is required because Swift 6.1 embeds runtime source paths that are
not fully rewritten by compiler prefix-map flags; building both clean runs at
the same in-container path keeps those paths deterministic.

Set `BUILD_ROOT=/path/to/output` to choose where the two clean build outputs are
written. On macOS/Docker Desktop, temporary worktrees outside `/Users` default to
`~/Library/Caches/lattice-node/reproducible-builds/...` so Docker can copy the
hash files and normalized artifacts back to the host.
