// Reorg mempool eviction (no wrong re-admission): a tx that becomes INVALID after a
// reorg must be evicted, not silently re-mined. Specifically a nonce conflict: sender S
// spends nonce N on the losing fork (S→R_A) and ALSO nonce N on the winning fork (S→R_C).
// After A reorgs onto C, S's nonce N is consumed by S→R_C, so the orphaned S→R_A is
// permanently stale — it must NEVER re-mine, or R_A would receive funds S never authorized
// on the canonical chain (a double-spend / replay of S's nonce).
//
// Complements reorg-mempool-readmit (an orphaned tx that IS still valid re-mines). This is
// the must-NOT case: re-admission must respect the post-reorg nonce/state.
//
// Isolation mirrors orphaned-withdrawal-pending: C syncs a shared prefix (S funded, nonce N
// on both forks), is taken down with peers.json cleared + a fork port before A builds its
// fork, then mines a heavier fork containing its OWN S→R_C @nonce N in isolation. On heal A
// reorgs onto C; S→R_A is orphaned with its nonce already consumed.

import { rmSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, peers } from 'lattice-node-sdk'
import { sleep, waitFor, waitForProgress } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import { chainInfo, getNonce, getBalance, startMining, stopMining, awaitMiningQuiesced, tipInfo } from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('reorg-mempool-nonce-evict')
const [a, cOrig, cFork, cHeal] = await allocPorts(4, { seed: 233 })

console.log('=== reorg-mempool-nonce-evict smoke test ===')
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

// [1] Shared prefix: fund S; C syncs it; C down + isolated (peers cleared, fork port).
console.log('\n[1] Build shared prefix: fund S, C syncs, take C down isolated...')
await startMining(A, nexusDir); await waitFor(async () => ((await tipInfo(A))?.height ?? 0) >= 4 ? true : null, 'A mines coinbase', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const S = genKeypair()
const R_A = genKeypair()
const R_C = genKeypair()
const an = await getNonce(A, aAddr, nexusDir)
const fundRes = await submitTx(A, {
  chainPath: [nexusDir], nonce: an, signers: [aAddr], fee: 1,
  accountActions: [{ owner: aAddr, delta: -5001 }, { owner: S.address, delta: 5000 }],
}, nexusDir, aKP)
if (!fundRes.ok) fail(`fund S rejected: ${JSON.stringify(fundRes.submit)}`)
await startMining(A, nexusDir); await waitFor(async () => (await getBalance(A, S.address, nexusDir)) >= 5000 ? true : null, 'S funded on A', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const sharedTip = await tipInfo(A)
const N = await getNonce(A, S.address, nexusDir)
console.log(`  S funded (5000) at nonce ${N}; shared prefix A@${sharedTip.height}`)

C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000); await C.readIdentity()
await waitFor(async () => {
  const ct = await tipInfo(C)
  return ct?.tip === sharedTip.tip && (await getBalance(C, S.address, nexusDir)) >= 5000 ? true : null
}, 'C synced shared prefix incl. S funding', { timeoutMs: 120_000, intervalMs: 1000 })
// Cut the split in BOTH directions. Clearing only C's peers.json is NOT enough: A
// re-dials C from its OWN discovered-peers store (re-learning C's new port via the
// reconnect handshake), silently healing the partition. So take BOTH nodes down, clear
// BOTH peer stores, move C to a fork port, and restart A peerless.
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

// [2] A mines S→R_A @nonce N (the loser) while C is down.
console.log('\n[2] A mines S→R_A @nonce N (C is down)...')
const txA = await submitTx(A, {
  chainPath: [nexusDir], nonce: N, signers: [S.address], fee: 1,
  accountActions: [{ owner: S.address, delta: -1001 }, { owner: R_A.address, delta: 1000 }],
}, nexusDir, S)
if (!txA.ok) fail(`S→R_A rejected on A: ${JSON.stringify(txA.submit)}`)
await startMining(A, nexusDir); await waitFor(async () => (await getBalance(A, R_A.address, nexusDir)) >= 1000 ? true : null, 'S→R_A mined on A', { timeoutMs: 60_000, intervalMs: 500 }); await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const aForkTip = await tipInfo(A)
console.log(`  S→R_A mined on A@${aForkTip.height}`)

// [3] C up isolated; require shared prefix + S nonce N (no leak); spend S→R_C @nonce N;
// mine a heavier fork.
console.log('\n[3] C up isolated; S→R_C @nonce N; mine heavier fork...')
C.start(['--finality-confirmations', '999999'])
await C.waitForRPC(120_000)
const cBase = await waitFor(async () => { const t = await tipInfo(C); return t?.tip ? t : null }, 'C restored base', { timeoutMs: 60_000, intervalMs: 500 })
const cNonceForS = await getNonce(C, S.address, nexusDir)
if (cBase.tip !== sharedTip.tip) fail(`isolation leaked: C on ${cBase.tip.slice(0,12)}@${cBase.height}, not shared @${sharedTip.height}`)
if (cNonceForS !== N) fail(`isolation leaked: C's S nonce is ${cNonceForS}, expected N=${N}`)
console.log(`  ✓ isolation held: C on shared prefix @${cBase.height}, S nonce ${cNonceForS}`)
const txC = await submitTx(C, {
  chainPath: [nexusDir], nonce: N, signers: [S.address], fee: 1,
  accountActions: [{ owner: S.address, delta: -2001 }, { owner: R_C.address, delta: 2000 }],
}, nexusDir, S)
if (!txC.ok) fail(`S→R_C rejected on C: ${JSON.stringify(txC.submit)}`)
await startMining(C, nexusDir)
await waitFor(async () => (await getBalance(C, R_C.address, nexusDir)) >= 2000 && ((await tipInfo(C))?.height ?? 0) > aForkTip.height + 1 ? true : null, 'S→R_C mined + C heavier', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(C, nexusDir); await awaitMiningQuiesced(C, nexusDir)
const cForkTip = await tipInfo(C)
if (cForkTip.height <= aForkTip.height) fail(`C(${cForkTip.height}) not heavier than A(${aForkTip.height})`)
console.log(`  A@${aForkTip.height} (R_A=1000) vs heavier C@${cForkTip.height} (R_C=2000)`)

// [4] Heal on a third port; A reorgs onto C.
console.log('\n[4] Heal; A reorgs onto C (S→R_A nonce now consumed by S→R_C)...')
await stopAndAwaitShutdown(C); await sleep(500)
C.port = cHeal.port; C.rpcPort = cHeal.rpcPort
C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC(120_000)
await waitForProgress(async () => C.height(nexusDir), (h) => h >= cForkTip.height, 'C restored fork provider', { stallMs: 60_000, intervalMs: 500 })
await waitFor(async () => {
  const [aPeers, at] = await Promise.all([peers(A).catch(() => []), tipInfo(A).catch(() => null)])
  const admitted = aPeers.filter((p) => !String(p.publicKey).startsWith('inbound-') && p.host !== 'unknown')
  return admitted.length >= 1 || at?.tip === cForkTip.tip ? true : null
}, 'A admitted C for fork sync', { timeoutMs: 90_000, intervalMs: 500 })
await waitFor(async () => (await tipInfo(A))?.tip === cForkTip.tip ? true : null, 'A reorged onto C', { timeoutMs: 120_000, intervalMs: 2000 })
console.log('  ✓ A reorged onto C')

// [5] THE TEST: re-mine, then require S→R_A EVICTED (never re-mined) and S→R_C canonical.
console.log('\n[5] Re-mine; require S→R_A evicted (stale nonce), S→R_C canonical...')
const postReorgTip = await waitFor(async () => { const t = await tipInfo(A); return t?.tip ? t : null }, 'A tip after reorg', { timeoutMs: 60_000, intervalMs: 1000 })
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(A))?.height ?? 0) >= postReorgTip.height + 3 ? true : null, 'A mines several more blocks', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const balRA = await getBalance(A, R_A.address, nexusDir)
const balRC = await getBalance(A, R_C.address, nexusDir)
const sNonceFinal = await getNonce(A, S.address, nexusDir)
console.log(`  final: R_A=${balRA} (must be 0) R_C=${balRC} (must be 2000); S nonce=${sNonceFinal}`)
if (balRC < 2000) fail(`winning-fork tx S→R_C did not stand (R_C=${balRC})`)
if (balRA !== 0) fail(`stale orphaned tx S→R_A WRONGLY re-mined (R_A=${balRA}) — double-spent S's nonce`)
if (sNonceFinal !== N + 1) fail(`S nonce should be exactly N+1 after one consuming tx; got ${sNonceFinal} (N=${N})`)
await waitFor(async () => (await getBalance(C, R_C.address, nexusDir)) >= 2000 && (await getBalance(C, R_A.address, nexusDir)) === 0 ? true : null, 'C agrees R_C=2000, R_A=0', { timeoutMs: 120_000, intervalMs: 1000 })
console.log('  ✓ stale orphaned tx evicted, winning-fork tx canonical, nonce consumed once')

console.log('\n✓ reorg-mempool-nonce-evict smoke test passed.')
net.teardown(); await sleep(500); process.exit(0)
