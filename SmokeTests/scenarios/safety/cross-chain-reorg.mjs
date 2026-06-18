// Cross-chain reorg: deposit on child chain during partition, verify parent
// chain canonicity does not erase already-verified child-chain state.
//
// All nodes share genesis (C syncs from A before partitioning).
// After partition, C mines more to become heavier. On heal, A reorgs
// to C's chain. The child chain deposit remains valid because the child PoW
// slice and state transition were already independently verified.
//
// Per-process version: the child chain (Reorgable) runs as a separate
// process subscribed to A's Nexus. When Nexus reorgs, the child
// process receives new parent blocks via ParentChainBlockExtractor for future
// mining context, not to roll back valid child state.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress, peerCount,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('cross-chain-reorg')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [a, c, childPorts] = await allocPorts(3)
const CHILD = 'Reorgable'

console.log('=== cross-chain-reorg smoke test ===')

const A = new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort })
const C = new LatticeNode({ name: 'C', dir: `${ROOT}/C`, port: c.port, rpcPort: c.rpcPort })

const net = new LatticeNetwork()
net.add(A)
net.add(C)
net.installSignalHandlers()

// Helper: stop a node and wait until its RPC stops responding.
async function stopAndAwaitShutdown(node, { timeoutMs = 30_000 } = {}) {
  await node.stop()
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      await fetch(`${node.base}/api/chain/info`, { signal: AbortSignal.timeout(500) })
    } catch {
      return
    }
    await sleep(500)
  }
  throw new Error(`${node.name} failed to shut down within ${timeoutMs}ms`)
}

// Helper: get tip height + hash for a node's nexus chain.
async function tipInfo(node, dir) {
  const info = await node.chainInfo()
  if (!info) return null
  const target = dir ?? info.nexus
  const ch = info.chains?.find(c => c.directory === target)
  return { directory: target, height: ch?.height ?? 0, tip: ch?.tip ?? '', nexus: info.nexus }
}

console.log('\n[1] Boot A, deploy child as separate process, let C sync genesis...')
A.start(['--finality-confirmations', '999999'])
await A.waitForRPC()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)
const nexusDir = (await A.chainInfo()).nexus

// Internal miner earns Nexus coinbase (aAddr needs Nexus + child balance).
await A.startMining(nexusDir)
await A.waitForHeight(3, nexusDir)
await A.stopMining(nexusDir)
await A.awaitQuiesced(nexusDir)

// Deploy child with premine to aAddr.
const childNode = await A.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  premine: 100, premineRecipient: aAddr,
})
net.add(childNode)

// Mine merged to get child chain started
const miner1 = new LatticeMiner(A, [childNode])
await miner1.start()
await childNode.waitForHeight(3, CHILD)
await miner1.stop()
await A.awaitQuiesced(nexusDir)

// C syncs A's Nexus genesis (standalone, no child)
C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000)
await C.readIdentity()
await waitFor(async () => (await peerCount(C)) >= 1, 'C-A sync', { timeoutMs: 30_000 })
await waitFor(async () => {
  const [at, ct] = await Promise.all([tipInfo(A), tipInfo(C)])
  return at?.tip && at.tip === ct?.tip ? ct : null
}, 'C synced A before partition', { timeoutMs: 60_000, intervalMs: 2000 })

console.log('\n[2] Partition: stop C, restart standalone...')
await stopAndAwaitShutdown(C)
await sleep(3000)
C.start(['--finality-confirmations', '999999'])
await C.waitForRPC(120_000)

console.log('\n[3] Deposit on child chain (A\'s partition)...')
const user = genKeypair()
const fundNonce = await childNode.nonce(aAddr, CHILD)
await childNode.submitTx({
  nonce: fundNonce, signers: [aAddr], fee: 1,
  accountActions: [
    { owner: aAddr, delta: -2001 },
    { owner: user.address, delta: 2000 },
  ],
}, CHILD, aKP)

const miner2 = new LatticeMiner(A, [childNode])
await miner2.start()
await waitFor(async () => (await childNode.balance(user.address, CHILD)) >= 2000,
  'user funded on child', { timeoutMs: 120_000 })
await miner2.stop()
await A.awaitQuiesced(nexusDir)

const swapNonce = Date.now().toString(16).padStart(32, '0').slice(-32)
const depNonce = await childNode.nonce(user.address, CHILD)
await childNode.submitTx({
  nonce: depNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: 500, amountDeposited: 500 }],
}, CHILD, user)

const miner3 = new LatticeMiner(A, [childNode])
await miner3.start()
await waitFor(async () => {
  const d = await childNode.getDeposit(user.address, 500, swapNonce, CHILD)
  return d.exists ? d : null
}, 'deposit visible on A', { timeoutMs: 60_000 })
await miner3.stop()
await A.awaitQuiesced(nexusDir)
console.log('  ✓ deposit confirmed on A\'s fork')

console.log('\n[4] Mine competing Nexus-only fork on C until it wins...')
const preTipA = await tipInfo(A)
const preTipC = await tipInfo(C)
console.log(`  pre-fork: A@${preTipA.height} C@${preTipC.height}`)

// A stays frozen with the child deposit. C mines a strictly longer parent fork
// without child blocks so the heal must reorg A onto C deterministically.
await C.startMining(nexusDir)
let postTipC = await waitFor(async () => {
  const [at, ct] = await Promise.all([tipInfo(A), tipInfo(C)])
  return at && ct && ct.height > at.height + 5 ? ct : null
}, 'C fork strictly longer than A', { timeoutMs: 120_000, intervalMs: 500 })
await C.stopMining(nexusDir)
await C.awaitQuiesced(nexusDir)

const postTipA = await tipInfo(A)
postTipC = await tipInfo(C)
console.log(`  pre-heal: A@${postTipA.height} C@${postTipC.height}`)

if (postTipA.tip === postTipC.tip) {
  console.error('  ✗ partitions not isolated — C did not build a competing fork')
  net.teardown(); await sleep(500); process.exit(1)
}
if (postTipC.height <= postTipA.height) {
  console.error(`  ✗ C fork did not become strictly longer: A@${postTipA.height} C@${postTipC.height}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  heavier chain: C tip=${postTipC.tip.slice(0, 12)}…`)

console.log('\n[5] Heal: restart C with --peer A (C wins)...')
await stopAndAwaitShutdown(C)
await sleep(500)
C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000)
await C.readIdentity()

await waitFor(async () => (await peerCount(C)) >= 1, 'A-C connected', { timeoutMs: 30_000 })

const finalTip = await waitFor(async () => {
  const [at, ct] = await Promise.all([tipInfo(A), tipInfo(C)])
  return at?.tip && at.tip === ct?.tip && at.tip === postTipC.tip ? at : null
}, 'A-C converged on C fork', { timeoutMs: 180_000, intervalMs: 3000 })
console.log(`  converged on C fork at height=${finalTip.height}`)

// Allow time for child chain state to fully reconcile after the reorg.
await sleep(5000)

console.log('\n[6] Check deposit state after reorg...')
const depPost = await childNode.getDeposit(user.address, 500, swapNonce, CHILD)
if (!depPost.exists) {
  console.error('  ✗ deposit lost after parent reorg')
  console.error('    Parent canonicity should not invalidate already-verified child state.')
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ deposit preserved (C won parent fork)`)

console.log('\n✓ cross-chain-reorg smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
