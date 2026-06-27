// Reorg mempool re-admission (no tx loss): a regular value-transfer tx mined on a
// fork that then loses a reorg must return to the mempool and re-mine on the new
// canonical chain — its effect must NOT silently vanish.
//
// orphaned-withdrawal-pending covers a cross-chain WITHDRAWAL returning to mempool;
// this covers the ordinary case (a plain account transfer) end-to-end.
//
// Isolation mirrors orphaned-withdrawal-pending's proven partition mechanism: C syncs a
// SHARED prefix (so sender S + funds exist on both forks), then C is taken DOWN, its
// persisted peers.json removed, and moved to a fresh fork port BEFORE A builds its fork —
// so C cannot sync A's fork (no saved peer to dial; A only knows C's old port). C then
// mines a heavier receipt-free fork in isolation; on heal (a third port + --peer A) A
// reorgs onto it, orphaning S→R. The tx must come back and re-mine.
//
// If re-admission is broken (recoverTransactionsFromReplacedCanonicalBlock), R's transfer
// is lost forever even though S's funds and nonce are intact on the winner.

import { rmSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, peers } from 'lattice-node-sdk'
import { sleep, waitFor, waitForProgress } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import { chainInfo, getNonce, getBalance, startMining, stopMining, awaitMiningQuiesced, tipInfo } from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('reorg-mempool-readmit')
const [a, cOrig, cFork, cHeal] = await allocPorts(4, { seed: 231 })

console.log('=== reorg-mempool-readmit smoke test ===')
const A = new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort })
const C = new LatticeNode({ name: 'C', dir: `${ROOT}/C`, port: cOrig.port, rpcPort: cOrig.rpcPort })
const net = new LatticeNetwork(); net.add(A); net.add(C); net.installSignalHandlers()
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }
async function stopAndAwaitShutdown(node, { timeoutMs = 30_000 } = {}) {
  await node.stop()
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try { await fetch(`${node.base}/api/chain/info`, { signal: AbortSignal.timeout(500) }) }
    catch { return }
    await sleep(500)
  }
  throw new Error(`${node.name} failed to shut down within ${timeoutMs}ms`)
}

A.start(['--finality-confirmations', '999999'])
await A.waitForRPC()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)
const nexusDir = (await chainInfo(A)).nexus

// [1] Shared prefix: A funds sender S; C syncs it; then C goes down (isolated).
console.log('\n[1] Build shared prefix: fund S, C syncs, then take C down isolated...')
await startMining(A, nexusDir); await waitFor(async () => ((await tipInfo(A))?.height ?? 0) >= 4 ? true : null, 'A mines coinbase', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const S = genKeypair()
const R = genKeypair()
const an = await getNonce(A, aAddr, nexusDir)
const fundRes = await submitTx(A, {
  chainPath: [nexusDir], nonce: an, signers: [aAddr], fee: 1,
  accountActions: [{ owner: aAddr, delta: -5001 }, { owner: S.address, delta: 5000 }],
}, nexusDir, aKP)
if (!fundRes.ok) fail(`fund S rejected: ${JSON.stringify(fundRes.submit)}`)
await startMining(A, nexusDir); await waitFor(async () => (await getBalance(A, S.address, nexusDir)) >= 5000 ? true : null, 'S funded on A', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const sharedTip = await tipInfo(A)
console.log(`  S funded (5000); shared prefix A@${sharedTip.height}`)

C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000); await C.readIdentity()
await waitFor(async () => {
  const ct = await tipInfo(C)
  return ct?.tip === sharedTip.tip && (await getBalance(C, S.address, nexusDir)) >= 5000 ? true : null
}, 'C synced shared prefix incl. S funding', { timeoutMs: 120_000, intervalMs: 1000 })
// Cut the split in BOTH directions. Clearing only C's peers.json is NOT enough: A
// re-dials C from its OWN discovered-peers store (and re-learns C's new port via the
// reconnect handshake), silently healing the partition. So take BOTH nodes down, clear
// BOTH peer stores, move C to a fork port, and restart A peerless — now neither node
// has any address for the other until the explicit heal.
await stopAndAwaitShutdown(C)
await stopAndAwaitShutdown(A)
// Both peer-persistence files must go: peers.json AND anchors.json (the router/
// rendezvous anchor set). Leaving anchors.json lets a node re-dial its anchor on
// restart, re-healing the split.
for (const n of [C, A]) for (const f of ['peers.json', 'anchors.json']) rmSync(`${n.dir}/${f}`, { force: true })
await sleep(500)
C.port = cFork.port; C.rpcPort = cFork.rpcPort
A.start(['--finality-confirmations', '999999'])
await A.waitForRPC(120_000)
console.log('  ✓ both isolated (peers.json + anchors.json cleared; A restarted peerless; C on fork port)')

// [2] A mines S→R into a block while C is down.
console.log('\n[2] A mines S→R (C is down)...')
const sNonce = await getNonce(A, S.address, nexusDir)
const spendRes = await submitTx(A, {
  chainPath: [nexusDir], nonce: sNonce, signers: [S.address], fee: 1,
  accountActions: [{ owner: S.address, delta: -1001 }, { owner: R.address, delta: 1000 }],
}, nexusDir, S)
if (!spendRes.ok) fail(`S→R rejected on A: ${JSON.stringify(spendRes.submit)}`)
await startMining(A, nexusDir); await waitFor(async () => (await getBalance(A, R.address, nexusDir)) >= 1000 ? true : null, 'S→R mined on A', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const aForkTip = await tipInfo(A)
console.log(`  S→R mined on A@${aForkTip.height}; R=${await getBalance(A, R.address, nexusDir)}`)

// [3] Bring C up isolated on its fork port; require it on the shared prefix (no leak),
// then mine a heavier receipt-free fork that does NOT contain S→R.
console.log('\n[3] C up isolated; mine a heavier fork without S→R...')
C.start(['--finality-confirmations', '999999'])
await C.waitForRPC(120_000)
const cBase = await waitFor(async () => {
  const t = await tipInfo(C)
  return t?.tip ? t : null
}, 'C restored base', { timeoutMs: 60_000, intervalMs: 500 })
if (cBase.tip !== sharedTip.tip) fail(`isolation leaked: C is on ${cBase.tip.slice(0,12)}@${cBase.height}, not the shared prefix @${sharedTip.height} — S→R would never be orphaned`)
if ((await getBalance(C, R.address, nexusDir)) !== 0) fail('isolation leaked: C already has S→R applied')
console.log(`  ✓ isolation held: C on shared prefix @${cBase.height}`)
await startMining(C, nexusDir)
await waitFor(async () => ((await tipInfo(C))?.height ?? 0) > aForkTip.height + 1 ? true : null, 'C heavier than A', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(C, nexusDir); await awaitMiningQuiesced(C, nexusDir)
const cForkTip = await tipInfo(C)
// Height is a valid proxy for work here only because the dev genesis is max-target and
// the retarget window is never reached in these short runs, so per-block difficulty is
// constant. Equal work HOLDS the incumbent, so C must be strictly taller to win the reorg.
if (cForkTip.height <= aForkTip.height) fail(`C(${cForkTip.height}) not heavier than A(${aForkTip.height})`)
console.log(`  C fork heavier: C@${cForkTip.height} vs A@${aForkTip.height}`)

// [4] Heal on a third port; A reorgs onto C, orphaning S→R.
console.log('\n[4] Heal; A reorgs onto C, orphaning S→R...')
await stopAndAwaitShutdown(C); await sleep(500)
C.port = cHeal.port; C.rpcPort = cHeal.rpcPort
C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000)
await waitForProgress(async () => C.height(nexusDir), (h) => h >= cForkTip.height, 'C restored fork provider', { stallMs: 60_000, intervalMs: 500 })
// Require A to actually admit C (not a half-open inbound) before expecting the reorg.
await waitFor(async () => {
  const [aPeers, at] = await Promise.all([peers(A).catch(() => []), tipInfo(A).catch(() => null)])
  const admitted = aPeers.filter((p) => !String(p.publicKey).startsWith('inbound-') && p.host !== 'unknown')
  return admitted.length >= 1 || at?.tip === cForkTip.tip ? true : null
}, 'A admitted C for fork sync', { timeoutMs: 90_000, intervalMs: 500 })
await waitFor(async () => (await tipInfo(A))?.tip === cForkTip.tip ? true : null, 'A reorged onto C', { timeoutMs: 120_000, intervalMs: 2000 })
console.log('  ✓ A reorged onto C (S→R orphaned)')

const reR = await waitFor(async () => { try { return { r: await getBalance(A, R.address, nexusDir) } } catch { return null } }, 'A serving post-reorg balances', { timeoutMs: 60_000, intervalMs: 1000 })
const mp = await A.rpc('GET', `/api/mempool?chainPath=${nexusDir}`)
console.log(`  post-reorg R=${reR.r} (expect 0 until re-mined); A mempool count=${mp.json?.count ?? 'n/a'}`)
// Explicit orphan proof: on the just-adopted C fork, S→R is gone (R back to 0). Without
// this the re-mine below could pass vacuously if S→R had somehow stayed canonical.
if (reR.r !== 0) fail(`S→R was NOT orphaned by the reorg (R=${reR.r}) — re-mine test would be vacuous`)

// [5] THE TEST: re-mining must re-include S→R — no tx loss.
console.log('\n[5] Re-mine; require S→R to re-mine on the canonical chain...')
await startMining(A, nexusDir)
await waitFor(async () => (await getBalance(A, R.address, nexusDir)) >= 1000 ? true : null, 'S→R re-mined on canonical chain', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const finalR = await getBalance(A, R.address, nexusDir)
const finalSNonce = await getNonce(A, S.address, nexusDir)
console.log(`  final R=${finalR}; S nonce=${finalSNonce}`)
if (finalR < 1000) fail(`S→R was LOST across the reorg (R=${finalR})`)
if (finalSNonce < 1) fail(`S nonce did not advance (tx not actually applied): ${finalSNonce}`)
await waitFor(async () => (await getBalance(C, R.address, nexusDir)) >= 1000 ? true : null, 'C sees re-mined S→R', { timeoutMs: 120_000, intervalMs: 1000 })
console.log('  ✓ orphaned regular tx returned to mempool and re-mined — no tx loss')

console.log('\n✓ reorg-mempool-readmit smoke test passed.')
net.teardown(); await sleep(500); process.exit(0)
