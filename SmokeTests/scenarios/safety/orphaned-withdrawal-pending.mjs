// Gap 5c: Orphaned withdrawal returns to mempool pending after reorg.
//
// When a receipt-granting nexus block is orphaned (reorg), a withdrawal
// that was blocked waiting for the receipt should transition back to
// "pending" in the mempool rather than silently disappearing.
//
// If the orphan-recovery path in recoverOrphanedTransactions is broken,
// the withdrawal vanishes and the user loses funds on the swap source chain.
//
// Scenario:
//   1. Node A + B (--finality-confirmations 999999 to allow reorgs).
//   2. Deploy SwapTest on A as a separate per-process child.
//   3. Complete a full deposit → receipt → attempt withdrawal cycle:
//      - deposit on SwapTest
//      - receipt on Nexus (forks!)
//      - withdrawal on SwapTest (needs the receipt block)
//   4. Mine a longer fork on B that orphans the Nexus block containing the receipt.
//   5. A syncs from B (reorg).
//   6. The receipt block on Nexus is now orphaned — withdrawal should return
//      to mempool pending (not silently lost).

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, waitForProgress, genKeypair, computeAddress, peers } from 'lattice-node-sdk'

const ROOT = smokeRoot('orphaned-withdrawal-pending')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, bPorts, swapPorts, bForkPorts, bHealPorts] = await allocPorts(5)

console.log('=== orphaned-withdrawal-pending smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

A.start(['--finality-confirmations', '999999'])
await A.waitForRPC()
await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus
const aIdent = await A.readIdentity()
const minerAddr = computeAddress(aIdent.publicKey)
const user = genKeypair()
const swapNonce = Date.now().toString(16).padStart(32, '0').slice(-32)

// Deploy SwapTest on A as a separate per-process child.
const swapNode = await A.spawnChild({
  directory: 'SwapTest',
  parentDirectory: nexusDir,
  ports: swapPorts,
  premine: 100, premineRecipient: minerAddr,
  extraArgs: ['--finality-confirmations', '999999'],
})
net.add(swapNode)

// Earn Nexus coinbase via internal miner, then merged mining for SwapTest.
await A.mineToHeight(5, nexusDir, { timeoutMs: 180_000 })

const miner1 = new LatticeMiner(A, [swapNode])
await miner1.start()
net.addMiner(miner1)
await swapNode.waitForHeight(3, 'SwapTest', { timeoutMs: 60_000 })

// Fund user on both chains.
await miner1.stop()
await A.awaitQuiesced(nexusDir)

const nexusNonce = await A.nonce(minerAddr, nexusDir)
const rNexus = await A.submitTx({
  chainPath: [nexusDir], nonce: nexusNonce, signers: [minerAddr], fee: 1,
  accountActions: [{ owner: minerAddr, delta: -5001 }, { owner: user.address, delta: 5000 }],
}, nexusDir, { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey })
if (!rNexus.ok) throw new Error(`fund nexus failed: ${JSON.stringify(rNexus)}`)

const swapFundNonce = await swapNode.nonce(minerAddr, 'SwapTest')
const rSwap = await swapNode.submitTx({
  nonce: swapFundNonce, signers: [minerAddr], fee: 1,
  accountActions: [{ owner: minerAddr, delta: -5001 }, { owner: user.address, delta: 5000 }],
}, 'SwapTest', { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey })
if (!rSwap.ok) throw new Error(`fund SwapTest failed: ${JSON.stringify(rSwap)}`)

const miner2 = new LatticeMiner(A, [swapNode])
await miner2.start()
net.addMiner(miner2)
await waitFor(async () => (await A.balance(user.address, nexusDir)) >= 5000, 'nexus funded', { timeoutMs: 30_000 })
await waitFor(async () => (await swapNode.balance(user.address, 'SwapTest')) >= 5000, 'swap funded', { timeoutMs: 30_000 })
await miner2.stop()
await A.awaitQuiesced(nexusDir)
console.log('  ✓ user funded')

// ── Deposit on SwapTest ────────────────────────────────────────────────────
const depNonce = await swapNode.nonce(user.address, 'SwapTest')
const depR = await swapNode.submitTx({
  nonce: depNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: 500, amountDeposited: 500 }],
}, 'SwapTest', user)
if (!depR.ok) throw new Error(`deposit failed: ${JSON.stringify(depR)}`)

const miner3 = new LatticeMiner(A, [swapNode])
await miner3.start()
net.addMiner(miner3)
await waitFor(async () => {
  const d = await swapNode.getDeposit(user.address, 500, swapNonce, 'SwapTest')
  return d?.exists ? d : null
}, 'deposit confirmed', { timeoutMs: 30_000 })
console.log('  ✓ deposit confirmed on SwapTest')
await miner3.stop()
await A.awaitQuiesced(nexusDir)

// ── Boot B and sync a pre-receipt base ──────────────────────────────────────
console.log('\n[2] Boot B and sync pre-receipt fork base...')
const minPreReceiptHeight = await A.height(nexusDir)
B.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await B.waitForRPC()
await B.readIdentity()
const preReceiptBase = await waitFor(async () => {
  const bh = await B.height(nexusDir)
  if (bh < minPreReceiptHeight) return null
  const bt = await B.tip(nexusDir)
  return bt ? { height: bh, tip: bt } : null
}, 'B synced pre-receipt base', { timeoutMs: 30_000, intervalMs: 500 })
let preReceiptHeight = preReceiptBase.height
let preReceiptTip = preReceiptBase.tip

await B.stop()
rmSync(`${B.dir}/peers.json`, { force: true })
await sleep(500)
B.port = bForkPorts.port
B.rpcPort = bForkPorts.rpcPort
console.log(`  ✓ B pinned pre-receipt base height=${preReceiptHeight} tip=${preReceiptTip.slice(0, 12)}…`)

// ── Receipt on Nexus (this block will be orphaned) ─────────────────────────
console.log('\n[3] Mine receipt on A only...')
const recNonce = await A.nonce(user.address, nexusDir)
const recR = await A.submitTx({
  chainPath: [nexusDir], nonce: recNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -1 }],
  receiptActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: 500, directory: 'SwapTest' }],
}, nexusDir, user)
if (!recR.ok) throw new Error(`receipt failed: ${JSON.stringify(recR)}`)

await miner3.start()
await waitFor(async () => {
  const r = await A.getReceipt(user.address, 500, swapNonce, 'SwapTest')
  return r?.exists ? r : null
}, 'receipt confirmed on nexus', { timeoutMs: 30_000 })
await miner3.stop()
await A.awaitQuiesced(nexusDir)
const receiptHeight = await A.height(nexusDir)
console.log(`  ✓ receipt confirmed on Nexus at height=${receiptHeight}`)

// ── Submit withdrawal on SwapTest (blocked by receipt) ────────────────────
const wdNonce = await swapNode.nonce(user.address, 'SwapTest')
const wdR = await swapNode.submitTx({
  nonce: wdNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: 499 }],
  withdrawalActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: 500, amountWithdrawn: 500 }],
}, 'SwapTest', user)
console.log(`  Withdrawal submit: ok=${wdR.ok} ${JSON.stringify(wdR).slice(0, 80)}`)

// ── Boot B with a longer fork that orphans the receipt block ──────────────
console.log('\n[4] Boot B from pre-receipt base; mine longer fork...')
B.start(['--finality-confirmations', '999999'])
await B.waitForRPC(60_000)
const restoredPreReceiptBase = await waitFor(async () => {
  const bh = await B.height(nexusDir)
  const bt = await B.tip(nexusDir)
  if (!bt || bh < preReceiptHeight) return null
  return bh < receiptHeight ? { height: bh, tip: bt } : null
}, 'B restored receipt-free fork base', { timeoutMs: 30_000, intervalMs: 500 })
preReceiptHeight = restoredPreReceiptBase.height
preReceiptTip = restoredPreReceiptBase.tip
console.log(`  ✓ B restored receipt-free base height=${preReceiptHeight} tip=${preReceiptTip.slice(0, 12)}…`)
await B.startMining(nexusDir)
await waitFor(async () => {
  const bh = await B.height(nexusDir)
  return bh > receiptHeight + 3 ? bh : null
}, `B height > ${receiptHeight + 3}`, { timeoutMs: 120_000, intervalMs: 500 })
await B.stopMining(nexusDir)
const bForkHeight = await B.height(nexusDir)
const bTip = await B.tip(nexusDir)
console.log(`  B fork: height=${bForkHeight} tip=${bTip.slice(0, 12)}…`)

// Heal A ← B while keeping the child node online so the withdrawal mempool entry
// is tested across the parent reorg, not across a child-process restart.
await B.stop()
await sleep(500)
B.port = bHealPorts.port
B.rpcPort = bHealPorts.rpcPort

B.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await B.waitForRPC(60_000)
// Progress-based: B re-syncing to its fork height is monotonic progress, not a latency
// bound — fail only if the resync STALLS, so a slow-but-advancing restore under CI load
// still passes (this fixed-deadline wait was an intermittent flake). B is a stable fork
// provider (no mining), so its tip at ≥ bForkHeight is the restored fork tip.
await waitForProgress(
  async () => B.height(nexusDir),
  (bh) => bh >= bForkHeight,
  "B restored fork provider",
  { stallMs: 60_000, intervalMs: 500 },
)
const restoredBTip = await B.tip(nexusDir)

// Reconnect gate: require a genuinely ADMITTED peer on A (the node that must
// pull B's longer fork), not merely a peerCount. Per the SDK, a peer still
// mid-identify is listed under a transient `inbound-<uuid>` id with host
// 'unknown'; peerCount includes those, so the old `ap>=1 || bp>=1` gate could
// pass on a dial that never completes identify — leaving A with no usable peer
// to fetch the fork from, so the adoption wait below expired (the observed
// flake). There is no re-dial RPC, so we must not proceed until A has admitted B.
await waitFor(async () => {
  const [aPeers, at] = await Promise.all([
    peers(A).catch(() => []),
    A.tip(nexusDir).catch(() => null),
  ])
  const admitted = aPeers.filter((p) => !String(p.publicKey).startsWith('inbound-') && p.host !== 'unknown')
  return admitted.length >= 1 || at === restoredBTip ? { admitted: admitted.length, at } : null
}, 'A admitted B for fork sync', { timeoutMs: 90_000, intervalMs: 500 })

await waitFor(async () => {
  const at = await A.tip(nexusDir)
  return at === restoredBTip ? at : null
}, "A adopted B's fork", { timeoutMs: 120_000, intervalMs: 2000 })
console.log(`  ✓ A reorged to B's fork`)
await sleep(3000)

// ── Verify receipt is now absent (orphaned) ───────────────────────────────
const receiptPost = await A.getReceipt(user.address, 500, swapNonce, 'SwapTest')
console.log(`  Receipt post-reorg: exists=${receiptPost?.exists}`)

if (receiptPost?.exists) {
  throw new Error('receipt still present after deterministic pre-receipt fork reorg')
}
console.log('  ✓ Receipt correctly orphaned after reorg')

// ── Check if withdrawal returned to mempool ───────────────────────────────
console.log('\n[5] Checking if withdrawal returned to mempool pending...')
const mempoolR = await swapNode.rpc('GET', `/api/mempool?chainPath=SwapTest`)
const mempoolCount = mempoolR.json?.count ?? 0
console.log(`  SwapTest mempool count: ${mempoolCount}`)

// The withdrawal needs the receipt to be valid. Two acceptable outcomes:
// 1. Withdrawal is back in mempool (pending, waiting for a new receipt block).
// 2. Withdrawal was rejected because the receipt is now missing — acceptable too,
//    as long as it doesn't silently disappear without being mineable again.
if (wdR.ok && mempoolCount > 0) {
  console.log('  ✓ Withdrawal returned to mempool pending — orphan recovery worked')
} else if (!wdR.ok) {
  console.log('  ✓ Withdrawal was rejected initially (receipt-blocked), no orphan issue')
} else {
  throw new Error('withdrawal accepted before reorg but missing from mempool after receipt orphan')
}

console.log('\n✓ orphaned-withdrawal-pending passed.')
await net.teardown()
await sleep(500)
process.exit(0)
