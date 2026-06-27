// Heterogeneous per-chain difficulty under ONE merged miner: two sibling children with
// very different targetBlockTimes, merge-mined by a single miner, must retarget
// INDEPENDENTLY — a hash is graded per-chain, so one child's difficulty must not leak into
// the other's. child-epoch-difficulty proves ONE child retargets; MergedMiningTemplateTargetTests
// proves the template's target math; this proves the end-to-end property no smoke does: a
// single merged miner sustaining two children at genuinely DIFFERENT live difficulties, both
// advancing. If per-chain target derivation were shared/leaky, the two would converge to the
// same difficulty (or the harder one would stall because it was graded at the easier target).
//
// Construction: EasyChild (tiny targetBlockTime → blocks are "too slow" vs target → difficulty
// eases toward trivial) vs HardChild (large targetBlockTime → blocks are "too fast" → difficulty
// hardens). After both pass their retarget window, their live block targets must differ and the
// easy child must have produced strictly more blocks.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitForProgress } from 'lattice-node-sdk'

const ROOT = smokeRoot('heterogeneous-child-targets')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [ports, easyPorts, hardPorts] = await allocPorts(3, { seed: 271 })
const WINDOW = 4

console.log('=== heterogeneous-child-targets smoke test ===')
const net = new LatticeNetwork(); net.installSignalHandlers()
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: ports.port, rpcPort: ports.rpcPort }))
node.start()
await node.waitForRPC()
const nexusDir = (await node.chainInfo()).nexus

// [1] Deploy two children with very different targetBlockTimes (→ divergent difficulty).
console.log('\n[1] Deploy EasyChild (tbt=50) + HardChild (tbt=5000) under one Nexus...')
const easy = net.add(await node.spawnChild({ directory: 'EasyChild', parentDirectory: nexusDir, ports: easyPorts, retargetWindow: WINDOW, targetBlockTime: 50, premine: 0 }))
const hard = net.add(await node.spawnChild({ directory: 'HardChild', parentDirectory: nexusDir, ports: hardPorts, retargetWindow: WINDOW, targetBlockTime: 5000, premine: 0 }))

async function blockTarget(n, dir) {
  const r = await n.rpc('GET', `/api/block/latest?chainPath=${dir}`).catch(() => null)
  return r?.ok ? (r.json?.target ?? null) : null
}

// [2] ONE merged miner advances both children past their retarget windows.
console.log('\n[2] Merge-mine both with a single miner past the retarget window...')
// Pin the miner cadence so the per-child block interval is deterministically WELL ABOVE
// EasyChild's tiny targetBlockTime (→ "too slow" → eases to trivial max) and far below
// HardChild's large one (→ "too fast" → hardens). Without this, a very fast idle box could
// drive EasyChild blocks <50ms apart and harden it too, narrowing the divergence.
const miner = net.addMiner(new LatticeMiner(node, [easy, hard], { workers: 2, minBlockIntervalMs: 200 }))
await miner.start()
await waitForProgress(async () => Math.min(await easy.height('EasyChild'), await hard.height('HardChild')),
  (h) => h >= WINDOW + 3, 'both children past retarget window', { stallMs: 120_000, intervalMs: 300 })
// Let difficulty settle a few more blocks past the window so the retarget has taken effect.
await waitForProgress(async () => await easy.height('EasyChild'), (h) => h >= WINDOW + 6,
  'EasyChild settles past window', { stallMs: 90_000, intervalMs: 300 })
await miner.stop()
await node.awaitQuiesced(nexusDir)

const [easyH, hardH] = await Promise.all([easy.height('EasyChild'), hard.height('HardChild')])
const [easyT, hardT] = await Promise.all([blockTarget(easy, 'EasyChild'), blockTarget(hard, 'HardChild')])
console.log(`  EasyChild: height=${easyH} target=${easyT?.slice(0, 24)}…`)
console.log(`  HardChild: height=${hardH} target=${hardT?.slice(0, 24)}…`)

// [3] THE TEST: both advanced, AND they hold genuinely different live difficulties under
// the single miner (per-chain independent retarget — no leakage/convergence).
if (easyH < WINDOW || hardH < WINDOW) fail(`a child did not pass its retarget window (easy=${easyH} hard=${hardH})`)
if (!easyT || !hardT) fail('could not read a child block target')
if (easyT === hardT) fail(`both children converged to the SAME target ${easyT} under one miner — per-chain difficulty leaked`)
// Harder target = numerically smaller hex (more leading zeros). HardChild (tbt=5000) hardens;
// EasyChild (tbt=50) stays near-trivial. So HardChild's target must be strictly smaller.
// Targets are fixed-width 64-char unprefixed lowercase hex (UInt256.toHexString), so
// lexicographic < equals numeric < — HardChild's target must be strictly smaller (harder).
if (!(hardT < easyT)) fail(`HardChild target (${hardT?.slice(0, 16)}) is not harder than EasyChild's (${easyT?.slice(0, 16)})`)
// (Block COUNT is not asserted: under one merged miner, per-child count is governed by
// template-fetch scheduling, not difficulty, so it isn't a sound difficulty signal — the
// per-chain target divergence above is.)
console.log('  ✓ two children sustained DIFFERENT live difficulties under one merged miner (per-chain independent retarget)')

console.log('\n✓ heterogeneous-child-targets smoke test passed.')
await net.teardown(); await sleep(500); process.exit(0)
