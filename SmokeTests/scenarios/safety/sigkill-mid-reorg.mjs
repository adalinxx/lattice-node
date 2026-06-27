// SIGKILL during a reorg: a node hard-killed WHILE adopting a heavier fork must
// recover to a CONSISTENT state — never a corrupted tip/state mismatch.
//
// Existing crash coverage (crash-mid-prune) kills mid-MINING/mid-PRUNING. This
// kills mid-REORG: the per-block tip-apply and the multi-block segment commit are
// two separate transactions, so a crash between them can leave block_index out of
// sync with the committed tip. recoverFromCAS + reconcileBlockIndex are the repair
// path; this asserts it end-to-end.
//
// The recovery assertions (tip block resolvable, state served, converges with the
// network's heavier fork, balances agree, chain advances) hold no matter exactly
// when the SIGKILL lands relative to the reorg, so the test is robust, not timing-
// flaky; the mid-reorg window is the target, any kill timing still tests crash
// recovery during an active sync.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, tipInfo,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('sigkill-mid-reorg')
const [a, b, c] = await allocPorts(3, { seed: 223 })

console.log('=== sigkill-mid-reorg smoke test ===')
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

// [1] Build two isolated forks: A short, C clearly heavier (taller). Fund userC on C.
console.log('\n[1] Partition-mine: A short fork, C heavier fork...')
await startMining(A, nexusDir); await sleep(2500); await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
const aTip = await tipInfo(A)

const userC = genKeypair()
await startMining(C, nexusDir)
await waitFor(async () => ((await tipInfo(C))?.height ?? 0) > aTip.height + 4 ? true : null,
  'C well taller than A', { timeoutMs: 60_000, intervalMs: 500 })
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
if (aTip.tip === cTip.tip) fail('partitions not isolated')
if (cTip.height <= aTip.height) fail(`C (${cTip.height}) not heavier than A (${aTip.height})`)

// [2] Heal so A begins reorging onto C's heavier fork, then SIGKILL A mid-reorg.
console.log('\n[2] Connect C→A to trigger the reorg, then SIGKILL A mid-reorg...')
await C.stopAndAwaitShutdown(); await sleep(500)
C.start({ peers: [A, B] })
await C.waitForRPC()
// Give A just enough time to discover C's heavier tip and start fetching/applying
// the fork, then hard-kill it inside that window.
await sleep(450)
const pid = A.pid
if (!pid) fail('A not running before kill')
try { process.kill(pid, 'SIGKILL') } catch {}
await waitFor(async () => {
  try { await fetch(`${A.base}/api/chain/info`, { signal: AbortSignal.timeout(500) }); return null }
  catch { return true }
}, 'A RPC down after SIGKILL', { timeoutMs: 30_000, intervalMs: 300 })
A.proc = null
await stopMining(A, nexusDir)
console.log('  ✓ A hard-killed mid-reorg, RPC down')

// [3] Restart A on the same data-dir; require a CONSISTENT recovery.
console.log('\n[3] Restart A; assert consistent crash recovery...')
A.start({ peers: [B, C] })
await A.waitForRPC(300_000)
console.log('  ✓ RPC back up after crash')

// Internal consistency: A's reported tip must be a resolvable block whose state A
// can serve (no tip/state-root mismatch from a half-applied reorg). Poll past the
// brief fail-closed rebuild window.
const recovered = await waitFor(async () => {
  try {
    const t = await tipInfo(A)
    if (!t?.tip || t.height < 1) return null
    const blk = await A.rpc('GET', `/api/block/${t.height}?chainPath=${nexusDir}`)
    if (!blk.ok || !blk.json) return null
    // state must be serveable at the recovered tip
    await getBalance(A, aAddr, nexusDir)
    return t
  } catch { return null }
}, 'A serving a consistent tip+state after crash', { timeoutMs: 120_000, intervalMs: 1000 })
console.log(`  ✓ A recovered to a consistent tip A@${recovered.height} (${recovered.tip.slice(0, 12)}…)`)

// Network consistency: A must converge with the heavier fork (C) and agree on state.
const finalTip = await waitFor(async () => {
  const [at, bt, ct] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  return at?.tip && at.tip === bt?.tip && at.tip === ct?.tip ? at : null
}, 'three-node convergence after crash recovery', { timeoutMs: 300_000, intervalMs: 3000 })
if (finalTip.tip !== cTip.tip) fail(`converged on ${finalTip.tip.slice(0, 12)}…, not C's heavier fork`)
console.log(`  ✓ converged on the heavier fork at height=${finalTip.height}`)

const bals = await waitFor(async () => {
  try {
    const [ua, ub, uc] = await Promise.all([
      getBalance(A, userC.address, nexusDir),
      getBalance(B, userC.address, nexusDir),
      getBalance(C, userC.address, nexusDir),
    ])
    return { ua, ub, uc }
  } catch { return null }
}, 'all nodes serving userC balance', { timeoutMs: 60_000, intervalMs: 1000 })
console.log(`  userC: A=${bals.ua} B=${bals.ub} C=${bals.uc}`)
if (!(bals.ua === bals.ub && bals.ub === bals.uc)) fail(`balances disagree after recovery: ${JSON.stringify(bals)}`)
if (bals.ua < 1000) fail(`recovered chain lost userC's funded state: ${bals.ua}`)
console.log('  ✓ state consistent across all nodes after crash recovery')

// Liveness: the recovered+converged chain still advances.
console.log('\n[4] Verify the recovered chain advances...')
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(A))?.height ?? 0) > finalTip.height ? true : null,
  'A advances past the recovered/converged tip', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(A, nexusDir)
console.log('  ✓ recovered chain advances')

console.log('\n✓ sigkill-mid-reorg smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
