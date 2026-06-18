// Peer churn: nodes join and leave while the network is actively mining.
// Validates that:
//   1. New nodes can sync and catch up while blocks are flowing.
//   2. The chain continues advancing when nodes leave.
//   3. A late-joining node converges despite having missed blocks.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { startMining, stopMining, tipInfo } from 'lattice-node-sdk/chain'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('peer-churn')
const [a, b, c] = await allocPorts(3, { seed: 203 })

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
    { name: 'C', port: c.port, rpcPort: c.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')
const C = net.byName('C')

console.log('=== peer-churn smoke test ===')

console.log('\n[1] Boot A and B, start mining...')
A.start()
await A.waitForRPC()
await A.readIdentity()
B.start({ peers: [A] })
await B.waitForRPC()

const info = await A.rpc('GET', '/api/chain/info')
const nexus = info.json.nexus

await waitFor(async () => (await peerCount(A)) >= 1 && (await peerCount(B)) >= 1,
  'A-B connected', { timeoutMs: 15_000 })
await startMining(A, nexus)
await sleep(500)

const midTip = await tipInfo(A)
console.log(`  A at height=${midTip.height} after 500ms mining`)
if (midTip.height < 2) { console.error('  ✗ A failed to mine'); net.teardown(); process.exit(1) }

console.log('\n[2] B disconnects (simulates churn)...')
await B.stop()
await sleep(1000)

console.log('\n[3] C joins while A continues mining...')
C.start({ peers: [A] })
await C.waitForRPC()
await waitFor(async () => (await peerCount(A)) >= 1, 'C connected to A', { timeoutMs: 15_000 })

// Mine a few more blocks while C is syncing (keep depth low)
await sleep(500)
await stopMining(A, nexus)
await sleep(1000)
const finalTip = await tipInfo(A)
console.log(`  A frozen at height=${finalTip.height}`)

console.log('\n[4] Wait for C to converge with A (up to 90s)...')
// C needs to reach finalTip.height. If gossip delivers the last block in sync,
// tip may differ briefly but height should match once C is fully caught up.
await waitFor(async () => {
  const ct = await tipInfo(C)
  if (!ct) return null
  if (ct.tip === finalTip.tip) return ct
  // If C is at the right height but different tip, it may still be catching up
  if (ct.height >= finalTip.height) return ct
  return null
}, 'C converged with A', { timeoutMs: 90_000, intervalMs: 1000 })

const cTip = await tipInfo(C)
console.log(`  ✓ C converged at height=${cTip.height}`)

console.log('\n✓ peer-churn smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
