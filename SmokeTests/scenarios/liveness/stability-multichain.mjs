// Multi-chain stability: one node mines Nexus + 3 child chains for SMOKE_DURATION_MIN
// minutes (default 30). Asserts every chain keeps advancing and peak RSS stays
// under 2× steady-state baseline (caught the multi-chain leak class that
// triggered UNSTOPPABLE_LATTICE).

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor,
} from 'lattice-node-sdk'
import { scaledMs } from 'lattice-node-sdk/waitFor'
import { rssBytes } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('stability-multichain')
const [nexusPorts, ...childPorts] = await allocPorts(4, { seed: 5 })
const DURATION_MIN = Number(process.env.SMOKE_DURATION_MIN || 30)
const SAMPLE_INTERVAL_S = 30
const WARMUP_S = 60
const RSS_RATIO_LIMIT = 2.0
const STALL_GRACE_MS = scaledMs(Number(process.env.SMOKE_STABILITY_STALL_GRACE_MS || 120_000))
const CHAINS = ['Alpha', 'Beta', 'Gamma']

console.log(`=== stability-multichain smoke (${DURATION_MIN}min, ${CHAINS.length + 1} chains) ===`)
const node = new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
})
const net = new LatticeNetwork([node])
net.installSignalHandlers()

node.start()
await node.waitForRPC()
await node.readIdentity()
const info = await node.chainInfo()
const nexusDir = info.nexus

console.log(`\n[2] Deploy ${CHAINS.length} child chains...`)
const childNodes = []
for (const [i, dir] of CHAINS.entries()) {
  const child = await node.spawnChild({
    directory: dir,
    parentDirectory: nexusDir,
    ports: childPorts[i],
    premine: 0,
  })
  net.add(child)
  childNodes.push(child)
}
const miner = new LatticeMiner(node, childNodes, { workers: 2 })
net.addMiner(miner)
await miner.start()

await waitFor(async () => {
  const heights = await sampleHeights()
  return Object.values(heights).every((h) => h > 0) ? heights : null
}, 'all chains started', { timeoutMs: 180_000, intervalMs: 1000 })

console.log(`\n[3] Warmup ${WARMUP_S}s before sampling baseline RSS...`)
await sleep(WARMUP_S * 1000)

const samples = []
async function sampleHeights() {
  const entries = await Promise.all([
    node.height(nexusDir).then((h) => [nexusDir, h]),
    ...childNodes.map((child) => child.height(child.chainPath.at(-1)).then((h) => [child.chainPath.at(-1), h])),
  ])
  return Object.fromEntries(entries)
}

function totalRSS() {
  const pids = [
    node.proc?.pid,
    ...childNodes.map((child) => child.proc?.pid),
    miner.proc?.pid,
  ].filter(Boolean)
  return pids.reduce((sum, pid) => {
    try {
      return sum + rssBytes(pid)
    } catch {
      return sum
    }
  }, 0)
}

async function sample() {
  const heights = await sampleHeights()
  const rss = totalRSS()
  return { t: Date.now(), rss, heights }
}

const baseline = await sample()
samples.push(baseline)
const lastAdvancedAt = Object.fromEntries(
  Object.keys(baseline.heights).map((dir) => [dir, baseline.t]),
)
console.log(`  baseline RSS=${(baseline.rss / 1024 / 1024).toFixed(1)}MB heights=${JSON.stringify(baseline.heights)}`)

const endAt = Date.now() + DURATION_MIN * 60 * 1000
let peakRSS = baseline.rss
let stallDetected = null

while (Date.now() < endAt) {
  const remaining = endAt - Date.now()
  await sleep(Math.min(SAMPLE_INTERVAL_S * 1000, remaining))
  const s = await sample()
  samples.push(s)
  const prev = samples[samples.length - 2]
  const rssMB = (s.rss / 1024 / 1024).toFixed(1)
  const ratio = (s.rss / baseline.rss).toFixed(2)
  if (s.rss > peakRSS) peakRSS = s.rss

  for (const dir of [nexusDir, ...CHAINS]) {
    const before = prev.heights[dir] ?? 0
    const after = s.heights[dir] ?? 0
    if (after > before) {
      lastAdvancedAt[dir] = s.t
    } else if (s.t - (lastAdvancedAt[dir] ?? baseline.t) > STALL_GRACE_MS) {
      stallDetected = stallDetected || `${dir} stalled at height ${after} for >${Math.round(STALL_GRACE_MS / 1000)}s`
    }
  }

  const elapsedMin = ((Date.now() - baseline.t) / 60000).toFixed(1)
  console.log(`  t=${elapsedMin}m RSS=${rssMB}MB (${ratio}× baseline) heights=${JSON.stringify(s.heights)}`)
  if (stallDetected) break
}

await miner.stop()
net.teardown()

await sleep(500)

if (stallDetected) {
  console.error(`\n  ✗ stall: ${stallDetected}`)
  console.error(`    inspect ${ROOT}/node.log and ${ROOT}/miner.log`)
  process.exit(1)
}

const peakRatio = peakRSS / baseline.rss
const peakMB = (peakRSS / 1024 / 1024).toFixed(1)
console.log(`\n  baseline RSS ${(baseline.rss / 1024 / 1024).toFixed(1)}MB → peak ${peakMB}MB (${peakRatio.toFixed(2)}× baseline)`)
if (peakRatio > RSS_RATIO_LIMIT) {
  console.error(`  ✗ RSS exceeded ${RSS_RATIO_LIMIT}× steady-state — multi-chain leak suspected`)
  process.exit(1)
}

const last = samples[samples.length - 1]
const advanced = Object.fromEntries(
  Object.entries(last.heights).map(([d, h]) => [d, h - (baseline.heights[d] ?? 0)]),
)
console.log(`  height progress over run: ${JSON.stringify(advanced)}`)
console.log('\n✓ stability-multichain smoke test passed.')
process.exit(0)
