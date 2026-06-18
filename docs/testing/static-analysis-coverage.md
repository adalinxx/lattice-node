# Static Analysis Coverage Map

This map is a CI-gated contract for the analysis coverage plan. It records which gates are active in this PR, which gates are planned but not wired in this PR, and the remediated files that must stay represented. `scripts/verify-analysis-coverage.sh` fails if the required remediated-file coverage drops below four entries or if planned rows are not clearly marked as not wired.

| Gate | CI status | Defect class | Required remediated file |
| --- | --- | --- | --- |
| SwiftLint | Active in CI | Unsafe `.load(as: UInt/Int*.self)` typed integer loads in network wire formats; this rule is intentionally scoped to the regressed spelling and does not claim to cover every unsafe pointer-binding form. | Sources/LatticeNode/Network/ChainNetwork.swift |
| Clang Static Analyzer | Active smoke in CI | C analyzer availability and diagnostic plumbing; the lane fails on a seeded null-deref diagnostic. This repository currently has no non-empty first-party C implementation to analyze. | Sources/CSQLite/csqlite.c |
| ASan | Not wired in this PR | Out-of-bounds host memory reads/writes and poisoned-buffer regressions | Sources/LatticeNode/Network/ChainNetwork.swift |
| UBSan | Not wired in this PR | Misaligned typed loads and integer undefined behavior | Sources/LatticeNode/Chain/LatticeNode+Persistence.swift |
| TSan | Not wired in this PR | Actor isolation escapes, nonisolated storage reads, and CAS/storage data races | Sources/LatticeNode/Storage/StateStore.swift |
| Swift warnings-as-errors | Not wired in this PR | Deprecated APIs, unused values, and warning-only regressions that hide security-relevant build drift | Sources/LatticeNodeAuth/RPCAuth.swift |

The coverage threshold intentionally names the load-bearing remediated areas: storage state reads, persistence, ChainNetwork decoders, and RPC auth. A future change may expand the threshold, but lowering it should be treated as weakening acceptance unless the change is accompanied by a validated bug in the map.
