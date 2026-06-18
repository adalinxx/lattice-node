// 5-node full-mesh convergence. Boots 5 nodes with overlapping peer connections
// forming a mesh, mines on one, and asserts all 5 converge to the same tip.
// Validates that gossip propagation and sync work across a realistic network
// with multiple hops — a single node may only know 2-3 peers directly.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { startMining, stopMining, tipInfo, mineBurst } from 'lattice-node-sdk/chain'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('mesh-convergence')
const ports = await allocPorts(5, { seed: 201 })
const [a, b, c, d, e] = ports

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
    { name: 'C', port: c.port, rpcPort: c.rpcPort },
    { name: 'D', port: d.port, rpcPort: d.rpcPort },
    { name: 'E', port: e.port, rpcPort: e.rpcPort },
  ],
})

const A = net.byName('A')
const B = net.byName('B')
const C = net.byName('C')
const D = net.byName('D')
const E = net.byName('E')

console.log('=== 5-node mesh convergence smoke test ===')
console.log('\n[1] Boot A (miner), then B-E in a mesh...')
A.start()
await A.waitForRPC()
await A.readIdentity()

// Partial mesh: A-B-C, B-D, C-E — requires multi-hop for A-D and A-E
B.start({ peers: [A] })
C.start({ peers: [A] })
await Promise.all([B.waitForRPC(), C.waitForRPC()])
await Promise.all([B.readIdentity(), C.readIdentity()])
D.start({ peers: [B] })
E.start({ peers: [C] })
await Promise.all([B.waitForRPC(), C.waitForRPC(), D.waitForRPC(), E.waitForRPC()])

console.log('\n[2] Wait for mesh to form...')
await waitFor(async () => {
  const [pa, pb, pc, pd, pe] = await Promise.all([
    peerCount(A), peerCount(B), peerCount(C), peerCount(D), peerCount(E),
  ])
  return pa >= 2 && pb >= 2 && pc >= 2 && pd >= 1 && pe >= 1 ? true : null
}, 'mesh connected', { timeoutMs: 30_000 })

const [pa, pb, pc, pd, pe] = await Promise.all([
  peerCount(A), peerCount(B), peerCount(C), peerCount(D), peerCount(E),
])
console.log(`  peers: A=${pa} B=${pb} C=${pc} D=${pd} E=${pe}`)

console.log('\n[3] Mine 10 blocks on A...')
const info = await A.rpc('GET', '/api/chain/info')
const nexus = info.json.nexus
const tip = await mineBurst(A, nexus, { targetHeight: 10 })
console.log(`  A mined to height=${tip.height}`)

console.log('\n[4] Wait for all 5 nodes to converge (up to 120s)...')
await waitFor(async () => {
  const tips = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C), tipInfo(D), tipInfo(E)])
  const [tA, tB, tC, tD, tE] = tips
  if (tA?.height) process.stdout.write(`\r  A@${tA?.height} B@${tB?.height} C@${tC?.height} D@${tD?.height} E@${tE?.height}   `)
  const allMatch = tA?.tip && tA.tip === tB?.tip && tA.tip === tC?.tip && tA.tip === tD?.tip && tA.tip === tE?.tip
  return allMatch ? tA : null
}, 'all 5 nodes converged', { timeoutMs: 120_000, intervalMs: 2000 })

const final = await tipInfo(A)
console.log(`\n  ✓ all 5 nodes converged at height=${final.height}`)
console.log('✓ mesh-convergence smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
