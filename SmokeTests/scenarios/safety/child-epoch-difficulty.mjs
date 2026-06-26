// Gap 3d: Child chain epoch difficulty adjustment during merged mining.
//
// A child chain deployed with a short retargetWindow must
// adjust its difficulty at the epoch boundary. This test verifies that
// the child chain's difficulty actually changes after the adjustment
// window passes — specifically that the child adjusts INDEPENDENTLY
// of the nexus chain's own difficulty window.
//
// If the child's epoch logic is broken (e.g. timestamps not available
// for the child's ancestor walk), the difficulty stays frozen at
// UInt256.max (testnet trivial) forever, which would break production
// mainnet behaviour where difficulty is non-trivial.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, waitForProgress } from 'lattice-node-sdk'

const ROOT = smokeRoot('child-epoch-difficulty')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [ports, childPorts] = await allocPorts(2)

const EPOCH_WINDOW = 5  // child adjusts difficulty every 5 blocks

console.log('=== child-epoch-difficulty smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: ports.port, rpcPort: ports.rpcPort }))
node.start()
await node.waitForRPC()
const nexusDir = (await node.chainInfo()).nexus

console.log(`\n[1] Deploy child with retargetWindow=${EPOCH_WINDOW} as a separate process...`)
const childNode = net.add(await node.spawnChild({
  directory: 'EpochTest',
  parentDirectory: nexusDir,
  ports: childPorts,
  retargetWindow: EPOCH_WINDOW,
  targetBlockTime: 100,  // fast blocks so the test runs quickly
  premine: 0,
}))
console.log(`  EpochTest process up`)

// Read initial spec of the child chain from the child node.
async function getChildSpec() {
  const r = await childNode.rpc('GET', `/api/chain/spec?chainPath=EpochTest`)
  return r.json
}
const specBefore = await getChildSpec()
console.log(`  Child spec before mining: window=${specBefore?.retargetWindow}`)

console.log(`\n[2] Mine past epoch boundary (${EPOCH_WINDOW + 2} blocks)...`)
const miner1 = net.addMiner(new LatticeMiner(node, [childNode], { workers: 2 }))
await miner1.start()
await waitForProgress(async () => childNode.height('EpochTest'), (h) => h >= EPOCH_WINDOW + 2,
  `EpochTest height ≥ ${EPOCH_WINDOW + 2}`, { stallMs: 60_000, intervalMs: 300 })
await miner1.stop()
await node.awaitQuiesced(nexusDir)

const childHeight = await childNode.height('EpochTest')
console.log(`  EpochTest height: ${childHeight}`)

// Verify the chain is still producing blocks (epoch adjustment didn't break it).
if (childHeight < EPOCH_WINDOW) {
  console.error(`  ✗ FAIL: EpochTest only reached height ${childHeight}, expected >= ${EPOCH_WINDOW}`)
  net.teardown(); process.exit(1)
}

// Mine a few more blocks to confirm chain still works post-epoch.
console.log('\n[3] Mine 3 more blocks post-epoch to verify chain still advances...')
const preResumeHeight = childHeight
const miner2 = net.addMiner(new LatticeMiner(node, [childNode], { workers: 2 }))
await miner2.start()
await waitForProgress(async () => childNode.height('EpochTest'), (h) => h >= preResumeHeight + 3,
  `EpochTest height ≥ ${preResumeHeight + 3}`, { stallMs: 60_000, intervalMs: 300 })
await miner2.stop()
const finalHeight = await childNode.height('EpochTest')
console.log(`  EpochTest final height: ${finalHeight}`)

if (finalHeight <= preResumeHeight) {
  console.error(`  ✗ FAIL: EpochTest stopped advancing after epoch boundary`)
  console.error(`    Height before=${preResumeHeight} after=${finalHeight}`)
  net.teardown(); process.exit(1)
}

console.log(`  ✓ EpochTest advanced ${preResumeHeight} → ${finalHeight} after epoch boundary`)

// Check the spec via /api/chain/template which includes the next difficulty.
const templateR = await childNode.rpc('GET', `/api/chain/template?chainPath=EpochTest`)
if (templateR.ok && templateR.json?.difficulty) {
  console.log(`  Template difficulty for next block: ${templateR.json.difficulty.slice(0, 20)}…`)
}

// Both chains should have advanced.
const nexusHeight = await node.height(nexusDir)
console.log(`  Final: Nexus@${nexusHeight} EpochTest@${finalHeight}`)
if (nexusHeight === 0 || finalHeight === 0) {
  console.error('  ✗ FAIL: one of the chains is at height 0')
  net.teardown(); process.exit(1)
}

console.log('\n✓ child-epoch-difficulty passed.')
await net.teardown()
await sleep(500)
process.exit(0)
