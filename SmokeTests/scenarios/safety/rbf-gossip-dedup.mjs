// Gap 5b: RBF replacement gossip within the 60s deduplication window.
//
// ChainNetwork deduplicates gossiped transactions by CID for 60 seconds.
// An RBF replacement has a DIFFERENT body (higher fee) → different CID,
// so the dedup window should NOT suppress it. This test verifies that a
// valid fee-bumped replacement propagates to a second node even when both
// the original and replacement are gossiped within the 60-second window.
//
// If dedup incorrectly uses a key other than CID (e.g. sender nonce), the
// replacement would be suppressed and the second node would only see the
// original low-fee transaction.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor, genKeypair, computeAddress } from 'lattice-node-sdk'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('rbf-gossip-dedup')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, bPorts] = await allocPorts(2)

console.log('=== rbf-gossip-dedup smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

A.start()
await A.waitForRPC()
await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus
const minerIdent = await A.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()

// Mine some blocks on A to fund the miner.
await A.startMining(nexusDir)
await A.waitForHeight(4, nexusDir, { timeoutMs: 60_000 })
await A.stopMining(nexusDir)
await A.awaitQuiesced(nexusDir)

// Fund the user.
const fundNonce = await A.nonce(minerAddr, nexusDir)
const fundResult = await A.submitTx({
  chainPath: [nexusDir], nonce: fundNonce, signers: [minerAddr], fee: 1,
  accountActions: [{ owner: minerAddr, delta: -5001 }, { owner: user.address, delta: 5000 }],
}, nexusDir, minerKP)
if (!fundResult.ok) throw new Error(`fund failed: ${JSON.stringify(fundResult)}`)
await A.startMining(nexusDir)
await waitFor(async () => (await A.balance(user.address, nexusDir)) >= 5000, 'user funded', { timeoutMs: 30_000 })
await A.stopMining(nexusDir)
await A.awaitQuiesced(nexusDir)
console.log(`  User funded: ${await A.balance(user.address, nexusDir)}`)

// Connect B to A.
B.start(['--peer', A.peerArg()])
await B.waitForRPC()
await waitFor(async () => {
  const ah = await A.height(nexusDir)
  const bh = await B.height(nexusDir)
  return ah > 0 && bh >= ah ? bh : null
}, 'B synced', { timeoutMs: 30_000, intervalMs: 500 })
await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? { A: ap, B: bp } : null
}, 'A/B peers connected after sync', { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  B synced to A (height ${await B.height(nexusDir)})`)

// Pause mining so txs stay in mempool.
const userNonce = await A.nonce(user.address, nexusDir)

// ── [1] Submit original tx (low fee = 1) ──────────────────────────────────
console.log('\n[1] Submit original tx (fee=1), verify B gossips it...')
const originalResult = await A.submitTx({
  chainPath: [nexusDir], nonce: userNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -2 }, { owner: minerAddr, delta: 1 }],
}, nexusDir, user)
if (!originalResult.ok) throw new Error(`original tx failed: ${JSON.stringify(originalResult)}`)
const originalCID = originalResult.txCID ?? originalResult.bodyCID ?? originalResult.cid ?? 'unknown'
console.log(`  Original submitted (fee=1) cid=${String(originalCID).slice(0, 20)}…`)

// Wait for B to gossip the original tx.
const originalMempoolB = await waitFor(async () => {
  const r = await B.rpc('GET', `/api/mempool?chainPath=${nexusDir}`)
  return r.json?.count === 1 && r.json?.totalFees === 1 ? r.json : null
}, 'B received original tx', { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  ✓ B received original tx (count=${originalMempoolB.count} totalFees=${originalMempoolB.totalFees})`)

// ── [2] Submit RBF replacement (higher fee = 5) ────────────────────────────
// This has the SAME nonce/sender but higher fee → different CID.
// The 60-second dedup window must NOT block this replacement.
console.log('\n[2] Submit RBF replacement (fee=5, same nonce) within 60s window...')
const rbfResult = await A.submitTx({
  chainPath: [nexusDir], nonce: userNonce, signers: [user.address], fee: 5,
  accountActions: [{ owner: user.address, delta: -6 }, { owner: minerAddr, delta: 1 }],
}, nexusDir, user)
console.log(`  RBF result: ok=${rbfResult.ok} ${JSON.stringify(rbfResult).slice(0, 60)}`)

if (!rbfResult.ok) {
  console.error(`  ✗ FAIL: RBF replacement rejected: ${JSON.stringify(rbfResult)}`)
  net.teardown(); process.exit(1)
}

// ── [3] Verify B sees the replacement, not the original ───────────────────
console.log('\n[3] Verify B sees the RBF replacement propagated...')
const replacementMempoolB = await waitFor(async () => {
  const r = await B.rpc('GET', `/api/mempool?chainPath=${nexusDir}`)
  return r.json?.count === 1 && r.json?.totalFees === 5 ? r.json : null
}, 'B received RBF replacement tx', { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  ✓ B mempool replaced original (count=${replacementMempoolB.count} totalFees=${replacementMempoolB.totalFees})`)

// Mine on B. If gossip dedup suppressed the replacement, B would mine the
// original fee=1 body and the balance would be 4998 instead of 4994.
const bStartHeight = await B.height(nexusDir)
await B.startMining(nexusDir)
await B.waitForHeight(bStartHeight + 1, nexusDir, { timeoutMs: 30_000 })
await B.stopMining(nexusDir)
await B.awaitQuiesced(nexusDir)

const userBalB = await B.balance(user.address, nexusDir)
console.log(`  User balance on B: ${userBalB} (started with 5000)`)
if (userBalB !== 4994) {
  console.error(`  ✗ FAIL: expected replacement balance 4994; got ${userBalB}`)
  net.teardown(); process.exit(1)
}
console.log(`  ✓ RBF replacement tx (fee=5, delta=-6) was mined on B`)

console.log('\n✓ rbf-gossip-dedup passed.')
net.teardown()
await sleep(500)
process.exit(0)
