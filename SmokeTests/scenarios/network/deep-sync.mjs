// Deep sync: a fresh node joins a chain that is far past the gossip threshold.
// Validates that headers-first sync + state peer-binding works at scale —
// the joining node must converge correctly despite a large gap, and must
// be able to validate new gossip blocks immediately after sync completes.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { startMining, stopMining, tipInfo, awaitMiningQuiesced } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('deep-sync')
const [a, b] = await allocPorts(2, { seed: 205 })

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('=== deep-sync smoke test ===')

console.log('\n[1] Build a deep chain on A...')
A.start()
await A.waitForRPC()

const info = await A.rpc('GET', '/api/chain/info')
const nexus = info.json.nexus
await startMining(A, nexus)

const TARGET = 64
await waitFor(async () => {
  const t = await tipInfo(A)
  if (t?.height) process.stdout.write(`\r  A mining: height=${t.height}   `)
  return t && t.height >= TARGET ? t : null
}, `A reaches height ${TARGET}`, { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)

const frozenTip = await tipInfo(A)
console.log(`\n  A frozen at height=${frozenTip.height} tip=${frozenTip.tip.slice(0, 20)}...`)

console.log(`\n[2] Fresh node B joins with a ${TARGET}+ block gap...`)
await A.readIdentity()
B.start({ peers: [A] })
await B.waitForRPC()

console.log('\n[3] Wait for B to sync and converge (up to 120s)...')
const start = Date.now()
await waitFor(async () => {
  const bt = await tipInfo(B)
  if (bt?.height) process.stdout.write(`\r  B syncing: height=${bt.height}   `)
  return bt?.tip === frozenTip.tip ? bt : null
}, 'B converged', { timeoutMs: 120_000, intervalMs: 1000 })

const elapsed = ((Date.now() - start) / 1000).toFixed(1)
const bTip = await tipInfo(B)
console.log(`\n  ✓ B converged at height=${bTip.height} in ${elapsed}s`)

console.log('\n[4] Mine 5 more blocks on A — B must validate via gossip...')
await startMining(A, nexus)
await waitFor(async () => {
  const t = await tipInfo(A)
  return t && t.height >= frozenTip.height + 5 ? t : null
}, 'A mines 5 more', { timeoutMs: 30_000 })
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)
const postTip = await tipInfo(A)

await waitFor(async () => {
  const bt = await tipInfo(B)
  return bt?.tip === postTip.tip ? bt : null
}, 'B converged on post-sync blocks', { timeoutMs: 60_000, intervalMs: 1000 })

const bFinal = await tipInfo(B)
console.log(`  ✓ B validated post-sync gossip blocks, now at height=${bFinal.height}`)
console.log('\n✓ deep-sync smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
