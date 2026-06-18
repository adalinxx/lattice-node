// Legacy filename: this now tests strict-work convergence, not equal-work
// tiebreak adoption. Lattice consensus selects the greatest trueCumWork tip; an
// exact tie holds the incumbent. The smoke therefore creates two isolated
// equal-height forks, verifies a peer does not switch just because it heard a
// sibling tip, then extends one fork and requires convergence only once that
// fork is strictly heavier.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor, peerCount } from 'lattice-node-sdk'

const ROOT = smokeRoot('tiebreaker-convergence')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, bPorts] = await allocPorts(2)

console.log('=== strict-work convergence smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

// Continuous external mining overshoots a requested height by a block or two
// (the miner submits in-flight blocks between the height check and stop), so a
// single mine can't reliably land two isolated forks on the SAME height.
// mineForkTo polls tightly and stops the instant the target is reached to keep
// overshoot small; equalizeForks then nudges whichever fork is short until both
// sit at the same height (equal work) on different tips.
async function mineForkTo(node, directory, target) {
  await node.startMining(directory)
  try {
    const start = Date.now()
    while (Date.now() - start < 45_000) {
      if ((await node.height(directory)) >= target) break
      await sleep(100)
    }
  } finally {
    await node.stopMining(directory)
    await node.awaitQuiesced(directory)
  }
  return node.height(directory)
}

async function mineTo(node, directory, height, label) {
  await mineForkTo(node, directory, height)
  console.log(`  ${label} height=${await node.height(directory)} tip=${(await node.tip(directory)).slice(0, 12)}...`)
}

// Drive A and B to an identical height (equal work) despite per-mine overshoot:
// repeatedly extend whichever fork is behind up to the taller one. With the
// tight-poll stop the catch-up mine usually lands exactly, so this converges in
// a couple of rounds; the cap guards against a pathological ping-pong.
async function equalizeForks(directory) {
  let hA = await A.height(directory)
  let hB = await B.height(directory)
  for (let i = 0; i < 12 && hA !== hB; i++) {
    const target = Math.max(hA, hB)
    if (hA < target) await mineForkTo(A, directory, target)
    else await mineForkTo(B, directory, target)
    hA = await A.height(directory)
    hB = await B.height(directory)
  }
  return [hA, hB]
}

async function fail(message) {
  console.error(`  ✗ FAILURE: ${message}`)
  await net.teardown()
  await sleep(500)
  process.exit(1)
}

// ── [1] Build two isolated equal-work forks ────────────────────────────────

console.log('\n[1] Boot A and B without peers, mine equal-height forks...')
A.start(['--finality-confirmations', '999999'])
B.start(['--finality-confirmations', '999999'])
await Promise.all([A.waitForRPC(), B.waitForRPC()])
await Promise.all([A.readIdentity(), B.readIdentity()])
const nexusDir = (await A.chainInfo()).nexus

await mineTo(A, nexusDir, 5, 'A isolated fork')
await mineTo(B, nexusDir, 5, 'B isolated fork')
const [aTieHeight, bTieHeight] = await equalizeForks(nexusDir)
console.log(`  equalized forks: A=${aTieHeight} B=${bTieHeight}`)

const aTieTip = await A.tip(nexusDir)
const bTieTip = await B.tip(nexusDir)
if (aTieTip === bTieTip) {
  await fail('isolated forks unexpectedly produced the same tip; test cannot exercise fork choice')
}
if (aTieHeight !== bTieHeight) {
  await fail(`isolated forks must have equal work before tie check (A=${aTieHeight} B=${bTieHeight})`)
}

// ── [2] Connect at equal work: incumbent must hold ─────────────────────────

console.log('\n[2] Restart B with A as peer; equal work must not displace B incumbent...')
await B.stop()
B.start(['--peer', A.peerArg(), '--finality-confirmations', '999999'])
await B.waitForRPC()
await waitFor(async () => (await peerCount(B)) >= 1 ? true : null, 'B connected to A', {
  timeoutMs: 30_000,
  intervalMs: 500,
})

await sleep(3_000)
const bAfterTieConnect = await B.tip(nexusDir)
if (bAfterTieConnect !== bTieTip) {
  await fail(`B adopted an equal-work sibling tip (${bAfterTieConnect.slice(0, 12)}...); exact ties must hold incumbent ${bTieTip.slice(0, 12)}...`)
}
console.log('  ✓ equal-work sibling did not replace B incumbent')

// ── [3] Extend A: strictly heavier work must converge ─────────────────────

// Extend A well past catchUpSyncThreshold (3) so convergence exercises the
// robust catch-up sync path. A 1-block sibling-reorg would instead depend on
// small-reorg gossip propagation, which is a separate reliability property
// (covered by deep-reorg / cross-chain-reorg); here we assert only that a
// strictly heavier fork is adopted.
console.log('\n[3] Extend A; B must adopt the strictly heavier fork...')
await mineTo(A, nexusDir, aTieHeight + 5, 'A heavier fork')
const aHeavierTip = await A.tip(nexusDir)

const convergedTip = await waitFor(async () => {
  const bTip = await B.tip(nexusDir)
  return bTip === aHeavierTip ? bTip : null
}, 'B adopted A strictly heavier tip', { timeoutMs: 45_000, intervalMs: 500 })

const [aFinal, bFinal] = await Promise.all([A.height(nexusDir), B.height(nexusDir)])
if (aFinal !== bFinal || aFinal <= aTieHeight) {
  await fail(`unexpected final heights A=${aFinal} B=${bFinal}`)
}

console.log(`  ✓ converged at strictly heavier tip=${convergedTip.slice(0, 12)}... height=${aFinal}`)
console.log('\n✓ tiebreaker-convergence passed.')
await net.teardown()
await sleep(500)
process.exit(0)
