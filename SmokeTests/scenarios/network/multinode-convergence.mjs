// Three-node mesh: A mines, B and C bootstrap from A and must converge to A's
// tip after mining stops. Validates merged-mining + gossip follow-up routing.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { tipInfo, mineBurst } from 'lattice-node-sdk/chain'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('multinode')
const [a, b, c] = await allocPorts(3, { seed: 31 })

console.log('=== multi-node mesh smoke test ===')
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

console.log('\n[1] Boot node A (will mine)...')
A.start()
await A.waitForRPC()
const aIdent = await A.readIdentity()
console.log(`  A pubkey: ${aIdent.publicKey.slice(0, 32)}...`)

console.log(`\n[2] Boot B and C with --peer <A>...`)
B.start({ peers: [A] })
C.start({ peers: [A] })
await B.waitForRPC()
await C.waitForRPC()

console.log('  waiting for all peers to connect...')
await waitFor(async () => {
  const [a, b, c] = await Promise.all([peerCount(A), peerCount(B), peerCount(C)])
  return a >= 2 && b >= 1 && c >= 1 ? true : null
}, 'all peers connected', { timeoutMs: 30_000 })

console.log('\n[3] Checking peer connectivity...')
const peers = [await peerCount(A), await peerCount(B), await peerCount(C)]
console.log(`  peer counts: A=${peers[0]} B=${peers[1]} C=${peers[2]}`)

console.log('\n[4] Confirming peer counts stay connected...')
const peers2 = await waitFor(async () => {
  const counts = [await peerCount(A), await peerCount(B), await peerCount(C)]
  return counts[0] >= 2 && counts[1] >= 1 && counts[2] >= 1 ? counts : null
}, 'peer counts still connected', { timeoutMs: 10_000, intervalMs: 500 })
console.log(`  peer counts after settle: A=${peers2[0]} B=${peers2[1]} C=${peers2[2]}`)

console.log('\n[5] Start mining on A...')
const aTip = await mineBurst(A, 'Nexus')
if (!aTip) { console.error('  ✗ A tip unavailable after mining'); net.teardown(); process.exit(1) }
console.log(`  ✓ mining stopped; A tip height=${aTip.height}`)
if (aTip.height < 2) {
  console.error('  ✗ A failed to mine any blocks'); net.teardown(); process.exit(1)
}

console.log('\n[5] Checking for convergence (up to 60s)...')
await waitFor(async () => {
  const [aT, bT, cT] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  if (aT?.height) process.stdout.write(`\r  A@${aT.height} B@${bT?.height ?? '?'} C@${cT?.height ?? '?'}   `)
  return aT?.tip && aT.tip === bT?.tip && aT.tip === cT?.tip ? aT : null
}, 'three-node mesh converged', { timeoutMs: 180_000, intervalMs: 2000 })

const finalTip = await tipInfo(A)
console.log(`  ✓ converged at height=${finalTip.height} tip=${finalTip.tip.slice(0, 20)}...`)
console.log('\n✓ three-node mesh smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
