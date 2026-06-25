// Chain spec + deployment test. Verifies:
//   1. /api/chain/spec returns expected Nexus parameters
//   2. Deploying a child chain with custom config succeeds
//   3. The deployed child's spec matches what was requested
//   4. Child process owns child chain/info; parent exposes only route metadata

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('chain-spec')
const [{ port, rpcPort }, childPorts] = await allocPorts(2, { seed: 55 })
const CHILD = 'CustomChild'

async function fail(message) {
  console.error(`  ✗ ${message}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log('=== chain-spec smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort }))
node.start()
await node.waitForRPC()

const info = await node.chainInfo()
const nexusDir = info.nexus
console.log(`  nexus=${nexusDir} genesis=${info.genesisHash.slice(0, 24)}...`)

console.log(`\n[1] Query Nexus chain spec...`)
const specResp = await node.rpc('GET', `/api/chain/spec?chainPath=${nexusDir}`)
if (!specResp.ok) throw new Error(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const spec = specResp.json
console.log(`  directory: ${spec.directory}`)
console.log(`  targetBlockTime: ${spec.targetBlockTime}`)
console.log(`  initialReward: ${spec.initialReward}`)
console.log(`  halvingInterval: ${spec.halvingInterval}`)
console.log(`  maxTransactionsPerBlock: ${spec.maxTransactionsPerBlock}`)

if (spec.directory !== nexusDir) {
  console.error(`  ✗ spec directory "${spec.directory}" != "${nexusDir}"`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (typeof spec.initialReward !== 'number' || spec.initialReward <= 0) {
  console.error(`  ✗ invalid initialReward: ${spec.initialReward}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ Nexus spec is well-formed`)

console.log(`\n[2] Deploy child chain with custom parameters as a separate process...`)
const customOpts = {
  directory: CHILD,
  parentDirectory: nexusDir,
  targetBlockTime: 2000,
  initialReward: 512,
  halvingInterval: 100000,
  maxTransactionsPerBlock: 50,
  premine: 0,
  ports: childPorts,
}
const childNode = net.add(await node.spawnChild(customOpts))
console.log(`  child process up`)

// Use LatticeMiner to mine the child chain.
const miner = net.addMiner(new LatticeMiner(node, [childNode], { workers: 2 }))
await miner.start()
await waitFor(async () => {
  const h = await childNode.height(CHILD)
  return h >= 3 ? h : null
}, `${CHILD} height ≥ 3`, { timeoutMs: 120_000, intervalMs: 500 })
await miner.stop()
console.log(`  ✓ child chain deployed and mining`)

console.log(`\n[3] Verify child spec matches requested params...`)
// Query child spec from the child node process.
const childSpec = await childNode.rpc('GET', `/api/chain/spec?chainPath=${CHILD}`)
if (!childSpec.ok) throw new Error(`child spec failed: ${JSON.stringify(childSpec.json)}`)
const cs = childSpec.json
console.log(`  child spec: reward=${cs.initialReward} halving=${cs.halvingInterval} maxTx=${cs.maxTransactionsPerBlock}`)

const expectedSpec = {
  directory: CHILD,
  targetBlockTime: customOpts.targetBlockTime,
  initialReward: customOpts.initialReward,
  halvingInterval: customOpts.halvingInterval,
  maxTransactionsPerBlock: customOpts.maxTransactionsPerBlock,
}
for (const [field, expected] of Object.entries(expectedSpec)) {
  if (cs[field] !== expected) await fail(`child spec ${field} mismatch: ${cs[field]} != ${expected}`)
}
const childPathText = `${nexusDir}/${CHILD}`
const proxiedSpec = await node.rpc('GET', `/api/chain/spec?chainPath=${encodeURIComponent(childPathText)}`)
if (!proxiedSpec.ok) await fail(`parent-proxied child spec failed: ${JSON.stringify(proxiedSpec.json)}`)
for (const [field, expected] of Object.entries(expectedSpec)) {
  if (proxiedSpec.json[field] !== expected) await fail(`proxied child spec ${field} mismatch: ${proxiedSpec.json[field]} != ${expected}`)
}
console.log(`  ✓ child spec matches requested parameters locally and through parent chain path`)

console.log(`\n[4] Verify parent has no child view and child owns chain/info...`)
const postInfo = await node.chainInfo()
if (!Array.isArray(postInfo.chains) || postInfo.chains.length !== 1 || postInfo.chains[0].directory !== nexusDir) {
  await fail(`parent chain/info should contain only ${nexusDir}: ${JSON.stringify(postInfo.chains)}`)
}
const leakedChildEntry = postInfo.chains.find(c => c.directory === CHILD || c.chainPath?.join('/') === `${nexusDir}/${CHILD}`)
if (leakedChildEntry) {
  await fail(`parent node leaked child chain view: ${JSON.stringify(leakedChildEntry)}`)
}
const chainMap = await node.rpc('GET', '/api/chain/map')
// Registered endpoints are stored in API-base form (trailing /api); normalize before compare.
const normEndpoint = (u) => (u ?? '').replace(/\/api\/?$/, '')
if (!chainMap.ok || normEndpoint(chainMap.json?.[childPathText]) !== normEndpoint(childNode.base)) {
  await fail(`parent chain/map did not route ${childPathText} to child: ${JSON.stringify(chainMap.json)}`)
}
const childInfo = await childNode.chainInfo()
if (!Array.isArray(childInfo.chains) || childInfo.chains.length !== 1) {
  await fail(`child chain/info should contain exactly one local chain: ${JSON.stringify(childInfo.chains)}`)
}
const childEntry = childInfo.chains.find(c => c.directory === CHILD && c.chainPath?.join('/') === childPathText)
if (!childEntry || childEntry.height < 3) {
  await fail(`child process does not own ${childPathText}: ${JSON.stringify(childInfo.chains)}`)
}
if (childEntry.parentDirectory !== nexusDir) {
  await fail(`child parentDirectory ${childEntry.parentDirectory} != ${nexusDir}`)
}
console.log(`  ✓ parent only routes ${childPathText}; child owns chain/info at height ${childEntry.height}`)

console.log(`\n✓ chain-spec smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
