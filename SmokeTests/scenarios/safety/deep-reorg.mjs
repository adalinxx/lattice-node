// Deep cross-chain reorg: parent chain canonicity must not erase already-valid
// per-process child-chain state.
//
// Tests the invariant: a child block's PoW slice is anchored by the verified
// ancestor path that carried it. Parent-chain canonicity affects future mining
// and mempool source selection, but it does not retroactively invalidate the
// child block's content-addressed state transition.
//
// Topology: Nexus → SwapTest (per-process)
// Scenario:
//   1. Mine Nexus + SwapTest together (fork A) via LatticeMiner
//   2. User deposits on SwapTest during fork A
//   3. Mine a longer Nexus-only fork (fork C, no SwapTest blocks)
//   4. Heal: C wins, A is orphaned
//   5. SwapTest deposit remains valid after the parent reorg

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, waitForProgress, genKeypair, computeAddress,
} from 'lattice-node-sdk'
import { startMining, stopMining } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('deep-reorg')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, swapPorts, cPorts] = await allocPorts(3)
const CHILD = 'SwapTest'
const SHORT_WAIT_MS = 120_000
const MEDIUM_WAIT_MS = 180_000

console.log('=== deep cross-chain reorg test ===')

const A = new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort })
const C = new LatticeNode({ name: 'C', dir: `${ROOT}/C`, port: cPorts.port, rpcPort: cPorts.rpcPort })

const net = new LatticeNetwork()
net.add(A)
net.add(C)
net.installSignalHandlers()

// ── [1] Boot A, deploy SwapTest as per-process child, mine fork A ─────────

console.log('\n[1] Boot A, deploy SwapTest (per-process), mine 5 blocks (fork A)...')
A.start(['--finality-confirmations', '999999'])
await A.waitForRPC()
const aIdent = await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus
const childFunder = genKeypair()

// Deploy SwapTest as a per-process child — LatticeMiner handles embedding.
const swapTestNode = await A.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: swapPorts,
  premine: 100, premineRecipient: childFunder.address,
})
net.add(swapTestNode)

const miner = new LatticeMiner(A, [swapTestNode], { workers: 2, batchSize: 2000 })
net.addMiner(miner)
await miner.start()

await waitForProgress(async () => A.height(nexusDir), (h) => h >= 5, 'nexus height 5', { stallMs: SHORT_WAIT_MS, intervalMs: 300 })
await waitForProgress(async () => swapTestNode.height(CHILD), (h) => h >= 3, 'SwapTest height 3', { stallMs: SHORT_WAIT_MS, intervalMs: 300 })
await miner.stop()
await A.awaitQuiesced(nexusDir)
await swapTestNode.awaitQuiesced(CHILD)
await sleep(1000)
console.log(`  Fork A: Nexus=${await A.height(nexusDir)} SwapTest=${await swapTestNode.height(CHILD)}`)

// ── [2] User deposits on SwapTest during fork A ──────────────────────────

console.log('\n[2] User deposits on SwapTest (fork A)...')
const minerAddr = computeAddress(aIdent.publicKey)
const user = genKeypair()
const swapNonce = Date.now().toString(16).padStart(32, '0').slice(-32)

// Resume mining to fund accounts.
await miner.start()
await waitFor(async () => (await A.balance(minerAddr, nexusDir)) > 5000, 'miner funded', { timeoutMs: SHORT_WAIT_MS })
await waitFor(async () => (await swapTestNode.balance(childFunder.address, CHILD)) > 2000, 'child funder funded', { timeoutMs: SHORT_WAIT_MS })
await miner.stop()
await A.awaitQuiesced(nexusDir)
await swapTestNode.awaitQuiesced(CHILD)
await sleep(500)

const fundNonce = await A.nonce(minerAddr, nexusDir)
const fundResult = await A.submitTx({ nonce: fundNonce, signers: [minerAddr], fee: 1,
  accountActions: [{ owner: minerAddr, delta: -2001 }, { owner: user.address, delta: 2000 }],
}, nexusDir, { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey })
if (!fundResult.ok) throw new Error(`fund nexus failed: ${JSON.stringify(fundResult)}`)

const fundChildNonce = await swapTestNode.nonce(childFunder.address, CHILD)
const fundChildResult = await swapTestNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: fundChildNonce, signers: [childFunder.address], fee: 1,
  accountActions: [{ owner: childFunder.address, delta: -2001 }, { owner: user.address, delta: 2000 }],
}, CHILD, childFunder)
if (!fundChildResult.ok) throw new Error(`fund child failed: ${JSON.stringify(fundChildResult)}`)

await miner.start()
await waitFor(async () => (await A.balance(user.address, nexusDir)) >= 2000, 'nexus funded', { timeoutMs: MEDIUM_WAIT_MS })
await waitFor(async () => (await swapTestNode.balance(user.address, CHILD)) >= 2000, 'child funded', { timeoutMs: MEDIUM_WAIT_MS })
await miner.stop()
await sleep(500)

const depNonce = await swapTestNode.nonce(user.address, CHILD)
const depResult = await swapTestNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: 500, amountDeposited: 500 }],
}, CHILD, user)
if (!depResult.ok) throw new Error(`deposit submit failed: ${JSON.stringify(depResult)}`)

await miner.start()
await waitFor(async () => {
  const d = await swapTestNode.getDeposit(user.address, 500, swapNonce, CHILD)
  return d.exists ? d : null
}, 'deposit confirmed on fork A', { timeoutMs: MEDIUM_WAIT_MS })
await miner.stop()
await A.awaitQuiesced(nexusDir)
await swapTestNode.awaitQuiesced(CHILD)
const forkANexusAfterDeposit = await A.height(nexusDir)
console.log(`  ✓ Deposit confirmed. Fork A Nexus height=${forkANexusAfterDeposit}`)

// ── [3] Boot C as standalone (no SwapTest), mine a longer fork ───────────

console.log('\n[3] Boot C standalone, mine a longer fork (no SwapTest)...')
C.start(['--finality-confirmations', '999999'])
await C.waitForRPC()
await startMining(C, nexusDir)
await waitForProgress(async () => C.height(nexusDir), (h) => h > forkANexusAfterDeposit + 2,
  'C fork longer', { stallMs: MEDIUM_WAIT_MS, intervalMs: 500 })
await stopMining(C, nexusDir)
await C.awaitQuiesced(nexusDir)
const forkCHeight = await C.height(nexusDir)
const forkCTip = await C.tip(nexusDir)
console.log(`  Fork C: Nexus height=${forkCHeight} tip=${forkCTip.slice(0, 12)}… (fork A was ${forkANexusAfterDeposit})`)

// ── [4] Heal: connect A to C (C's longer fork wins) ──────────────────────

console.log('\n[4] Heal: connect A to C (C wins)...')
await C.readIdentity()
const aInfo = await A.chainInfo()
const aP2P = aInfo.p2pAddress

await C.stop()
await sleep(1000)
C.start(['--finality-confirmations', '999999', '--peer', aP2P])
await C.waitForRPC(SHORT_WAIT_MS)

await waitFor(async () => {
  const aTip = await A.tip(nexusDir)
  return aTip === forkCTip ? aTip : null
}, 'A adopted exact C fork tip', { timeoutMs: MEDIUM_WAIT_MS, intervalMs: 1000 })

const aFinalNexusH = await A.height(nexusDir)
console.log(`  ✓ A reorged to height=${aFinalNexusH} tip=${forkCTip.slice(0, 12)}…`)

console.log('  Mining parent blocks after heal as a child-stability control...')
const prePostHealChildHeight = await swapTestNode.height(CHILD)
const prePostHealChildTip = await swapTestNode.tip(CHILD)
await miner.start()
await waitForProgress(async () => A.height(nexusDir), (h) => h > aFinalNexusH,
  'Nexus advanced after parent heal', { stallMs: MEDIUM_WAIT_MS, intervalMs: 500 })
await miner.stop()
await A.awaitQuiesced(nexusDir)
await swapTestNode.awaitQuiesced(CHILD)
const postHealChildHeight = await swapTestNode.height(CHILD)
const postHealChildTip = await swapTestNode.tip(CHILD)
if (postHealChildHeight !== prePostHealChildHeight || postHealChildTip !== prePostHealChildTip) {
  console.error(
    `  ✗ child tip moved during sibling-parent mining control: ` +
    `height ${prePostHealChildHeight} -> ${postHealChildHeight}, ` +
    `tip ${prePostHealChildTip?.slice(0, 12)}… -> ${postHealChildTip?.slice(0, 12)}…`
  )
  net.teardown(); await sleep(500); process.exit(1)
}
console.log('  ✓ child tip stayed stable while sibling-parent-only mining advanced')

// ── [5] Verify deposit survives on SwapTest ──────────────────────────────

console.log('\n[5] Verify child deposit survives parent reorg...')
const depPost = await swapTestNode.getDeposit(user.address, 500, swapNonce, CHILD)

if (!depPost.exists) {
  console.error('  ✗ FAILURE: deposit disappeared after parent chain reorged!')
  console.error(`    Parent canonicity should not invalidate already-verified child state.`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log('  ✓ deposit still exists — child state is independent of parent canonicity')
console.log('\n✓ deep-reorg smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
