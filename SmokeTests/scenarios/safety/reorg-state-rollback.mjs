// Reorg state rollback: uses the partition.mjs pattern (A+B vs C) but adds
// state assertions. A mines and funds userA during the partition window, C
// mines and funds userC. After heal, the winning side's user keeps their
// balance; the losing side's state is rolled back.

import { readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, tipInfo,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('reorg-state-rollback')
const [a, b, c] = await allocPorts(3, { seed: 63 })
const PARTITION_MS = 5_000

console.log('=== reorg-state-rollback smoke test ===')
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

A.start()
await A.waitForRPC()
await A.readIdentity()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)

B.start({ peers: [A] })
C.start()
await B.waitForRPC()
await B.readIdentity()
await C.waitForRPC()
await C.readIdentity()
const cIdent = await C.readIdentity()
const cKP = { privateKey: cIdent.privateKey, publicKey: cIdent.publicKey }
const cAddr = computeAddress(cIdent.publicKey)

const infoA = await chainInfo(A)
const nexusDir = infoA.nexus

console.log(`\n[1] Mine in two partitions ({A,B} and {C})...`)
await startMining(A, nexusDir)
await startMining(C, nexusDir)
await sleep(PARTITION_MS)
await stopMining(A, nexusDir)
await sleep(2000)
await stopMining(C, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
await awaitMiningQuiesced(C, nexusDir)

console.log(`\n[2] Fund users on each partition...`)
const userA = genKeypair()
const userC = genKeypair()

const an = await getNonce(A, aAddr, nexusDir)
await submitTx(A, {
  chainPath: [nexusDir], nonce: an, signers: [aAddr], fee: 1,
  accountActions: [{ owner: aAddr, delta: -1001 }, { owner: userA.address, delta: 1000 }],
}, nexusDir, aKP)

const cn = await getNonce(C, cAddr, nexusDir)
await submitTx(C, {
  chainPath: [nexusDir], nonce: cn, signers: [cAddr], fee: 1,
  accountActions: [{ owner: cAddr, delta: -1001 }, { owner: userC.address, delta: 1000 }],
}, nexusDir, cKP)

await startMining(A, nexusDir)
await startMining(C, nexusDir)
await sleep(2000)
await stopMining(A, nexusDir)
await stopMining(C, nexusDir)
await sleep(2000)

const aTip = await tipInfo(A)
const cTip = await tipInfo(C)
console.log(`  A@${aTip.height} C@${cTip.height}`)

const balUA = await getBalance(A, userA.address, nexusDir)
const balUC = await getBalance(C, userC.address, nexusDir)
console.log(`  userA on A: ${balUA}, userC on C: ${balUC}`)

if (aTip.tip === cTip.tip) {
  console.error(`  ✗ partitions not isolated`); net.teardown(); process.exit(1)
}
const maxPre = Math.max(aTip.height, cTip.height)
const expectedWinner = aTip.height >= cTip.height ? 'A' : 'C'
console.log(`  heaviest chain by height: ${expectedWinner} (${maxPre})`)

console.log(`\n[3] Heal: restart C with --peer A,B...`)
await C.stopAndAwaitShutdown()
await sleep(500)
C.start({ peers: [A, B] })
await C.waitForRPC()

const finalTip = await waitFor(async () => {
  const [at, bt, ct] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  return at?.tip && at.tip === bt?.tip && at.tip === ct?.tip ? at : null
}, 'three-node convergence', { timeoutMs: 300_000, intervalMs: 3000 })
console.log(`  converged at height=${finalTip.height}`)

let winner = null
if (finalTip.tip === aTip.tip) winner = 'A'
if (finalTip.tip === cTip.tip) winner = 'C'
if (!winner) {
  console.error(`  ✗ converged tip ${finalTip.tip.slice(0, 16)} did not match either pre-heal fork`)
  net.teardown(); process.exit(1)
}
console.log(`  winning fork after heal: ${winner}`)

console.log(`\n[4] Verify state across all nodes...`)
// Tip convergence (above) only proves the nodes AGREE on the winning hash. A node
// that just reorged onto the heavier fork can still be briefly fail-closed
// ("Chain Nexus is unavailable") while it rebuilds/serves that state — querying
// balance in that window throws. Gate the assertions on every node actually
// SERVING balances: poll all six reads until none throw, so we assert against a
// settled chain rather than racing the reorg. A node stuck fail-closed (genuine
// failure) makes this time out instead of flaking on a transient.
const { balUA_A, balUA_B, balUC_A, balUC_B, balUA_C, balUC_C } = await waitFor(async () => {
  try {
    const [a1, b1, a2, b2, c1, c2] = await Promise.all([
      getBalance(A, userA.address, nexusDir),
      getBalance(B, userA.address, nexusDir),
      getBalance(A, userC.address, nexusDir),
      getBalance(B, userC.address, nexusDir),
      getBalance(C, userA.address, nexusDir),
      getBalance(C, userC.address, nexusDir),
    ])
    return { balUA_A: a1, balUA_B: b1, balUC_A: a2, balUC_B: b2, balUA_C: c1, balUC_C: c2 }
  } catch {
    return null
  }
}, 'all nodes serving Nexus balances after heal', { timeoutMs: 60_000, intervalMs: 1_000 })

console.log(`  userA: A=${balUA_A} B=${balUA_B} C=${balUA_C}`)
console.log(`  userC: A=${balUC_A} B=${balUC_B} C=${balUC_C}`)

function assertAllEqual(label, balances) {
  const values = Object.values(balances)
  if (!values.every(v => v === values[0])) {
    console.error(`  ✗ ${label} balance differs across converged nodes: ${JSON.stringify(balances)}`)
    net.teardown(); process.exit(1)
  }
  console.log(`  ✓ ${label} consistent across nodes (${values[0]})`)
}

assertAllEqual('userA', { A: balUA_A, B: balUA_B, C: balUA_C })
assertAllEqual('userC', { A: balUC_A, B: balUC_B, C: balUC_C })

if (winner === 'A') {
  if (balUA_A < 1000) {
    console.error(`  ✗ userA was on the winning fork but lost balance`)
    net.teardown(); process.exit(1)
  }
  if (balUC_A !== 0) {
    console.error(`  ✗ userC was on the losing fork but balance survived: ${balUC_A}`)
    net.teardown(); process.exit(1)
  }
  console.log(`  ✓ A-side state won: userA=${balUA_A}, userC rolled back`)
} else {
  if (balUC_A < 1000) {
    console.error(`  ✗ userC was on the winning fork but lost balance`)
    net.teardown(); process.exit(1)
  }
  if (balUA_A !== 0) {
    console.error(`  ✗ userA was on the losing fork but balance survived: ${balUA_A}`)
    net.teardown(); process.exit(1)
  }
  console.log(`  ✓ C-side state won: userC=${balUC_A}, userA rolled back`)
}

console.log(`\n✓ reorg-state-rollback smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
