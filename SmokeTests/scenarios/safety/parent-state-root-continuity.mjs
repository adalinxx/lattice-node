// Parent state root continuity is proof continuity, not parent canonicity.
//
// This scenario drives the production per-process path:
//   Nexus process -> child process -> external merged-mining coordinator.
// Each accepted child block must anchor its parentStateCID to the proven parent
// carrier block's prevStateCID. Consecutive child blocks may skip parent blocks,
// but the old parent-state root must transition to the new root through mined
// parent prevState -> postState edges.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('parent-state-root-continuity')
const [nexusPorts, childPorts] = await allocPorts(2, { seed: 155 })
const CHILD = 'Continuity'

console.log('=== parent-state-root-continuity smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

async function fail(message) {
  console.error(`  ✗ ${message}`)
  net.teardown(); await sleep(500); process.exit(1)
}

function pathParam(path) {
  return encodeURIComponent(Array.isArray(path) ? path.join('/') : path)
}

async function rpcOK(node, method, path, label) {
  const r = await node.rpc(method, path)
  if (!r.ok) await fail(`${label} failed: ${JSON.stringify(r.json)}`)
  return r.json
}

function reachableByParentTransitions(fromRoot, toRoot, transitionMap, maxSteps) {
  if (fromRoot === toRoot) return true
  let current = fromRoot
  const seen = new Set([current])
  for (let i = 0; i < maxSteps; i++) {
    const next = transitionMap.get(current)
    if (!next) return false
    if (next === toRoot) return true
    if (seen.has(next)) return false
    seen.add(next)
    current = next
  }
  return false
}

console.log('\n[1] Start Nexus and spawn per-process child...')
const nexus = net.add(new LatticeNode({
  name: 'Nexus',
  dir: `${ROOT}/Nexus`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
}))
nexus.start()
await nexus.waitForRPC()
await nexus.readIdentity()

const nexusDir = (await nexus.chainInfo()).nexus
const child = net.add(await nexus.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  targetBlockTime: 250,
  initialReward: 128,
  ports: childPorts,
}))
const childPath = [nexusDir, CHILD]
console.log(`  ✓ child ${childPath.join('/')} running at ${child.base}`)

console.log('\n[2] Mine parent and child through the coordinator...')
const miner = net.addMiner(new LatticeMiner(nexus, [child], { workers: 2, batchSize: 2000 }))
await miner.start()
await waitFor(async () => {
  const [parentHeight, childHeight] = await Promise.all([
    nexus.height(nexusDir),
    child.height(CHILD),
  ])
  return parentHeight >= 8 && childHeight >= 4 ? { parentHeight, childHeight } : null
}, 'Nexus and child have mined enough blocks', {
  timeoutMs: 120_000,
  intervalMs: 500,
  progress: async () => `${await nexus.height(nexusDir)}:${await child.height(CHILD)}`,
})
await miner.stop()
await nexus.awaitQuiesced(nexusDir)
await child.awaitQuiesced(CHILD)
const parentHeight = await nexus.height(nexusDir)
const childHeight = await child.height(CHILD)
console.log(`  ✓ mined Nexus@${parentHeight} ${CHILD}@${childHeight}`)

console.log('\n[3] Build parent state transition graph and child carrier index...')
const parentBlocks = []
const parentChildren = new Map()
const transitionMap = new Map()
for (let h = 0; h <= parentHeight; h++) {
  const block = await rpcOK(nexus, 'GET', `/api/block/${h}?chainPath=${pathParam(nexusDir)}`, `parent block ${h}`)
  parentBlocks.push(block)
  if (block.prevStateCID && block.postStateCID && !transitionMap.has(block.prevStateCID)) {
    transitionMap.set(block.prevStateCID, block.postStateCID)
  }
  const children = await rpcOK(nexus, 'GET', `/api/block/${h}/children?chainPath=${pathParam(nexusDir)}`, `parent children ${h}`)
  for (const entry of children.children ?? []) {
    parentChildren.set(entry.blockHash, { parentHeight: h, parentBlock: block, childEntry: entry })
  }
}
console.log(`  ✓ indexed ${parentBlocks.length} parent blocks and ${parentChildren.size} carried child block(s)`)

console.log('\n[4] Verify child anchors use parent prevState and are state-root continuous...')
let previousParentState = null
let checked = 0
for (let h = 1; h <= childHeight; h++) {
  const childBlock = await rpcOK(child, 'GET', `/api/block/${h}?chainPath=${pathParam(childPath)}`, `child block ${h}`)
  const carrier = parentChildren.get(childBlock.hash)
  if (!carrier) {
    await fail(`child block ${h} ${childBlock.hash} was not found in any parent children dictionary`)
  }
  if (carrier.childEntry.directory !== CHILD) {
    await fail(`child block ${h} was carried under ${carrier.childEntry.directory}, expected ${CHILD}`)
  }
  if (childBlock.parentStateCID !== carrier.parentBlock.prevStateCID) {
    await fail(
      `child block ${h} parentStateCID=${childBlock.parentStateCID} does not match carrier parent block ${carrier.parentHeight} prevStateCID=${carrier.parentBlock.prevStateCID}`
    )
  }
  if (childBlock.parentStateCID === carrier.parentBlock.postStateCID && carrier.parentBlock.prevStateCID !== carrier.parentBlock.postStateCID) {
    await fail(`child block ${h} appears anchored to carrier postStateCID instead of prevStateCID`)
  }
  if (previousParentState && !reachableByParentTransitions(previousParentState, childBlock.parentStateCID, transitionMap, parentBlocks.length + 1)) {
    await fail(`child block ${h} parentStateCID is not continuous from previous child parentStateCID`)
  }
  previousParentState = childBlock.parentStateCID
  checked++
}

if (checked < 4) await fail(`only checked ${checked} child blocks`)
console.log(`  ✓ verified ${checked} child parent-state anchors through parent prevState transitions`)

console.log('\n✓ parent-state-root-continuity smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
