// Adversarial / Module 4: stale-tip probe / recovery.
//
// Module 4 detects a stalled local tip (no advance for N refresh intervals while
// no connected peer advertises anything heavier) and opens 1-2 extra outbound
// "feeler" probes to diverse, persisted candidates, exposing the metrics
// eclipse_stale_detected / eclipse_stale_probes_opened / eclipse_better_tip_found.
//
// COVERAGE NOTE — this behavior is covered by a UNIT test, not this smoke run:
//   Tests/LatticeNodeTests/StaleTipDetectionTests.swift exercises the pure
//   decision `LatticeNode.tipLooksStale(...)` (not-stale-before-threshold,
//   stale-when-stuck-and-no-heavier-peer, not-stale-when-a-peer-has-a-heavier-tip).
//
// A LIVE loopback eclipse-recovery scenario is intentionally NOT implemented here:
//   - The detector cadence is the peer-refresh interval (60s) × the stale
//     threshold (3 intervals) ≈ 180s, which exceeds the smoke per-scenario window
//     and would make a real run slow and flaky.
//   - The "recover by sampling a DIVERSE netgroup" half cannot be reproduced on
//     127.0.0.1, where every peer shares one netgroup (the same loopback
//     limitation the low-work scenario documents).
// Driving it live would require a test-only fast cadence knob in Sources/, which
// is out of scope for this delta; the unit test is the authoritative coverage.

// Exit 77 = self-skip: the harness reports this as SKIP, NOT a green PASS (which
// is what exit 0 did — false confidence). A live run needs a fast-cadence test
// knob (stale threshold / refresh interval) and a non-loopback multi-netgroup
// topology; see the header. Detection is unit-tested (StaleTipDetectionTests);
// a real recovery scenario is a tracked follow-up.
console.log('SKIP: needs fast-cadence knob + non-loopback netgroups; detection covered by StaleTipDetectionTests')
process.exit(77)
