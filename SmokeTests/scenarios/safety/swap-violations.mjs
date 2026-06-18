// Swap protocol violation rejection. Uses strictly controlled mining
// (mineToHeight with specific targets) to keep chain depth < 20 blocks,
// avoiding deep state trie pressure that slows processBlockHeader.
//
// Violation 1: Withdraw with receipt but no deposit (rejected at block level)
// Violation 2: Double-withdraw after completed swap (second rejected)
// Violation 3: Duplicate deposit nonce (collision rejected)

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('swap-violations')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts] = await allocPorts(1)
const CHILD = 'SwapTest'
const FEE = 1
const WARMUP_WAIT_MS = 180_000
const FUND_WAIT_MS = 180_000
const MINING_WAIT_MS = 180_000
const STABLE_WAIT_MS = 120_000

console.log('=== swap-violations smoke test ===')

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
console.log(`  miner: ${minerAddr}`)
console.log(`  funder: ${funder.address}`)

const info = await nexusNode.chainInfo()
const nexusDir = info.nexus

// Deploy child chain as a per-process node; LatticeMiner handles merged mining.
const [childPorts] = await allocPorts(1)
const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  premine: 20,
  premineRecipient: funder.address,
  initialReward: 1024,
})
net.add(childNode)

// Internal miner earns Nexus coinbase; LatticeMiner advances child chain.
await nexusNode.startMining(nexusDir)
await waitFor(async () => (await nexusNode.height(nexusDir)) >= 5,
  'nexus height 5', { timeoutMs: WARMUP_WAIT_MS, intervalMs: 500 })
await nexusNode.stopMining(nexusDir)
await nexusNode.awaitQuiesced(nexusDir)

const miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)
await miner.start()

await waitFor(async () => (await nexusNode.height(nexusDir)) >= 6,
  'nexus height 6', { timeoutMs: WARMUP_WAIT_MS, intervalMs: 500 })

let _nonceSeq = 0
function swapNonce() {
  return (Date.now() * 100 + _nonceSeq++).toString(16).padStart(32, '0').slice(-32)
}

async function fail(message) {
  console.error(`  ✗ ${message}`)
  net.teardown(); await sleep(500); process.exit(1)
}

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
  await awaitStableTip(nexusNode, nexusDir, `${nexusDir} ${label}`)
  await awaitStableTip(childNode, CHILD, `${CHILD} ${label}`)
}

// Fund an account on a chain.
async function fundOnChain(user, amount, chain) {
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      if (chain === nexusDir) {
        const base = await nexusNode.nonce(funder.address, chain)
        for (const n of [base, base + 1, base + 2]) {
          const r = await nexusNode.submitTx({
            nonce: n, signers: [funder.address], fee: FEE,
            accountActions: [{ owner: funder.address, delta: -(amount + FEE) }, { owner: user.address, delta: amount }],
          }, chain, funder)
          if (r.ok) return
          const msg = JSON.stringify(r)
          if (msg.includes('Duplicate transaction')) return
          if (!msg.includes('Nonce') && !msg.includes('confirmed') && !msg.includes('RBF')) {
            throw new Error(`fund ${chain} failed: ${msg}`)
          }
        }
      } else {
        const base = await childNode.nonce(funder.address, chain)
        for (const n of [base, base + 1, base + 2]) {
          const r = await childNode.submitTx({
            chainPath: [nexusDir, CHILD], nonce: n, signers: [funder.address], fee: FEE,
            accountActions: [{ owner: funder.address, delta: -(amount + FEE) }, { owner: user.address, delta: amount }],
          }, chain, funder)
          if (r.ok) return
          const msg = JSON.stringify(r)
          if (msg.includes('Duplicate transaction')) return
          if (!msg.includes('Nonce') && !msg.includes('confirmed') && !msg.includes('RBF')) {
            throw new Error(`fund ${chain} failed: ${msg}`)
          }
        }
      }
    } catch (err) {
      if (attempt === 5) throw err
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

async function fundUser(user, amount) {
  let funded = false
  for (let round = 0; round < 5 && !funded; round++) {
    await waitFor(async () => {
      const nb = await nexusNode.balance(funder.address, nexusDir)
      const cb = await childNode.balance(funder.address, CHILD)
      return nb >= amount + FEE && cb >= amount + FEE ? true : null
    }, 'funder source balances', { timeoutMs: FUND_WAIT_MS, intervalMs: 1000 })
    await miner.stop()
    await awaitStableChains('before funding')
    await fundOnChain(user, amount, nexusDir)
    await nexusNode.startMining(nexusDir)
    await waitFor(async () => (await nexusNode.balance(user.address, nexusDir)) >= amount,
      'nexus funding confirmed', { timeoutMs: FUND_WAIT_MS, intervalMs: 1000 })
    await nexusNode.stopMining(nexusDir)
    await nexusNode.awaitQuiesced(nexusDir)
    await fundOnChain(user, amount, CHILD)
    await miner.start()
    await waitFor(async () => {
      const nb = await nexusNode.balance(user.address, nexusDir)
      const cb = await childNode.balance(user.address, CHILD)
      return nb >= amount && cb >= amount ? true : null
    }, 'funding confirmed on both chains', { timeoutMs: FUND_WAIT_MS, intervalMs: 1000 })
    await miner.stop()
    await awaitStableChains('after funding')
    const nb = await nexusNode.balance(user.address, nexusDir)
    const cb = await childNode.balance(user.address, CHILD)
    if (nb >= amount && cb >= amount) {
      funded = true
      break
    }
    console.log(`  funding reorged out; restaging (nexus=${nb} child=${cb})`)
    await miner.start()
  }
  if (!funded) throw new Error('funding did not survive reorg settling')
  await miner.start()
  console.log(`  ✓ funded`)
}

async function mineNexusTx(submitFn, confirmFn, desc) {
  await miner.stop()
  await awaitStableChains(`before ${desc}`)
  await nexusNode.startMining(nexusDir)
  await submitFn()
  await waitFor(confirmFn, desc, { timeoutMs: MINING_WAIT_MS, intervalMs: 1000 })
  await nexusNode.stopMining(nexusDir)
  await nexusNode.awaitQuiesced(nexusDir)
  await miner.start()
}

// ── Violation 1: Withdraw with receipt but no deposit ───────────────────
console.log(`\n[1] Withdraw with receipt but no deposit...`)
const u1 = genKeypair()
await fundUser(u1, 5000)
console.log(`  user1=${u1.address} nexus=${await nexusNode.balance(u1.address, nexusDir)} child=${await childNode.balance(u1.address, CHILD)}`)

const ghostNonce = swapNonce()
let rec1 = null
await mineNexusTx(async () => {
  const recN1 = await nexusNode.nonce(u1.address, nexusDir)
  rec1 = await nexusNode.submitTx({
    nonce: recN1, signers: [u1.address], fee: FEE,
    accountActions: [{ owner: u1.address, delta: -FEE }],
    receiptActions: [{ withdrawer: u1.address, nonce: ghostNonce, demander: u1.address, amountDemanded: 500, directory: CHILD }],
  }, nexusDir, u1)
  if (!rec1.ok) throw new Error(`receipt submit failed: ${JSON.stringify(rec1)}`)
}, async () => {
  const r = await nexusNode.getReceipt(u1.address, 500, ghostNonce, CHILD)
  return r.exists ? r : null
}, 'ghost receipt visible')
console.log(`  receipt accepted (by design — cross-chain claim)`)

const childBal1Before = await childNode.balance(u1.address, CHILD)
const wdN1 = await childNode.nonce(u1.address, CHILD)
const wd1 = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: wdN1, signers: [u1.address], fee: FEE,
  accountActions: [{ owner: u1.address, delta: 500 - FEE }],
  withdrawalActions: [{ withdrawer: u1.address, nonce: ghostNonce, demander: u1.address, amountDemanded: 500, amountWithdrawn: 500 }],
}, CHILD, u1)
if (wd1.ok) {
  await fail(`withdrawal without deposit was accepted at submit: ${JSON.stringify(wd1)}`)
}
const childBal1After = await childNode.balance(u1.address, CHILD)
if (childBal1After !== childBal1Before) {
  await fail(`withdrawal without deposit changed balance (${childBal1Before} → ${childBal1After})`)
}
console.log(`  ✓ rejected at submit: ${(wd1.error ?? JSON.stringify(wd1)).slice(0, 100)}`)

// ── Violation 2: Double-withdraw after completed swap ───────────────────
console.log(`\n[2] Double-withdraw (complete a real swap, then try withdrawal again)...`)
const u2 = genKeypair()
await fundUser(u2, 5000)
console.log(`  user2=${u2.address}`)

const dblNonce = swapNonce()

// Submit deposit on child (LatticeMiner mines continuously)
const depN2 = await childNode.nonce(u2.address, CHILD)
const dep2 = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depN2, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: -(300 + FEE) }],
  depositActions: [{ nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountDeposited: 300 }],
}, CHILD, u2)
if (!dep2.ok) throw new Error(`deposit failed: ${JSON.stringify(dep2)}`)
await waitFor(async () => {
  const d = await childNode.getDeposit(u2.address, 300, dblNonce, CHILD)
  return d.exists ? d : null
}, 'deposit visible', { timeoutMs: MINING_WAIT_MS })

// Receipt on nexus
let rec2 = null
await mineNexusTx(async () => {
  const recN2 = await nexusNode.nonce(u2.address, nexusDir)
  rec2 = await nexusNode.submitTx({
    nonce: recN2, signers: [u2.address], fee: FEE,
    accountActions: [{ owner: u2.address, delta: -FEE }],
    receiptActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, directory: CHILD }],
  }, nexusDir, u2)
  if (!rec2.ok) throw new Error(`receipt failed: ${JSON.stringify(rec2)}`)
}, async () => {
  const r = await nexusNode.getReceipt(u2.address, 300, dblNonce, CHILD)
  return r.exists ? r : null
}, 'receipt visible')

// First withdrawal — should succeed and consume deposit
let wd2 = null
let consumed2 = false
for (let attempt = 0; attempt < 6 && !consumed2; attempt++) {
  await waitFor(async () => {
    const d = await childNode.getDeposit(u2.address, 300, dblNonce, CHILD)
    return d.exists ? d : null
  }, 'deposit still visible', { timeoutMs: MINING_WAIT_MS })
  const wdN2 = await childNode.nonce(u2.address, CHILD)
  wd2 = await childNode.submitTx({
    chainPath: [nexusDir, CHILD], nonce: wdN2, signers: [u2.address], fee: FEE,
    accountActions: [{ owner: u2.address, delta: 300 - FEE }],
    withdrawalActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountWithdrawn: 300 }],
  }, CHILD, u2)
  if (wd2.ok) {
    try {
      await waitFor(async () => {
        const d = await childNode.getDeposit(u2.address, 300, dblNonce, CHILD)
        return !d.exists
      }, 'deposit consumed', { timeoutMs: MINING_WAIT_MS })
      consumed2 = true
      break
    } catch (err) {
      if (attempt === 5) throw err
      await sleep(1000)
      continue
    }
  }
  const msg = JSON.stringify(wd2)
  if (!msg.includes('no corresponding deposit')) break
  await sleep(1000)
}
if (!wd2?.ok || !consumed2) throw new Error(`first withdrawal failed: ${JSON.stringify(wd2)}`)
console.log(`  legitimate swap completed`)

// Second withdrawal — should fail (deposit consumed)
const childBal2Before = await childNode.balance(u2.address, CHILD)
const wdN2b = await childNode.nonce(u2.address, CHILD)
const wd2b = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: wdN2b, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: 300 - FEE }],
  withdrawalActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountWithdrawn: 300 }],
}, CHILD, u2)
if (wd2b.ok) {
  await fail(`second withdrawal was accepted at submit: ${JSON.stringify(wd2b)}`)
}
const childBal2After = await childNode.balance(u2.address, CHILD)
if (childBal2After !== childBal2Before) {
  await fail(`double-withdrawal changed balance (${childBal2Before} → ${childBal2After})`)
}
console.log(`  ✓ second withdrawal rejected at submit: ${(wd2b.error ?? JSON.stringify(wd2b)).slice(0, 80)}`)

// ── Violation 3: Duplicate deposit nonce ─────────────────────────────────
console.log(`\n[3] Duplicate deposit nonce (same demander/amount/nonce)...`)
const u3 = genKeypair()
await fundUser(u3, 5000)
console.log(`  user3=${u3.address}`)

const dupNonce = swapNonce()
const dupAmount = 400

await miner.stop()
await awaitStableChains('before first duplicate-nonce deposit')
const depN3 = await childNode.nonce(u3.address, CHILD)
const dep3 = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depN3, signers: [u3.address], fee: FEE,
  accountActions: [{ owner: u3.address, delta: -(dupAmount + FEE) }],
  depositActions: [{ nonce: dupNonce, demander: u3.address, amountDemanded: dupAmount, amountDeposited: dupAmount }],
}, CHILD, u3)
if (!dep3.ok) throw new Error(`first duplicate-nonce deposit failed: ${JSON.stringify(dep3)}`)
await miner.start()
await waitFor(async () => {
  const d = await childNode.getDeposit(u3.address, dupAmount, dupNonce, CHILD)
  return d.exists ? d : null
}, 'first duplicate-nonce deposit visible', { timeoutMs: MINING_WAIT_MS })
await miner.stop()
await awaitStableChains('after first duplicate-nonce deposit')
const depState3 = await childNode.getDeposit(u3.address, dupAmount, dupNonce, CHILD)
if (!depState3.exists || depState3.amountDeposited !== dupAmount) {
  await fail(`first deposit state wrong: ${JSON.stringify(depState3)}`)
}
console.log(`  first deposit confirmed`)

const childBal3Before = await childNode.balance(u3.address, CHILD)
const childHeight3Before = await childNode.height(CHILD)
const depN3b = await childNode.nonce(u3.address, CHILD)
const dep3b = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depN3b, signers: [u3.address], fee: FEE,
  accountActions: [{ owner: u3.address, delta: -(dupAmount + FEE) }],
  depositActions: [{ nonce: dupNonce, demander: u3.address, amountDemanded: dupAmount, amountDeposited: dupAmount }],
}, CHILD, u3)

if (!dep3b.ok) {
  console.log(`  ✓ duplicate deposit rejected at submit: ${(dep3b.error ?? JSON.stringify(dep3b)).slice(0, 100)}`)
} else {
  console.log(`  duplicate deposit accepted at submit; verifying block-level rejection`)
  await miner.start()
  await waitFor(async () => (await childNode.height(CHILD)) > childHeight3Before,
    'duplicate deposit attempt processed', { timeoutMs: MINING_WAIT_MS, intervalMs: 1000 })
  await miner.stop()
  await awaitStableChains('after duplicate deposit attempt')

  const depState3After = await childNode.getDeposit(u3.address, dupAmount, dupNonce, CHILD)
  const childBal3After = await childNode.balance(u3.address, CHILD)
  const mempool3 = await childNode.rpc('GET', `/api/mempool?chainPath=${childNode._queryPath(CHILD)}`)
  if (!depState3After.exists || depState3After.amountDeposited !== dupAmount) {
    await fail(`duplicate deposit changed state: ${JSON.stringify(depState3After)}`)
  }
  if (childBal3After !== childBal3Before) {
    await fail(`duplicate deposit debited user (${childBal3Before} → ${childBal3After})`)
  }
  if ((mempool3.json?.count ?? 0) !== 0) {
    await fail(`duplicate deposit remained in mempool: ${JSON.stringify(mempool3.json)}`)
  }
  console.log(`  ✓ duplicate deposit collision was not applied`)
}

console.log('\n✓ swap-violations smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
