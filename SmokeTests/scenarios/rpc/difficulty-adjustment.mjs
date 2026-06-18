// Difficulty adjustment: verify the per-block PoW target actually retargets as
// blocks are produced.
//
// The node uses a sliding-window retarget: each block's target is recomputed
// from the recent solve-time history, clamped to at most a 2x change per step.
// The external mining coordinator solves far faster than the Nexus target block
// time, so every block's solve interval is well under target and the windowed
// retarget HARDENS the target (halving it, the per-step clamp) each block. A
// handful of blocks is therefore enough to see the target move — no need to mine
// a full ~120-block window (which is both slow and, once the target hardens,
// effectively unmineable by the test coordinator).
//
// IMPORTANT: this requires the genesis timestamp to be ~now. The shared harness
// default (DEV_GENESIS_TS) is pinned ~14 months in the past, so the very first
// genesis->block-1 interval is enormous; while that giant interval dominates the
// retarget window it pins the target at its easiest (maximum) value and masks
// any adjustment. We override the genesis timestamp to the current time for this
// node so the retarget reflects the real (fast) solve times from block 1.
//
// Block production runs in the external mining coordinator (the node never mines
// in-process).

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('difficulty-adjustment')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 67 })

console.log('=== difficulty-adjustment smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
// Override the genesis timestamp to ~now so the retarget is driven by the real
// (fast) coordinator solve times from block 1 rather than a giant past gap.
node.start({ genesisTimestamp: Date.now() })
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log(`\n[1] Query early block target...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 4, 120_000)
const earlyBlock = await node.rpc('GET', `/api/block/2?chainPath=${nexusDir}`)
const earlyTarget = earlyBlock.json?.target
console.log(`  block 2 target: ${earlyTarget?.slice(0, 20)}...`)

// Mine enough blocks for the sliding retarget to harden the target by several
// clamped steps. Each fast block halves the target, so ~10 blocks moves it well
// clear of its block-2 value while remaining quick to reach.
console.log(`\n[2] Mine a few more blocks so the target retargets...`)
const LATE_HEIGHT = 10
await waitForHeight(node, nexusDir, LATE_HEIGHT + 2, 180_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const height = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  reached height ${height}`)

console.log(`\n[3] Query late block target...`)
const lateBlock = await node.rpc('GET', `/api/block/${LATE_HEIGHT}?chainPath=${nexusDir}`)
const lateTarget = lateBlock.json?.target
console.log(`  block ${LATE_HEIGHT} target: ${lateTarget?.slice(0, 20)}...`)

if (!earlyTarget || !lateTarget) {
  console.error(`  ✗ couldn't read target from block responses`)
  node.stop(); await sleep(500); process.exit(1)
}

if (earlyTarget === lateTarget) {
  console.error(`  ✗ target did not adjust across the retarget window`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ target adjusted: ${earlyTarget.slice(0, 16)}... → ${lateTarget.slice(0, 16)}...`)

// The /api/block/latest tip summary intentionally omits nextTarget; read it
// from the numbered block detail endpoint, which carries the full PoW fields.
console.log(`\n[4] Verify nextTarget field exists...`)
const hasNextTarget = lateBlock.json?.nextTarget !== undefined
console.log(`  nextTarget present: ${hasNextTarget}`)
if (!hasNextTarget) {
  console.error(`  ✗ block ${LATE_HEIGHT} missing nextTarget`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  nextTarget: ${lateBlock.json.nextTarget?.toString().slice(0, 20)}...`)

console.log(`\n✓ difficulty-adjustment smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
