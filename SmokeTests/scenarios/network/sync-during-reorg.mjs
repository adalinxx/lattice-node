// Sync across a reorg: a late joiner that syncs one fork from its single peer must end on
// the canonical (heaviest) chain when that peer reorgs underneath it — never stuck on the
// abandoned fork, never corrupted.
//
// GUARANTEED property: C is peered to A ONLY, so the heavier fork Y (mined independently
// by P from genesis) can reach C SOLELY by A adopting it and re-serving it — C following
// A's reorg from X to Y. C must converge to Y and serve Y's funded-user state. This holds
// for any interleaving, so the test is robust rather than timing-flaky.
//
// OPPORTUNISTIC: X is mined long (≥30 blocks) and the reorg is triggered right as C joins,
// so on a slower box C may still be backfilling X when A's tip flips — additionally
// exercising a headers-first sync against a mid-flight tip change. On fast loopback C may
// finish X first; either way the end-state assertion is the same and sound.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import { chainInfo, getNonce, getBalance, startMining, stopMining, awaitMiningQuiesced, tipInfo } from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('sync-during-reorg')
const [a, p, c] = await allocPorts(3, { seed: 251 })

console.log('=== sync-during-reorg smoke test ===')
const net = Network.fresh({ root: ROOT, nodes: [
  { name: 'A', port: a.port, rpcPort: a.rpcPort },
  { name: 'P', port: p.port, rpcPort: p.rpcPort },
  { name: 'C', port: c.port, rpcPort: c.rpcPort },
] })
const A = net.byName('A'), P = net.byName('P'), C = net.byName('C')
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }

A.start(); await A.waitForRPC(); await A.readIdentity()
const nexusDir = (await chainInfo(A)).nexus

// [1] A mines fork X — a longer chain so C's backfill has a chance to still be in flight
// when the reorg lands (the mid-sync overlap is opportunistic on fast loopback).
console.log('\n[1] A mines fork X...')
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(A))?.height ?? 0) >= 30 ? true : null, 'A fork X', { timeoutMs: 120_000, intervalMs: 500 })
await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const xTip = await tipInfo(A)
console.log(`  A fork X @${xTip.height} (${xTip.tip.slice(0, 12)}…)`)

// [2] P (independent, from genesis) mines a strictly heavier fork Y; fund userY on it.
console.log('\n[2] P mines a heavier fork Y (with funded userY)...')
P.start(); await P.waitForRPC()
const pIdent = await P.readIdentity()
const pKP = { privateKey: pIdent.privateKey, publicKey: pIdent.publicKey }
const pAddr = computeAddress(pIdent.publicKey)
const userY = genKeypair()
await startMining(P, nexusDir)
await waitFor(async () => ((await tipInfo(P))?.height ?? 0) > xTip.height + 4 ? true : null, 'P taller than X', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(P, nexusDir); await awaitMiningQuiesced(P, nexusDir)
const pn = await getNonce(P, pAddr, nexusDir)
const fundY = await submitTx(P, { chainPath: [nexusDir], nonce: pn, signers: [pAddr], fee: 1, accountActions: [{ owner: pAddr, delta: -1001 }, { owner: userY.address, delta: 1000 }] }, nexusDir, pKP)
if (!fundY.ok) fail(`fund userY on P rejected: ${JSON.stringify(fundY.submit)}`)
// Mine until userY is actually funded on Y (not a fixed sleep) so yTip is captured with
// the funded state — otherwise a missed inclusion would surface later as a misleading
// "C didn't adopt Y" failure.
await startMining(P, nexusDir)
await waitFor(async () => (await getBalance(P, userY.address, nexusDir)) >= 1000 ? true : null, 'userY funded on Y', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(P, nexusDir); await awaitMiningQuiesced(P, nexusDir)
const yTip = await tipInfo(P)
if (yTip.tip === xTip.tip) fail('forks X and Y are not distinct')
if (yTip.height <= xTip.height) fail(`Y(${yTip.height}) not heavier than X(${xTip.height})`)
console.log(`  P fork Y @${yTip.height} (${yTip.tip.slice(0, 12)}…) heavier; userY funded`)

// [3] THE TEST: C joins peered to A ONLY (so it can reach Y solely by following A's
// reorg, never directly from P), starts syncing A's fork X, then P heals → A reorgs to Y.
console.log('\n[3] C joins (syncs fork X, peered to A only) while P heals → A reorgs to Y...')
C.start({ peers: [A] })
await C.waitForRPC()
// Trigger the reorg right as C begins syncing, to overlap sync with the tip flip.
await P.stopAndAwaitShutdown(); await sleep(300)
P.start({ peers: [A] })
await P.waitForRPC()

const converged = await waitFor(async () => {
  const [at, pt, ct] = await Promise.all([tipInfo(A), tipInfo(P), tipInfo(C)])
  return at?.tip === yTip.tip && pt?.tip === yTip.tip && ct?.tip === yTip.tip ? { at, ct } : null
}, 'A, P, C all converge on heavier fork Y', { timeoutMs: 300_000, intervalMs: 3000 })
console.log(`  ✓ all converged on Y @${converged.at.height}`)

// [4] C (the late joiner that synced through the reorg) must serve Y's state consistently.
console.log('\n[4] Verify C serves the reorged state consistently...')
const cState = await waitFor(async () => {
  try {
    const t = await tipInfo(C)
    if (t?.tip !== yTip.tip) return null
    const uy = await getBalance(C, userY.address, nexusDir)
    return { t, uy }
  } catch { return null }
}, 'C serving Y state', { timeoutMs: 60_000, intervalMs: 1000 })
if (cState.t.tip !== yTip.tip) fail(`C not on Y (tip ${cState.t.tip.slice(0, 12)})`)
if (cState.uy < 1000) fail(`C did not adopt Y's funded state (userY=${cState.uy}) — stuck on abandoned fork X?`)
console.log(`  ✓ C on Y @${cState.t.height}, userY=${cState.uy}`)

// [5] The converged chain still advances from C's view (recovered tip is live).
console.log('\n[5] Verify the converged chain advances...')
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(C))?.height ?? 0) > converged.at.height ? true : null, 'C sees chain advance past Y', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(A, nexusDir)
console.log('  ✓ converged chain advances')

console.log('\n✓ sync-during-reorg smoke test passed.')
net.teardown(); await sleep(500); process.exit(0)
