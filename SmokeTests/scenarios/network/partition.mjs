// Network partition: A+B mutually peered, C standalone (forms its own
// partition from genesis). Both A and C mine, then heal by restarting C with
// --peer A,B. Asserts:
//   - A and C diverge during the partition window.
//   - All three converge after heal.
//   - Final height ≥ max pre-heal height (heaviest-chain rule).
//   - At least one miner's tip changed (reorg fired).

import { readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import {
  startMining, stopMining, tipInfo, waitForHeight,
  awaitMiningQuiesced, getNonce, getBalance,
} from 'lattice-node-sdk/chain'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('partition')
const [a, b, c] = await allocPorts(3, { seed: 41 })

console.log('=== partition smoke (3 nodes, two partitions, heal & converge) ===')
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
const SEND_A = 111
const SEND_C = 222

console.log('\n[1] Boot A (alone)...')
A.start()
await A.waitForRPC()
await A.readIdentity()

console.log(`\n[2] Boot B peered to A; boot C standalone (partition)...`)
B.start({ peers: [A] })
C.start()
await B.waitForRPC()
await C.waitForRPC()
await B.readIdentity()
const cIdent = await C.readIdentity()

console.log(`\n[3] Mine in two partitions ({A,B} and {C}), with a spend on each side...`)
const ax = await tipInfo(A)
await startMining(A, ax.nexus)
await startMining(C, ax.nexus)
await Promise.all([
  waitForHeight(A, ax.nexus, 3, 60_000),
  waitForHeight(C, ax.nexus, 3, 60_000),
])
await stopMining(A, ax.nexus)
await stopMining(C, ax.nexus)
await Promise.all([
  awaitMiningQuiesced(A, ax.nexus),
  awaitMiningQuiesced(C, ax.nexus),
])

const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const cKP = { privateKey: cIdent.privateKey, publicKey: cIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)
const cAddr = computeAddress(cIdent.publicKey)
const aRecipient = genKeypair()
const cRecipient = genKeypair()
const aNonce = await getNonce(A, aAddr, ax.nexus)
const cNonce = await getNonce(C, cAddr, ax.nexus)

const aTx = await submitTx(A, {
  chainPath: [ax.nexus], nonce: aNonce, signers: [aAddr], fee: 1,
  accountActions: [
    { owner: aAddr, delta: -(SEND_A + 1) },
    { owner: aRecipient.address, delta: SEND_A },
  ],
}, ax.nexus, aKP)
if (!aTx.ok) throw new Error(`partition A tx rejected: ${JSON.stringify(aTx.submit)}`)
const cTx = await submitTx(C, {
  chainPath: [ax.nexus], nonce: cNonce, signers: [cAddr], fee: 1,
  accountActions: [
    { owner: cAddr, delta: -(SEND_C + 1) },
    { owner: cRecipient.address, delta: SEND_C },
  ],
}, ax.nexus, cKP)
if (!cTx.ok) throw new Error(`partition C tx rejected: ${JSON.stringify(cTx.submit)}`)

await startMining(A, ax.nexus)
await startMining(C, ax.nexus)
await waitFor(async () => {
  const [aBal, cBal] = await Promise.all([
    getBalance(A, aRecipient.address, ax.nexus),
    getBalance(C, cRecipient.address, ax.nexus),
  ])
  return aBal === SEND_A && cBal === SEND_C ? true : null
}, 'both partition-local spends mined', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(A, ax.nexus)
const aFrozen = await tipInfo(A)
console.log(`  A stopped at height ${aFrozen.height}; let C become strictly heavier...`)
await waitFor(async () => {
  const t = await tipInfo(C)
  return t && t.height >= aFrozen.height + 2 ? t : null
}, 'C strictly heavier than A', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(C, ax.nexus)
await Promise.all([
  awaitMiningQuiesced(A, ax.nexus),
  awaitMiningQuiesced(C, ax.nexus),
])

const preA = await tipInfo(A)
const preB = await tipInfo(B)
const preC = await tipInfo(C)
if (!preA || !preB || !preC) { console.error('  ✗ node tip unavailable'); net.teardown(); process.exit(1) }
console.log(`  pre-heal: A=${preA.height}/${preA.tip.slice(0, 16)} B=${preB.height}/${preB.tip.slice(0, 16)} C=${preC.height}/${preC.tip.slice(0, 16)}`)

if (preA.tip === preC.tip) {
  console.error(`  ✗ A and C share a tip — partition didn't isolate.`)
  net.teardown(); await sleep(500); process.exit(1)
}
const maxPre = Math.max(preA.height, preC.height)
console.log(`  partition isolated. Heaviest pre-heal: ${preA.height >= preC.height ? '{A,B}' : '{C}'}@${maxPre}`)
if (preC.height <= preA.height) {
  console.error(`  ✗ C did not become the winning partition: A=${preA.height} C=${preC.height}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`\n[4] Heal: restart C and stale follower B with fresh peers...`)
await Promise.all([
  C.stopAndAwaitShutdown(),
  B.stopAndAwaitShutdown(),
])
await sleep(500)
C.start({ peers: [A] })
await C.waitForRPC()
B.start({ peers: [A, C] })
await B.waitForRPC()

console.log(`\n[5] Waiting for full-mesh convergence (up to 120s)...`)
const finalTip = await waitFor(async () => {
  const [aT, bT, cT] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  return aT?.tip && aT.tip === bT?.tip && aT.tip === cT?.tip ? aT : null
}, 'three-node converged after heal', { timeoutMs: 120_000, intervalMs: 1000 })

console.log(`  ✓ converged at height=${finalTip.height} tip=${finalTip.tip.slice(0, 20)}...`)

if (finalTip.height < maxPre) {
  console.error(`  ✗ converged at height ${finalTip.height} but max pre-heal was ${maxPre} — heaviest-chain rule violated`)
  net.teardown(); await sleep(500); process.exit(1)
}

const reorgedSides = []
if (preA.tip !== finalTip.tip) reorgedSides.push('A')
if (preC.tip !== finalTip.tip) reorgedSides.push('C')
if (reorgedSides.length === 0) {
  console.error(`  ✗ neither miner's tip changed — partition may not have produced divergent chains`)
  net.teardown(); await sleep(500); process.exit(1)
}

let reorgLogSeen = false
for (const side of reorgedSides) {
  try {
    const log = readFileSync(`${ROOT}/${side}.log`, 'utf8')
    if (/\bReorg:\s/.test(log) || /\[reorg\]/i.test(log)) { reorgLogSeen = true; break }
  } catch {}
}
console.log(`  reorg observed on: ${reorgedSides.join(', ')} (log signal: ${reorgLogSeen ? 'yes' : 'tip-swap only'})`)

const [finalLoseA, finalWinA, finalLoseB, finalWinB, finalLoseC, finalWinC] = await Promise.all([
  getBalance(A, aRecipient.address, ax.nexus),
  getBalance(A, cRecipient.address, ax.nexus),
  getBalance(B, aRecipient.address, ax.nexus),
  getBalance(B, cRecipient.address, ax.nexus),
  getBalance(C, aRecipient.address, ax.nexus),
  getBalance(C, cRecipient.address, ax.nexus),
])
if (finalWinA !== SEND_C || finalWinB !== SEND_C || finalWinC !== SEND_C) {
  console.error(`  ✗ winning-side tx did not survive convergence: A=${finalWinA} B=${finalWinB} C=${finalWinC}`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (finalLoseA !== 0 || finalLoseB !== 0 || finalLoseC !== 0) {
  console.error(`  ✗ losing-side tx leaked after reorg: A=${finalLoseA} B=${finalLoseB} C=${finalLoseC}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ winning-side tx survived and losing-side tx disappeared after convergence`)

console.log(`\n✓ partition smoke test passed (final height ${finalTip.height}, max pre-heal ${maxPre}).`)
net.teardown()
await sleep(500)
process.exit(0)
