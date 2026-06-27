// Reorg durability across a graceful restart: a node that reorged onto a heavier
// fork must RECOVER on that reorged tip after a restart — never regress to its
// abandoned pre-reorg fork, and never lose the reorged state.
//
// Builds on reorg-state-rollback's partition idiom (A+B vs C) but adds the piece
// no existing smoke covers: a graceful RESTART of the node AFTER it reorged. This
// exercises end-to-end the restart-recovery invariants hardened this cycle —
//   * the multi-block reorg's durable canonical-tip commit (publishCanonicalTransition),
//   * graceful stop() draining in-flight processing before persisting the tip, and
//   * recoverFromCAS projecting the in-memory tip to the durable committed tip —
// i.e. "a block that became the canonical tip via a reorg survives a restart."
//
// (The strictly heavier-but-SHORTER lower-height promotion path is covered at unit
// level by AtomicApplyRecoveryTests; reproducing it e2e needs flaky difficulty
// asymmetry. This asserts the durability path with a reliable taller-heavier reorg.)
//
// If durability is broken, the restarted node comes back on its old fork (or a
// regressed/empty tip) and the reorged user's balance is gone.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, tipInfo,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('reorg-restart-durability')
const [a, b, c] = await allocPorts(3, { seed: 211 })

console.log('=== reorg-restart-durability smoke test ===')
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

function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }

A.start()
await A.waitForRPC()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)

B.start({ peers: [A] })
C.start()
await B.waitForRPC(); await B.readIdentity()
await C.waitForRPC()
const cIdent = await C.readIdentity()
const cKP = { privateKey: cIdent.privateKey, publicKey: cIdent.publicKey }
const cAddr = computeAddress(cIdent.publicKey)

const nexusDir = (await chainInfo(A)).nexus

// [1] Partition: {A,B} mine a short fork; {C} mines a strictly heavier (taller) fork.
console.log('\n[1] Partition-mine: A+B short fork, C heavier fork...')
const userA = genKeypair()
const userC = genKeypair()

await startMining(A, nexusDir)
await sleep(3000)
await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
const an = await getNonce(A, aAddr, nexusDir)
await submitTx(A, {
  chainPath: [nexusDir], nonce: an, signers: [aAddr], fee: 1,
  accountActions: [{ owner: aAddr, delta: -1001 }, { owner: userA.address, delta: 1000 }],
}, nexusDir, aKP)
await startMining(A, nexusDir); await sleep(1500); await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
const aTip = await tipInfo(A)

// C mines past A's height, then funds userC on its fork, then keeps mining so it
// is unambiguously heavier (more blocks == more work at the shared genesis target).
await startMining(C, nexusDir)
await waitFor(async () => ((await tipInfo(C))?.height ?? 0) > aTip.height + 2 ? true : null,
  'C taller than A', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(C, nexusDir); await awaitMiningQuiesced(C, nexusDir)
const cn = await getNonce(C, cAddr, nexusDir)
await submitTx(C, {
  chainPath: [nexusDir], nonce: cn, signers: [cAddr], fee: 1,
  accountActions: [{ owner: cAddr, delta: -1001 }, { owner: userC.address, delta: 1000 }],
}, nexusDir, cKP)
await startMining(C, nexusDir); await sleep(1500); await stopMining(C, nexusDir)
await awaitMiningQuiesced(C, nexusDir)
const cTip = await tipInfo(C)
console.log(`  A@${aTip.height} (${aTip.tip.slice(0, 12)}…)  C@${cTip.height} (${cTip.tip.slice(0, 12)}…)`)
if (aTip.tip === cTip.tip) fail('partitions not isolated (same tip)')
if (cTip.height <= aTip.height) fail(`C (${cTip.height}) is not heavier than A (${aTip.height})`)

// [2] Heal: A+B reorg onto C's heavier fork.
console.log('\n[2] Heal: A connects to C and reorgs onto the heavier fork...')
await C.stopAndAwaitShutdown(); await sleep(500)
C.start({ peers: [A, B] })
await C.waitForRPC()
const converged = await waitFor(async () => {
  const [at, bt, ct] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  return at?.tip && at.tip === bt?.tip && at.tip === ct?.tip ? at : null
}, 'three-node convergence on heavier fork', { timeoutMs: 300_000, intervalMs: 3000 })
if (converged.tip !== cTip.tip) fail(`converged on ${converged.tip.slice(0, 12)}…, not C's fork ${cTip.tip.slice(0, 12)}…`)
console.log(`  ✓ A reorged onto C's fork: height=${converged.height}`)

// Confirm A actually adopted C-fork state before the restart (poll past the brief
// fail-closed window a node can show while it rebuilds the just-reorged state).
const preBal = await waitFor(async () => {
  try {
    const [uc, ua] = await Promise.all([
      getBalance(A, userC.address, nexusDir), getBalance(A, userA.address, nexusDir),
    ])
    return { uc, ua }
  } catch { return null }
}, 'A serving reorged balances', { timeoutMs: 60_000, intervalMs: 1000 })
if (preBal.uc < 1000) fail(`A did not adopt C-fork state before restart (userC=${preBal.uc})`)
if (preBal.ua !== 0) fail(`A did not roll back its own fork (userA=${preBal.ua})`)
console.log(`  pre-restart on A: userC=${preBal.uc} userA=${preBal.ua}`)

// [3] THE TEST: gracefully restart A and require it to recover ON the reorged tip.
console.log('\n[3] Gracefully restart A; require recovery on the reorged tip...')
await A.stopAndAwaitShutdown(); await sleep(800)
A.start({ peers: [B, C] })
await A.waitForRPC(300_000)

const post = await waitFor(async () => {
  try {
    const t = await tipInfo(A)
    const uc = await getBalance(A, userC.address, nexusDir)
    const ua = await getBalance(A, userA.address, nexusDir)
    return t?.tip ? { t, uc, ua } : null
  } catch { return null }
}, 'A serving chain state after restart', { timeoutMs: 120_000, intervalMs: 1000 })
console.log(`  post-restart A@${post.t.height} (${post.t.tip.slice(0, 12)}…) userC=${post.uc} userA=${post.ua}`)

// Durability assertions — the heart of this test.
if (post.t.height < converged.height) fail(`height REGRESSED across restart: ${converged.height} -> ${post.t.height}`)
if (post.t.tip === aTip.tip) fail('restart RESURRECTED the abandoned pre-reorg fork')
if (post.t.tip !== converged.tip) fail(`restart landed on ${post.t.tip.slice(0, 12)}…, not the reorged tip ${converged.tip.slice(0, 12)}…`)
if (post.uc < 1000) fail(`reorged state LOST across restart (userC=${post.uc})`)
if (post.ua !== 0) fail(`abandoned-fork state RESURRECTED across restart (userA=${post.ua})`)
console.log('  ✓ restarted node recovered exactly on the reorged tip, no regression, state intact')

// [4] And it keeps building from there (the recovered tip is a live, mineable head).
console.log('\n[4] Verify the recovered chain still advances...')
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(A))?.height ?? 0) > post.t.height ? true : null,
  'A advances past the recovered tip', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(A, nexusDir)
console.log('  ✓ recovered chain advances')

console.log('\n✓ reorg-restart-durability smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
