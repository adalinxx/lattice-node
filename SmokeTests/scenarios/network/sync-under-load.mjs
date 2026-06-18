// Sync under load: a node joins a network where transactions are actively
// being submitted and confirmed during the sync window. Verifies that:
//   1. The syncing node correctly applies all state changes.
//   2. No transactions are lost or double-counted.
//   3. Balances are consistent between the source and synced node.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  waitForHeight, awaitMiningQuiesced, tipInfo,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('sync-under-load')
const [a, b] = await allocPorts(2, { seed: 213 })

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('=== sync-under-load smoke test ===')

A.start()
await A.waitForRPC()

const info = await chainInfo(A)
const nexus = info.nexus
const minerIdent = await A.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const { computeAddress } = await import('../../lib/wallet.mjs')
const minerAddr = computeAddress(minerIdent.publicKey)

// Build initial chain and user
console.log('\n[1] Build initial chain with funded users...')
await startMining(A, nexus)
await waitForHeight(A, nexus, 30, 30_000)

const alice = genKeypair()
const bob = genKeypair()
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)

const confirmedBase = await getNonce(A, minerAddr, nexus)
let nonceOff = 0
for (const [user, amount] of [[alice, 50000], [bob, 50000]]) {
  const r = await submitTx(A, {
    chainPath: [nexus], nonce: confirmedBase + nonceOff, signers: [minerAddr], fee: 1,
    accountActions: [{ owner: minerAddr, delta: -(amount + 1) }, { owner: user.address, delta: amount }],
  }, nexus, minerKP)
  if (!r.ok) throw new Error(`fund failed: ${JSON.stringify(r.submit)}`)
  nonceOff++
}

await startMining(A, nexus)
await waitFor(async () => (await getBalance(A, alice.address, nexus)) >= 50000, 'alice funded', { timeoutMs: 30_000 })
await waitFor(async () => (await getBalance(A, bob.address, nexus)) >= 50000, 'bob funded', { timeoutMs: 30_000 })
console.log('  ✓ alice and bob funded')

// Submit txs while B is joining
console.log('\n[2] Submit transactions while B joins the network...')
await A.readIdentity()
B.start({ peers: [A] })
await B.waitForRPC()

// Submit several alice→bob txs to create ongoing state changes
let txCount = 0
for (let i = 0; i < 5; i++) {
  const nonce = await getNonce(A, alice.address, nexus)
  const r = await submitTx(A, {
    chainPath: [nexus], nonce, signers: [alice.address], fee: 1,
    accountActions: [{ owner: alice.address, delta: -101 }, { owner: bob.address, delta: 100 }],
  }, nexus, alice)
  if (r.ok) txCount++
  await sleep(200)
}
console.log(`  submitted ${txCount} txs during B's sync`)

// Stop mining and freeze state
await sleep(3000)
await stopMining(A, nexus)
await sleep(2000)
const frozenTip = await tipInfo(A)
const aliceBalA = await getBalance(A, alice.address, nexus)
const bobBalA = await getBalance(A, bob.address, nexus)
console.log(`  A frozen at height=${frozenTip.height} alice=${aliceBalA} bob=${bobBalA}`)

// Wait for B to converge
console.log('\n[3] Wait for B to converge and verify balances match...')
await waitFor(async () => {
  const bt = await tipInfo(B)
  return bt?.tip === frozenTip.tip ? bt : null
}, 'B converged', { timeoutMs: 120_000, intervalMs: 2000 })

const syncedBalances = await waitFor(async () => {
  try {
    const aliceBalB = await getBalance(B, alice.address, nexus)
    const bobBalB = await getBalance(B, bob.address, nexus)
    return aliceBalB === aliceBalA && bobBalB === bobBalA
      ? { aliceBalB, bobBalB }
      : null
  } catch {
    return null
  }
}, 'B balances readable and matching', { timeoutMs: 30_000, intervalMs: 500 })
const { aliceBalB, bobBalB } = syncedBalances
console.log(`  B: alice=${aliceBalB} bob=${bobBalB}`)

if (aliceBalA !== aliceBalB) throw new Error(`Alice balance mismatch: A=${aliceBalA} B=${aliceBalB}`)
if (bobBalA !== bobBalB) throw new Error(`Bob balance mismatch: A=${bobBalA} B=${bobBalB}`)
console.log('  ✓ Balances match between A and B after sync-under-load')

console.log('\n✓ sync-under-load smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
