// Nexus-only child isolation:
// A node that only joins Nexus may sync parent blocks that commit child blocks,
// but it must not acquire a child chain view, storage namespace, or child RPC
// surface unless it explicitly starts/subscribes to that child process.

import { existsSync, rmSync, mkdirSync, readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('nexus-only-child-isolation')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, bPorts, childPorts] = await allocPorts(3)
const CHILD = 'Payments'

console.log('=== nexus-only-child-isolation smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
A.start()
await A.waitForRPC()
await A.readIdentity()

const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))
B.start(['--peer', A.peerArg()])
await B.waitForRPC()

const info = await A.chainInfo()
const nexus = info.nexus
const childPath = `${nexus}/${CHILD}`

console.log('\n[1] Deploy and mine a child only on A...')
const child = net.add(await A.spawnChild({
  directory: CHILD,
  parentDirectory: nexus,
  ports: childPorts,
  initialReward: 100,
  premine: 0,
}))

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A/B root peers connected', { timeoutMs: 30_000, intervalMs: 500 })

const miner = net.addMiner(new LatticeMiner(A, [child], { workers: 2 }))
await miner.mineUntil(async () => {
  const [aRootH, childH] = await Promise.all([
    A.height(nexus),
    child.height(CHILD),
  ])
  return aRootH >= 5 && childH >= 3
    ? { aRootH, childH }
    : null
}, {
  desc: 'A child advances while mining locally',
  timeoutMs: 120_000,
  progress: async () => `${await A.height(nexus)}:${await child.height(CHILD)}`,
})
await miner.stop()
await A.awaitQuiesced(nexus)
await child.awaitQuiesced(CHILD)

const aRootH = await A.height(nexus)
const aRootTip = await A.tip(nexus)
await waitFor(async () => {
  const [bRootH, bRootTip] = await Promise.all([
    B.height(nexus),
    B.tip(nexus),
  ])
  return bRootH === aRootH && bRootTip === aRootTip
    ? { bRootH, bRootTip }
    : null
}, 'B follows frozen Nexus tip only', { timeoutMs: 120_000, intervalMs: 500 })
await B.awaitQuiesced(nexus)

console.log('\n[2] Verify B has no child chain view...')
const bInfo = await B.chainInfo()
const leaked = bInfo.chains.filter(c =>
  c.directory === CHILD || c.chainPath?.join('/') === childPath)
if (leaked.length > 0) {
  throw new Error(`B acquired child chain view: ${JSON.stringify(leaked)}`)
}
console.log(`  ✓ B chain views: ${bInfo.chains.map(c => c.chainPath?.join('/') ?? c.directory).join(', ')}`)

console.log('\n[3] Verify B does not expose child RPC state...')
const childSpec = await B.rpc('GET', `/api/chain/spec?chainPath=${encodeURIComponent(childPath)}`)
if (childSpec.ok) {
  throw new Error(`B served child spec despite not subscribing: ${JSON.stringify(childSpec.json)}`)
}
const childLatest = await B.rpc('GET', `/api/block/latest?chainPath=${encodeURIComponent(childPath)}`)
if (childLatest.ok) {
  throw new Error(`B served child latest block despite not subscribing: ${JSON.stringify(childLatest.json)}`)
}
const childGenesis = await B.rpc('GET', `/api/chain/genesis?chainPath=${encodeURIComponent(childPath)}`)
if (childGenesis.ok) {
  throw new Error(`B served child genesis metadata despite not subscribing: ${JSON.stringify(childGenesis.json)}`)
}
console.log('  ✓ child chain RPC selectors are unavailable on Nexus-only B')

console.log('\n[4] Verify B did not create a child storage namespace...')
const pathAware = `${B.dir}/chains/${nexus}/${CHILD}`
const legacy = `${B.dir}/${CHILD}`
if (existsSync(pathAware) || existsSync(legacy)) {
  throw new Error(`B created child storage namespace (${pathAware} or ${legacy})`)
}
const deployedRegistry = `${B.dir}/deployed_child_chains.json`
if (existsSync(deployedRegistry)) {
  const registry = JSON.parse(readFileSync(deployedRegistry, 'utf8'))
  const leakedRegistry = Object.entries(registry).filter(([key, metadata]) =>
    key === childPath ||
    metadata?.chainPath?.join('/') === childPath ||
    metadata?.directory === CHILD)
  if (leakedRegistry.length > 0) {
    throw new Error(`B persisted child deployment metadata: ${JSON.stringify(leakedRegistry)}`)
  }
}
console.log('  ✓ no child storage namespace or deployment metadata exists on B')

console.log('\n✓ nexus-only-child-isolation smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
