// Restart resilience: run a variable-rate swap A, hard-restart the per-process
// Nexus + child nodes against the SAME data-dirs, then run swap B with an
// inverse rate. Asserts swap A's deposit stays consumed across restart, and the
// chains still settle new swaps.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, waitForProgress, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('restart-resilience')
const CHILD = 'FastTest'

rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, childPorts] = await allocPorts(2, { seed: 19 })

console.log('=== restart-resilience variable-rate swap smoke test ===')

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
const userA = genKeypair()
const userB = genKeypair()
const childPremineUnits = 10
const childPremineAmount = childPremineUnits * 1024
const WARMUP_WAIT_MS = 240_000
const MINING_WAIT_MS = 180_000
const STABLE_WAIT_MS = 120_000
console.log(`miner address: ${minerAddr}`)
console.log(`funder address: ${funder.address}`)
console.log(`user A:        ${userA.address}`)
console.log(`user B:        ${userB.address}`)

const initial = await nexusNode.chainInfo()
const nexusDir = initial.nexus
console.log(`  nexus=${nexusDir} chains=${initial.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

console.log(`  deploying ${CHILD} as per-process child...`)
const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  premine: childPremineUnits,
  premineRecipient: userB.address,
  targetBlockTime: 1000,
})
net.add(childNode)
const deployInfo = childNode._deployInfo
const genesisHex = deployInfo.genesisHex
const childP2PAddress = deployInfo.chainP2PAddress
const childPath = [nexusDir, CHILD]
const childPathString = childPath.join('/')
const parentP2P = (await nexusNode.chainInfo()).p2pAddress

let miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)
await miner.start()
await waitFor(async () => {
  const [nh, ch] = await Promise.all([
    nexusNode.height(nexusDir),
    childNode.height(CHILD),
  ])
  return nh >= 5 && ch >= 5 ? { nexus: nh, child: ch } : null
}, `Nexus + ${CHILD} height 5`, { timeoutMs: WARMUP_WAIT_MS, intervalMs: 500 })

async function restartMiner() {
  await miner.stop()
  miner = new LatticeMiner(nexusNode, [childNode])
  net.addMiner(miner)
  await miner.start()
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

async function stopNodeAndWaitDown(node, { timeoutMs = 30_000 } = {}) {
  await node.stop()
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      await fetch(`${node.base}/api/chain/info`, { signal: AbortSignal.timeout(500) })
    } catch {
      return
    }
    await sleep(500)
  }
  throw new Error(`${node.name} failed to shut down within ${timeoutMs}ms`)
}

async function stageFund(addr, fundAmount, chain, keypair = funder, fromAddr = funder.address) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const node = chain === nexusDir ? nexusNode : childNode
    const base = await node.nonce(fromAddr, chain)
    for (const n of [base, base + 1]) {
      const r = await node.submitTx({
        chainPath: chain === nexusDir ? [nexusDir] : childPath,
        nonce: n,
        signers: [fromAddr],
        fee: 1,
        accountActions: [
          { owner: fromAddr, delta: -(fundAmount + 1) },
          { owner: addr, delta: fundAmount },
        ],
      }, chain, keypair)
      if (r.ok) return
      const msg = JSON.stringify(r)
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

async function fundAccount(addr, fundAmount, {
  fundChild = false,
  expectedChild = fundAmount,
  childFunder = funder,
  childFunderAddress = funder.address,
} = {}) {
  await miner.stop()
  await awaitStableTip(nexusNode, nexusDir, 'Nexus before funding')
  await awaitStableTip(childNode, CHILD, `${CHILD} before funding`)
  await stageFund(addr, fundAmount, nexusDir)
  if (fundChild) await stageFund(addr, expectedChild, CHILD, childFunder, childFunderAddress)
  await restartMiner()
  await waitFor(async () => {
    const balance = await nexusNode.balance(addr, nexusDir)
    if (balance > fundAmount) throw new Error(`duplicate Nexus funding detected: ${balance} > ${fundAmount}`)
    return balance === fundAmount ? balance : null
  }, 'nexus balance funded', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
  if (fundChild) {
    await waitFor(async () => {
      const balance = await childNode.balance(addr, CHILD)
      if (balance > expectedChild) throw new Error(`duplicate ${CHILD} funding detected: ${balance} > ${expectedChild}`)
      return balance === expectedChild ? balance : null
    }, `${CHILD} balance funded`, { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
  }
  await miner.stop()
  await awaitStableTip(nexusNode, nexusDir, 'Nexus after funding')
  await awaitStableTip(childNode, CHILD, `${CHILD} after funding`)
  const [nexusBalance, childBalance] = await Promise.all([
    nexusNode.balance(addr, nexusDir),
    childNode.balance(addr, CHILD),
  ])
  if (nexusBalance !== fundAmount || childBalance !== expectedChild) {
    throw new Error(`funding reorged out: nexus=${nexusBalance} child=${childBalance}`)
  }
}

// Confirm a Nexus state tx under the merged miner. Stop-for-stable-tip keeps the
// pre-submit state deterministic; the merged miner (node builds the template with
// full state access) then confirms the tx while advancing the child too.
async function mineNexusTx(submitFn, confirmFn, desc) {
  await miner.stop()
  await submitFn()
  await restartMiner()
  await waitFor(confirmFn, desc, { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
}

async function fetchDeposit(user, amountDemanded, swapNonceHex, expectedKey = null) {
  const r = await childNode.rpc(
    'GET',
    `/api/deposit?demander=${user.address}&amount=${amountDemanded}&nonce=${swapNonceHex}&chainPath=${encodeURIComponent(childPathString)}`,
  )
  if (!r.ok) throw new Error(`deposit lookup failed: ${JSON.stringify(r.json)}`)
  if (r.json.chain !== CHILD) return null
  if (expectedKey && r.json.key !== expectedKey) return null
  return r.json
}

async function fetchReceipt(user, amountDemanded, swapNonceHex) {
  const r = await nexusNode.rpc(
    'GET',
    `/api/receipt-state?demander=${user.address}&amount=${amountDemanded}&nonce=${swapNonceHex}&chainPath=${encodeURIComponent(childPathString)}`,
  )
  if (!r.ok) throw new Error(`receipt lookup failed: ${JSON.stringify(r.json)}`)
  return r.json
}

function exactDeposit(d, amountDeposited) {
  return d &&
    d.exists === true &&
    d.amountDeposited === amountDeposited &&
    d.chain === CHILD &&
    typeof d.key === 'string' &&
    d.key.length > 0
    ? d
    : null
}

function exactReceipt(r, user) {
  return r &&
    r.exists === true &&
    r.directory === CHILD &&
    Array.isArray(r.chainPath) &&
    r.chainPath.join('/') === childPathString &&
    r.withdrawer === user.address &&
    typeof r.key === 'string' &&
    r.key.length > 0
    ? r
    : null
}

async function assertUserBalances(user, expectedNexus, expectedChild, label) {
  async function readBalancesOrNull() {
    try {
      const [nexusBalance, childBalance] = await Promise.all([
        nexusNode.balance(user.address, nexusDir),
        childNode.balance(user.address, CHILD),
      ])
      return { nexusBalance, childBalance }
    } catch {
      return null
    }
  }

  for (let attempt = 0; attempt < 4; attempt++) {
    await miner.mineUntil(async () => {
      const balances = await readBalancesOrNull()
      return balances?.nexusBalance === expectedNexus && balances?.childBalance === expectedChild ? balances : null
    }, {
      desc: `${label} exact balances`,
      timeoutMs: MINING_WAIT_MS,
      progress: async () => `${await nexusNode.height(nexusDir)}:${await childNode.height(CHILD)}`,
    })

    await miner.stop()
    await awaitStableTip(nexusNode, nexusDir, `${label} Nexus balance`)
    await awaitStableTip(childNode, CHILD, `${label} ${CHILD} balance`)
    const { nexusBalance, childBalance } = await waitFor(readBalancesOrNull, `${label} balance RPCs`, { timeoutMs: 15_000, intervalMs: 500 })
    if (nexusBalance === expectedNexus && childBalance === expectedChild) return
    console.log(`  ${label} balance changed after stop: nexus=${nexusBalance}/${expectedNexus} child=${childBalance}/${expectedChild}`)
  }
  const { nexusBalance, childBalance } = await waitFor(readBalancesOrNull, `${label} final balance RPCs`, { timeoutMs: 15_000, intervalMs: 500 })
  throw new Error(`${label} balance mismatch: nexus=${nexusBalance} expected=${expectedNexus} child=${childBalance} expected=${expectedChild}`)
}

async function runSwap({ label, user, amountDeposited, amountDemanded, swapNonceHex, fee = 1 }) {
  console.log(`\n--- ${label}: deposited=${amountDeposited} ${CHILD} demanded=${amountDemanded} Nexus (rate ${(amountDemanded / amountDeposited).toFixed(2)}x) ---`)

  await miner.stop()
  await awaitStableTip(nexusNode, nexusDir, 'Nexus before deposit')
  await awaitStableTip(childNode, CHILD, `${CHILD} before deposit`)
  const childBalance = await childNode.balance(user.address, CHILD)
  if (childBalance < amountDeposited + fee) {
    throw new Error(`insufficient canonical child balance before deposit: have=${childBalance} need=${amountDeposited + fee}`)
  }
  const depNonce = await childNode.nonce(user.address, CHILD)
  const depResult = await childNode.submitTx({
    chainPath: childPath,
    nonce: depNonce,
    signers: [user.address],
    fee,
    accountActions: [{ owner: user.address, delta: -(amountDeposited + fee) }],
    depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded, amountDeposited }],
  }, CHILD, user)
  if (!depResult.ok) throw new Error(`deposit failed: ${JSON.stringify(depResult)}`)
  console.log(`  [1/3] deposit accepted`)
  await restartMiner()

  const depState = await waitFor(async () => {
    const r = await fetchDeposit(user, amountDemanded, swapNonceHex)
    return exactDeposit(r, amountDeposited)
  }, 'deposit visible', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
  let depositKey = depState.key

  await mineNexusTx(
    async () => {
      const recNonce = await nexusNode.nonce(user.address, nexusDir)
      const recResult = await nexusNode.submitTx({
        chainPath: [nexusDir],
        nonce: recNonce,
        signers: [user.address],
        fee,
        accountActions: [{ owner: user.address, delta: -fee }],
        receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded, directory: CHILD }],
      }, nexusDir, user)
      if (!recResult.ok) throw new Error(`receipt failed: ${JSON.stringify(recResult)}`)
      console.log(`  [2/3] receipt accepted`)
    },
    async () => {
      const r = await fetchReceipt(user, amountDemanded, swapNonceHex)
      return exactReceipt(r, user)
    },
    'receipt visible'
  )
  const receiptState = exactReceipt(await fetchReceipt(user, amountDemanded, swapNonceHex), user)
  let receiptKey = receiptState.key
  await waitFor(async () => {
    const r = await fetchDeposit(user, amountDemanded, swapNonceHex, depositKey)
    return exactDeposit(r, amountDeposited)
  }, 'deposit still canonical after receipt', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })

  async function ensureDepositBeforeWithdrawal() {
    const existing = exactDeposit(await fetchDeposit(user, amountDemanded, swapNonceHex, depositKey), amountDeposited)
    if (existing) return

    const depNonce = await childNode.nonce(user.address, CHILD)
    const depResult = await childNode.submitTx({
      chainPath: childPath,
      nonce: depNonce,
      signers: [user.address],
      fee,
      accountActions: [{ owner: user.address, delta: -(amountDeposited + fee) }],
      depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded, amountDeposited }],
    }, CHILD, user)
    if (!depResult.ok) {
      const msg = JSON.stringify(depResult)
      if (!msg.includes('Duplicate') && !msg.includes('already') && !msg.includes('Nonce')) {
        throw new Error(`deposit restage failed before withdrawal: ${msg}`)
      }
    }
    await restartMiner()
    const restaged = await waitFor(async () => {
      const r = await fetchDeposit(user, amountDemanded, swapNonceHex)
      return exactDeposit(r, amountDeposited)
    }, 'deposit restaged before withdrawal', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
    depositKey = restaged.key
    await miner.stop()
    await awaitStableTip(nexusNode, nexusDir, 'Nexus after deposit restage')
    await awaitStableTip(childNode, CHILD, `${CHILD} after deposit restage`)
    const stable = exactDeposit(await fetchDeposit(user, amountDemanded, swapNonceHex, depositKey), amountDeposited)
    if (!stable) throw new Error(`deposit restage did not survive stable stop before withdrawal`)
  }

  async function ensureReceiptBeforeWithdrawal() {
    const existing = exactReceipt(await fetchReceipt(user, amountDemanded, swapNonceHex), user)
    if (existing && existing.key === receiptKey) return

    const recNonce = await nexusNode.nonce(user.address, nexusDir)
    const recResult = await nexusNode.submitTx({
      chainPath: [nexusDir],
      nonce: recNonce,
      signers: [user.address],
      fee,
      accountActions: [{ owner: user.address, delta: -fee }],
      receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded, directory: CHILD }],
    }, nexusDir, user)
    if (!recResult.ok) {
      const msg = JSON.stringify(recResult)
      if (!msg.includes('Duplicate') && !msg.includes('already') && !msg.includes('Nonce')) {
        throw new Error(`receipt restage failed before withdrawal: ${msg}`)
      }
    }
    await restartMiner()
    const restaged = await waitFor(async () => {
      const r = await fetchReceipt(user, amountDemanded, swapNonceHex)
      return exactReceipt(r, user)
    }, 'receipt restaged before withdrawal', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
    receiptKey = restaged.key
    await miner.stop()
    await awaitStableTip(nexusNode, nexusDir, 'Nexus after receipt restage')
    await awaitStableTip(childNode, CHILD, `${CHILD} after receipt restage`)
    const stable = exactReceipt(await fetchReceipt(user, amountDemanded, swapNonceHex), user)
    if (!stable || stable.key !== receiptKey) throw new Error(`receipt restage did not survive stable stop before withdrawal`)
  }

  async function proofPairReady() {
    const [deposit, receipt] = await Promise.all([
      fetchDeposit(user, amountDemanded, swapNonceHex, depositKey),
      fetchReceipt(user, amountDemanded, swapNonceHex),
    ])
    const exactDep = exactDeposit(deposit, amountDeposited)
    const exactRec = exactReceipt(receipt, user)
    return {
      deposit: exactDep && exactDep.key === depositKey ? exactDep : null,
      receipt: exactRec && exactRec.key === receiptKey ? exactRec : null,
    }
  }

  async function ensureProofPairBeforeWithdrawal() {
    for (let attempt = 0; attempt < 5; attempt++) {
      const ready = await proofPairReady()
      if (ready.deposit && ready.receipt) return
      if (!ready.deposit) await ensureDepositBeforeWithdrawal()
      if (!ready.receipt) await ensureReceiptBeforeWithdrawal()
      await miner.stop()
      await awaitStableTip(nexusNode, nexusDir, `Nexus proof pair ${attempt}`)
      await awaitStableTip(childNode, CHILD, `${CHILD} proof pair ${attempt}`)
      const stable = await proofPairReady()
      if (stable.deposit && stable.receipt) return
    }
    throw new Error(`deposit/receipt proof pair did not survive stable stop before withdrawal`)
  }

  await miner.stop()
  await awaitStableTip(nexusNode, nexusDir, 'Nexus before withdrawal')
  await awaitStableTip(childNode, CHILD, `${CHILD} before withdrawal`)
  await ensureProofPairBeforeWithdrawal()
  const wdNonce = await childNode.nonce(user.address, CHILD)
  const wdResult = await childNode.submitTx({
    chainPath: childPath,
    nonce: wdNonce,
    signers: [user.address],
    fee,
    accountActions: [{ owner: user.address, delta: amountDeposited - fee }],
    withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded, amountWithdrawn: amountDeposited }],
  }, CHILD, user)
  if (!wdResult.ok) throw new Error(`withdrawal failed: ${JSON.stringify(wdResult)}`)
  console.log(`  [3/3] withdrawal accepted`)
  await restartMiner()
  await waitFor(async () => {
    const r = await fetchDeposit(user, amountDemanded, swapNonceHex, depositKey)
    return r && r.exists === false ? r : null
  }, 'deposit consumed', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
  console.log(`  swap complete`)
  return { depositKey, receiptKey }
}

console.log(`\n[phase 2] swap A (pre-restart)...`)
console.log(`  user A: ${userA.address}`)
await fundAccount(userA.address, 5000, {
  fundChild: true,
  expectedChild: 5000,
  childFunder: userB,
  childFunderAddress: userB.address,
})
const swapNonceA = '00000000000000000000000000000001'
const swapA = await runSwap({ label: 'swap A', user: userA, amountDeposited: 100, amountDemanded: 250, swapNonceHex: swapNonceA })
await assertUserBalances(userA, 4999, 4998, 'swap A')

console.log(`\n[phase 3] restarting Nexus + ${CHILD} (preserving data-dirs)...`)
await miner.stop()
await Promise.all([
  nexusNode.awaitQuiesced(nexusDir, { timeoutMs: 45_000, idleMs: 2_000 }),
  childNode.awaitQuiesced(CHILD, { timeoutMs: 45_000, idleMs: 6_000 }),
])
const preRestartNexus = await awaitStableTip(nexusNode, nexusDir, 'Nexus pre-restart')
const preRestartChild = await awaitStableTip(childNode, CHILD, `${CHILD} pre-restart`)
await Promise.all([
  stopNodeAndWaitDown(nexusNode),
  stopNodeAndWaitDown(childNode),
])

nexusNode.start()
await nexusNode.waitForRPC(300_000)
childNode.start([
  '--genesis-hex', genesisHex,
  '--chain-directory', CHILD,
  '--chain-path', childPath.join('/'),
  '--subscribe-p2p', parentP2P,
  '--peer', childP2PAddress ?? parentP2P,
])
await childNode.waitForRPC(300_000)
console.log(`  nodes restarted`)

const recoveredNexus = await awaitStableTip(nexusNode, nexusDir, 'Nexus recovered pre-mining')
const recoveredChild = await awaitStableTip(childNode, CHILD, `${CHILD} recovered pre-mining`)
if (recoveredNexus.height !== preRestartNexus.height || recoveredNexus.tip !== preRestartNexus.tip) {
  throw new Error(`Nexus recovered to ${recoveredNexus.height}/${recoveredNexus.tip}, expected ${preRestartNexus.height}/${preRestartNexus.tip}`)
}
if (recoveredChild.height !== preRestartChild.height || recoveredChild.tip !== preRestartChild.tip) {
  throw new Error(`${CHILD} recovered to ${recoveredChild.height}/${recoveredChild.tip}, expected ${preRestartChild.height}/${preRestartChild.tip}`)
}

await restartMiner()
await waitFor(async () => {
  const [nh, ch] = await Promise.all([
    nexusNode.height(nexusDir),
    childNode.height(CHILD),
  ])
  return nh >= 1 && ch >= 1 ? { nexus: nh, child: ch } : null
}, 'post-restart mining resumed', { timeoutMs: MINING_WAIT_MS, intervalMs: 1_000 })
await miner.stop()
await awaitStableTip(nexusNode, nexusDir, 'Nexus after restart')
await awaitStableTip(childNode, CHILD, `${CHILD} after restart`)
await restartMiner()

console.log(`\n[phase 4] verifying swap A state survived restart...`)
const postDep = await fetchDeposit(userA, 250, swapNonceA, swapA.depositKey)
if (!postDep || postDep.exists !== false) {
  console.error(`  swap A deposit reappeared after restart`)
  net.teardown()
  process.exit(1)
}
console.log(`  swap A deposit still consumed`)
const postRec = exactReceipt(await fetchReceipt(userA, 250, swapNonceA), userA)
if (!postRec || postRec.key !== swapA.receiptKey) {
  console.error(`  swap A receipt vanished after restart`)
  net.teardown()
  process.exit(1)
}
console.log(`  swap A receipt still present`)

console.log(`\n[phase 5] swap B (post-restart, inverse rate)...`)
const initialHeight = await nexusNode.height(nexusDir)
await waitForProgress(
  async () => nexusNode.height(nexusDir),
  (h) => h > initialHeight,
  'nexus mining advance after restart',
  { stallMs: MINING_WAIT_MS, intervalMs: 1_000 },
)

console.log(`  user B: ${userB.address} (child genesis-premine account)`)
const userBChildBeforeSwap = childPremineAmount - 5001
await fundAccount(userB.address, 5000, { fundChild: false, expectedChild: userBChildBeforeSwap })
const swapNonceB = '00000000000000000000000000000002'
await runSwap({ label: 'swap B', user: userB, amountDeposited: 200, amountDemanded: 75, swapNonceHex: swapNonceB })
await assertUserBalances(userB, 4999, userBChildBeforeSwap - 2, 'swap B')

console.log(`\n=== RESULTS ===`)
console.log(`swap A executed pre-restart (rate 2.50x)`)
console.log(`Nexus + ${CHILD} restarted cleanly with data-dirs preserved`)
console.log(`swap A deposit/receipt state survived restart`)
console.log(`swap B executed post-restart (rate 0.375x inverse)`)

net.teardown()
await sleep(500)
process.exit(0)
