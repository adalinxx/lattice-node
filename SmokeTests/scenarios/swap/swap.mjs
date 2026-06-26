// Cross-chain swap: deposit (child) → receipt (parent) → withdrawal (child).
//
// Self-contained: spawns its own LatticeNode under SMOKE_ROOT, deploys a fast
// child chain as a per-process node, funds a fresh keypair on both chains,
// then runs the full swap.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, waitForProgress, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('swap')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts] = await allocPorts(1)
const CHILD = 'FastTest'
const WARMUP_WAIT_MS = 180_000
const MINING_WAIT_MS = 180_000
const STABLE_WAIT_MS = 120_000

console.log('=== cross-chain swap smoke test ===')

const funder = genKeypair()
const nexusNode = new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
  coinbaseAddress: funder.address,
})
const net = new LatticeNetwork()
net.add(nexusNode)
net.installSignalHandlers()

nexusNode.start()
await nexusNode.waitForRPC()
const minerIdent = await nexusNode.readIdentity()
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()
console.log(`miner address: ${minerAddr}`)
console.log(`funder address: ${funder.address}`)
console.log(`user address:  ${user.address}`)

const info = await nexusNode.chainInfo()
const nexusDir = info.nexus

// Deploy FastTest with premine to the dedicated funding address. Mining rewards
// are signed by the node identity but paid to this address, so spending nonces do
// not race the mining identity's coinbase nonce.
console.log(`deploying ${CHILD}...`)
const [childPorts] = await allocPorts(1)
const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  premine: 100,
  premineRecipient: funder.address,
})
net.add(childNode)

// One merged-mining coordinator advances BOTH Nexus and FastTest — including
// state-access txs like receipts. The node builds each template with full state
// access; the coordinator only does PoW. (No separate Nexus-only miner: merged
// mining confirms parent state txs directly — see scenarios/swap/swap-cli.mjs.)
const miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)
await miner.start()

// 10 blocks from genesis under one miner (~30s/block) needs more than a single
// WARMUP window; the original split this across two miners. Give it room.
await waitForProgress(async () => nexusNode.height(nexusDir), (h) => h >= 10,
  'nexus height 10 (merged miner advancing both chains)', { stallMs: 2 * WARMUP_WAIT_MS, intervalMs: 500 })
console.log(`${CHILD} deployed and mining`)

const funderNexusBal = await nexusNode.balance(funder.address, nexusDir)
const funderChildBal = await childNode.balance(funder.address, CHILD)
console.log(`\nfunder balances  Nexus=${funderNexusBal}  ${CHILD}=${funderChildBal}`)

const fundAmount = 5000
if (funderChildBal < fundAmount + 100 || funderNexusBal < fundAmount + 100) {
  console.error(`Insufficient funder balance to fund test`)
  net.teardown(); process.exit(1)
}

console.log(`\npausing mining to stage fund txs`)
await miner.stop()

async function awaitStableTip(node, dir, label, { timeoutMs = STABLE_WAIT_MS, idleMs = 5_000 } = {}) {
  const start = Date.now()
  let lastHeight = await node.height(dir)
  let lastTip = await node.tip(dir)
  let stableSince = Date.now()
  while (Date.now() - start < timeoutMs) {
    await sleep(500)
    const [height, tip] = await Promise.all([node.height(dir), node.tip(dir)])
    if (height === lastHeight && tip === lastTip) {
      if (Date.now() - stableSince >= idleMs) return { height, tip }
    } else {
      lastHeight = height
      lastTip = tip
      stableSince = Date.now()
    }
  }
  throw new Error(`timed out after ${timeoutMs}ms: ${label} stable tip`)
}

async function awaitStableChains(label) {
  await awaitStableTip(nexusNode, nexusDir, `Nexus ${label}`)
  await awaitStableTip(childNode, CHILD, `${CHILD} ${label}`)
}

await awaitStableChains('before funding')

// Submit to child chain directly via childNode with explicit chainPath.
async function stageFund(chain) {
  for (let attempt = 0; attempt < 6; attempt++) {
    if (chain === nexusDir) {
      const base = await nexusNode.nonce(funder.address, chain)
      for (const n of [base, base + 1]) {
        const r = await nexusNode.submitTx({ nonce: n, signers: [funder.address], fee: 1,
          accountActions: [{ owner: funder.address, delta: -(fundAmount + 1) }, { owner: user.address, delta: fundAmount }],
        }, chain, funder)
        if (r.ok) { console.log(`  staged ${chain}: tx=${r.txCID?.slice(0, 20)}... nonce=${n}`); return }
        const msg = JSON.stringify(r)
        if (!msg.includes('Nonce') && !msg.includes('future')) throw new Error(`fund ${chain} failed: ${msg}`)
      }
    } else {
      const base = await childNode.nonce(funder.address, chain)
      for (const n of [base, base + 1]) {
        const r = await childNode.submitTx({ chainPath: [nexusDir, CHILD], nonce: n, signers: [funder.address], fee: 1,
          accountActions: [{ owner: funder.address, delta: -(fundAmount + 1) }, { owner: user.address, delta: fundAmount }],
        }, chain, funder)
        if (r.ok) { console.log(`  staged ${chain}: tx=${r.txCID?.slice(0, 20)}... nonce=${n}`); return }
        const msg = JSON.stringify(r)
        if (!msg.includes('Nonce') && !msg.includes('future')) throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

console.log(`staging fund txs (${fundAmount} on each chain)...`)
await stageFund(nexusDir)
await stageFund(CHILD)
// The merged miner confirms BOTH the Nexus fund tx (parent state-access) and the
// child fund tx (via the child candidate) — one coordinator, both chains.
console.log(`resuming merged mining to confirm fund txs`)
await miner.start()
await waitFor(async () => (await nexusNode.balance(user.address, nexusDir)) >= fundAmount,
  'user Nexus balance funded', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })

console.log(`waiting for child fund inclusion...`)
await waitFor(async () => (await childNode.balance(user.address, CHILD)) >= fundAmount,
  `user ${CHILD} balance funded`, { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })

await miner.stop()
await awaitStableChains('after funding')
const [canonicalNexusFunding, canonicalChildFunding] = await Promise.all([
  nexusNode.balance(user.address, nexusDir),
  childNode.balance(user.address, CHILD),
])
if (canonicalNexusFunding < fundAmount || canonicalChildFunding < fundAmount) {
  throw new Error(`funding reorged out: nexus=${canonicalNexusFunding} child=${canonicalChildFunding}`)
}
await miner.start()

const nexusBal0 = await nexusNode.balance(user.address, nexusDir)
const childBal0 = await childNode.balance(user.address, CHILD)
console.log(`user balances  Nexus=${nexusBal0}  ${CHILD}=${childBal0}`)

// Confirm a Nexus state tx under the merged miner. Stop-for-stable-tip keeps the
// pre-submit balance deterministic; the merged miner then confirms the tx (the node
// builds the template with full state access) while advancing the child too.
async function mineNexusTx(submitFn, confirmFn, desc) {
  await miner.stop()
  await awaitStableChains(`before ${desc}`)
  await submitFn()
  await miner.start()
  await waitFor(confirmFn, desc, { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
}

const swapNonceHex = Date.now().toString(16).padStart(32, '0').slice(-32)
const amount = 500
const fee = 1
console.log(`\nswap: amount=${amount} swapNonce=0x${swapNonceHex} fee=${fee}/tx`)

// [1/3] Deposit on child — LatticeMiner mines it via child candidate.
await miner.stop()
await awaitStableChains('before deposit')
const spendableChildBalance = await childNode.balance(user.address, CHILD)
if (spendableChildBalance < amount + fee) {
  throw new Error(`insufficient canonical ${CHILD} balance before deposit: have=${spendableChildBalance} need=${amount + fee}`)
}
const depNonce = await childNode.nonce(user.address, CHILD)
console.log(`\n[1/3] Deposit on ${CHILD} (acct nonce=${depNonce})`)
const depResult = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -(amount + fee) }],
  depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
}, CHILD, user)
console.log('  submit:', depResult.ok ? '✓' : depResult.error)
if (!depResult.ok) { net.teardown(); process.exit(1) }
await miner.start()

const depState = await waitFor(async () => {
  const r = await childNode.getDeposit(user.address, amount, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'deposit state visible', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
console.log(`  ✓ deposit in state: amountDeposited=${depState.amountDeposited}`)

// [2/3] Receipt on parent — confirmed by the merged miner (parent state-access tx).
console.log(`\n[2/3] Receipt on ${nexusDir}`)
let recNonce
await mineNexusTx(
  async () => {
    recNonce = await nexusNode.nonce(user.address, nexusDir)
    const recResult = await nexusNode.submitTx({
      nonce: recNonce, signers: [user.address], fee,
      accountActions: [{ owner: user.address, delta: -fee }],
      receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: CHILD }],
    }, nexusDir, user)
    if (!recResult.ok) throw new Error(`receipt submit failed: ${JSON.stringify(recResult)}`)
    console.log('  receipt submitted ✓')
  },
  async () => {
    const r = await nexusNode.getReceipt(user.address, amount, swapNonceHex, CHILD)
    return r.exists ? r : null
  },
  'receipt state visible'
)
console.log(`  ✓ receipt confirmed on ${nexusDir}`)

// [3/3] Withdrawal on child — LatticeMiner mines it via child candidate.
await miner.stop()
await awaitStableChains('before withdrawal')
const wdNonce = await childNode.nonce(user.address, CHILD)
console.log(`\n[3/3] Withdrawal on ${CHILD} (acct nonce=${wdNonce})`)
const wdResult = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: wdNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: amount - fee }],
  withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
}, CHILD, user)
console.log('  submit:', wdResult.ok ? '✓' : wdResult.error)
if (!wdResult.ok) { net.teardown(); process.exit(1) }
await miner.start()

await waitFor(async () => {
  const r = await childNode.getDeposit(user.address, amount, swapNonceHex, CHILD)
  return !r.exists
}, 'deposit consumed', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
console.log(`  ✓ deposit consumed (withdrawal settled)`)

await miner.stop()
await awaitStableChains('before final balance')

async function stableBalance(node, addr, dir, label) {
  return await waitFor(async () => {
    try {
      return await node.balance(addr, dir)
    } catch {
      return null
    }
  }, label, { timeoutMs: 15_000, intervalMs: 500 })
}

const nexusBal1 = await stableBalance(nexusNode, user.address, nexusDir, 'final Nexus balance')
const childBal1 = await stableBalance(childNode, user.address, CHILD, `final ${CHILD} balance`)
const actualNexusDelta = nexusBal1 - nexusBal0
const actualChildDelta = childBal1 - childBal0
const expectedNexusDelta = -fee
const expectedChildDelta = -2 * fee
console.log(`\n=== RESULTS ===`)
console.log(`Nexus     before=${nexusBal0}  after=${nexusBal1}  delta=${actualNexusDelta}  expected=${expectedNexusDelta}  ${actualNexusDelta === expectedNexusDelta ? '✓' : '✗'}`)
console.log(`${CHILD}  before=${childBal0}  after=${childBal1}  delta=${actualChildDelta}  expected=${expectedChildDelta}  ${actualChildDelta === expectedChildDelta ? '✓' : '✗'}`)
if (actualNexusDelta !== expectedNexusDelta || actualChildDelta !== expectedChildDelta) {
  console.error(`\n✗ final balance deltas did not match expected swap fees`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`\n✓ Full deposit -> receipt -> withdrawal cycle completed`)

net.teardown()
await sleep(500)
process.exit(0)
