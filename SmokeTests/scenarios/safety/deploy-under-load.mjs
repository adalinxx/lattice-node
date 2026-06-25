// Deploy child chain under live mining: verify dynamic chain registration works
// mid-operation without giving the parent a child chain view. The child must be
// discoverable via chain/map, mine in its own process, and accept transactions.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, genKeypair } from 'lattice-node-sdk'

const ROOT = smokeRoot('deploy-under-load')
const [nodePorts, childPorts, child2Ports] = await allocPorts(3, { seed: 73 })

async function fail(message) {
  console.error(`  ✗ ${message}`)
  net.teardown(); await sleep(500); process.exit(1)
}

function chainPaths(info) {
  return (info.chains ?? []).map(c => c.chainPath?.join('/') ?? c.directory).sort()
}

console.log('=== deploy-under-load smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: nodePorts.port, rpcPort: nodePorts.rpcPort }))
node.start()
await node.waitForRPC()
await node.readIdentity()

const info = await node.chainInfo()
const nexusDir = info.nexus
const initialChains = chainPaths(info)

console.log(`\n[1] Start mining on Nexus...`)
let miner = net.addMiner(new LatticeMiner(node, [], { workers: 2 }))
await miner.start()
await node.waitForHeight(3, nexusDir, { timeoutMs: 120_000 })

console.log(`\n[2] Deploy child chain while mining is active...`)
const CHILD = 'HotDeploy'
const childFunder = genKeypair()
const preDeployHeight = await node.height(nexusDir)
let childNode = net.add(await node.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  initialReward: 256,
  premine: 2_000,
  premineRecipient: childFunder.address,
  ports: childPorts,
}))
await node.waitForHeight(preDeployHeight + 1, nexusDir, { timeoutMs: 120_000 })

const postDeploy = await node.chainInfo()
const postDeployChains = chainPaths(postDeploy)
if (JSON.stringify(postDeployChains) !== JSON.stringify(initialChains)) {
  await fail(`parent chain/info changed during deploy: before=${JSON.stringify(initialChains)} after=${JSON.stringify(postDeployChains)}`)
}
const leakedChildEntry = postDeploy.chains.find(c => c.directory === CHILD || c.chainPath?.join('/') === `${nexusDir}/${CHILD}`)
if (leakedChildEntry) {
  await fail(`parent node leaked ${CHILD} chain view after deploy: ${JSON.stringify(leakedChildEntry)}`)
}
const childPathText = `${nexusDir}/${CHILD}`
// Registered endpoints are stored in API-base form (trailing /api); normalize before compare.
const normEndpoint = (u) => (u ?? '').replace(/\/api\/?$/, '')
const chainMap = await waitFor(async () => {
  const r = await node.rpc('GET', '/api/chain/map')
  return r.ok && normEndpoint(r.json?.[childPathText]) === normEndpoint(childNode.base) ? r.json : null
}, `${CHILD} registered in chain/map`, { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  ✓ parent mined during deploy (${preDeployHeight}→${await node.height(nexusDir)}), chain/info unchanged (${initialChains.join(', ')}), chain/map routes ${childPathText} -> ${chainMap[childPathText]}`)

console.log(`\n[3] Wait for child chain to mine blocks...`)
await miner.stop()
miner = net.addMiner(new LatticeMiner(node, [childNode], { workers: 2 }))
await miner.start()
await childNode.waitForHeight(5, CHILD, { timeoutMs: 120_000 })
const childHeight = node.chainOf(await childNode.chainInfo(), CHILD).height
console.log(`  ✓ ${CHILD} mining at height ${childHeight}`)

console.log(`\n[4] Submit tx on the new child chain...`)
await miner.stop()
await node.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)
const user = genKeypair()
const funderBalance = await childNode.balance(childFunder.address, CHILD)
if (funderBalance < 1_000) {
  console.error(`  ✗ child premine missing: balance=${funderBalance}`)
  net.teardown(); await sleep(500); process.exit(1)
}
const nonce = await childNode.nonce(childFunder.address, CHILD)
const r = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce, signers: [childFunder.address], fee: 1,
  accountActions: [
    { owner: childFunder.address, delta: -501 },
    { owner: user.address, delta: 500 },
  ],
}, CHILD, childFunder)
if (!r.ok) throw new Error(`tx on new child failed: ${JSON.stringify(r)}`)

miner = net.addMiner(new LatticeMiner(node, [childNode], { workers: 2 }))
await miner.start()
await waitFor(async () => (await childNode.balance(user.address, CHILD)) >= 500,
  'user funded on child', { timeoutMs: 120_000 })
console.log(`  ✓ tx confirmed on dynamically deployed chain`)

console.log(`\n[5] Deploy a second child chain...`)
const CHILD2 = 'HotDeploy2'
const preSecondDeployHeight = await node.height(nexusDir)
let childNode2 = net.add(await node.spawnChild({
  directory: CHILD2,
  parentDirectory: nexusDir,
  initialReward: 128,
  ports: child2Ports,
}))
await node.waitForHeight(preSecondDeployHeight + 1, nexusDir, { timeoutMs: 120_000 })
const child2PathText = `${nexusDir}/${CHILD2}`
const postSecondDeploy = await node.chainInfo()
const postSecondChains = chainPaths(postSecondDeploy)
if (JSON.stringify(postSecondChains) !== JSON.stringify(initialChains)) {
  await fail(`parent chain/info changed during second deploy: before=${JSON.stringify(initialChains)} after=${JSON.stringify(postSecondChains)}`)
}
const secondMap = await waitFor(async () => {
  const r = await node.rpc('GET', '/api/chain/map')
  return r.ok && normEndpoint(r.json?.[childPathText]) === normEndpoint(childNode.base) && normEndpoint(r.json?.[child2PathText]) === normEndpoint(childNode2.base) ? r.json : null
}, `${CHILD2} registered in chain/map`, { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  ✓ parent mined during second deploy (${preSecondDeployHeight}→${await node.height(nexusDir)}); chain/map routes ${child2PathText} -> ${secondMap[child2PathText]}`)
await miner.stop()
miner = net.addMiner(new LatticeMiner(node, [childNode, childNode2], { workers: 2 }))
await miner.start()
await childNode2.waitForHeight(3, CHILD2, { timeoutMs: 120_000 })
const finalInfo = await childNode2.chainInfo()
console.log(`  chains: ${finalInfo.chains.map(c => `${c.directory}@${c.height}`).join(', ')}`)
console.log(`  ✓ second child deployed and mining`)

console.log(`\n✓ deploy-under-load smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
