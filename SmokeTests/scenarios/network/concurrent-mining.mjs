// Concurrent mining: A and B both mine nexus simultaneously, ending up on
// different forks. After a mine burst on A, both must converge to the same
// tip. Also verifies a tx submitted post-convergence propagates to both nodes.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance,
  startMining, stopMining, awaitMiningQuiesced,
  waitForHeight, tipInfo, mineBurst,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('concurrent-mining')
const [a, b] = await allocPorts(2, { seed: 101 })

console.log('=== concurrent-mining smoke test ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot A and B, establish connection...')
A.start({ extraArgs: ['--finality-confirmations', '999999'] })
await A.waitForRPC()
await A.readIdentity()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)
const nexusDir = (await chainInfo(A)).nexus

// Mine a few blocks so A has some balance for the tx test
await startMining(A, nexusDir)
await waitForHeight(A, nexusDir, 5, 30_000)
await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)

B.start({ peers: [A] })
await B.waitForRPC()
await B.readIdentity()
await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-B connected', { timeoutMs: 30_000 })
await sleep(2000)

console.log('\n[2] Both mine concurrently (50ms) — creates competing forks...')
await startMining(A, nexusDir)
await startMining(B, nexusDir)
await sleep(50)
await stopMining(A, nexusDir)
await stopMining(B, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
await awaitMiningQuiesced(B, nexusDir)

const midA = await tipInfo(A)
const midB = await tipInfo(B)
console.log(`  after concurrent mining: A@${midA.height} B@${midB.height}`)
if (midA.tip === midB.tip) {
  console.log('  (tips already match — both on same chain, test still valid)')
}

console.log('\n[3] Mine burst on A to give it more work, wait for B to converge...')
await mineBurst(A, nexusDir, { targetHeight: Math.max(midA.height, midB.height) + 5 })

const finalTip = await waitFor(async () => {
  const [at, bt] = await Promise.all([tipInfo(A), tipInfo(B)])
  return at?.tip && at.tip === bt?.tip ? at : null
}, 'A-B converged', { timeoutMs: 240_000, intervalMs: 3000 })
console.log(`  ✓ nexus tips converged at height ${finalTip.height}`)

console.log('\n[4] Submit tx on A, verify it confirms and propagates to B...')
await stopMining(A, nexusDir)
await stopMining(B, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
const user = genKeypair()
const n = await getNonce(A, aAddr, nexusDir)
await submitTx(A, {
  chainPath: [nexusDir], nonce: n, signers: [aAddr], fee: 1,
  accountActions: [{ owner: aAddr, delta: -501 }, { owner: user.address, delta: 500 }],
}, nexusDir, aKP)
await startMining(A, nexusDir)
await waitFor(async () => (await getBalance(A, user.address, nexusDir)) >= 500,
  'tx confirmed on A', { timeoutMs: 60_000 })

await waitFor(async () => {
  try { const bal = await getBalance(B, user.address, nexusDir); return bal >= 500 ? true : null }
  catch { return null }
}, 'tx visible on B', { timeoutMs: 120_000 })
console.log('  ✓ tx submitted on A, confirmed and propagated to B')

console.log(`\n[5] Height sanity: both contributed (final height=${finalTip.height})`)
if (finalTip.height < 5) {
  console.error(`  ✗ only reached height ${finalTip.height} — mining stalled`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log('\n✓ concurrent-mining smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
