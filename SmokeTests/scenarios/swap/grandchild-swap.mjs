// Grandchild cross-chain swap: deposit/withdrawal on grandchild, receipt on the
// direct parent (Mid). Validates `withdrawalsAreValid` walks the recursive
// ChainLevel tree to find receiptState on the intermediate parent — not the
// nexus.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, genKeypair, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('grandchild')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts] = await allocPorts(1)
const MID = 'Mid'
const ALPHA = 'AlphaChain'
const BETA = 'BetaChain'

console.log('=== grandchild cross-chain swap smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const nexusNode = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: nexusPorts.port, rpcPort: nexusPorts.rpcPort }))
nexusNode.start()
await nexusNode.waitForRPC()
const minerIdent = await nexusNode.readIdentity()
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()
const premineUnits = 5
const fundAmount = premineUnits * 1024
console.log(`miner address: ${minerAddr}`)
console.log(`user address:  ${user.address}`)

const info = await nexusNode.chainInfo()
const nexusDir = info.nexus
console.log(`initial chains: ${info.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

console.log(`\n[A] Deploying ${MID} as child of ${nexusDir}...`)
const [midPorts] = await allocPorts(1)
const midNode = await nexusNode.spawnChild({
  directory: MID,
  parentDirectory: nexusDir,
  ports: midPorts,
  premine: premineUnits,
  premineRecipient: user.address,
})
net.add(midNode)

console.log(`\n[B] Deploying grandchildren ${ALPHA} and ${BETA} as children of ${MID}...`)
const [alphaPorts] = await allocPorts(1)
const alphaNode = await midNode.spawnChild({
  directory: ALPHA,
  parentDirectory: MID,
  ports: alphaPorts,
  premine: premineUnits,
  premineRecipient: user.address,
})
net.add(alphaNode)

const [betaPorts] = await allocPorts(1)
const betaNode = await midNode.spawnChild({
  directory: BETA,
  parentDirectory: MID,
  ports: betaPorts,
  premine: premineUnits,
  premineRecipient: user.address,
})
net.add(betaNode)

// LatticeMiner needs all levels: nexus + mid + alpha + beta
const miner = new LatticeMiner(nexusNode, [midNode, alphaNode, betaNode])
net.addMiner(miner)
await miner.start()

console.log(`\n[C] Verifying chain topology...`)
// In per-process mode each node only shows its own chain — check the right node per chain.
const nexusInfo = await nexusNode.chainInfo()
const midInfo = await midNode.chainInfo()
const alphaInfo = await alphaNode.chainInfo()
const betaInfo = await betaNode.chainInfo()
const nexusOnly = nexusInfo.chains?.length === 1 && nexusInfo.chains[0]?.directory === nexusDir
const midEntry = midInfo.chains?.find(c => c.directory === MID && c.chainPath?.join('/') === `${nexusDir}/${MID}`)
const alphaEntry = alphaInfo.chains?.find(c => c.directory === ALPHA && c.chainPath?.join('/') === `${nexusDir}/${MID}/${ALPHA}`)
const betaEntry = betaInfo.chains?.find(c => c.directory === BETA && c.chainPath?.join('/') === `${nexusDir}/${MID}/${BETA}`)
if (!nexusOnly) throw new Error(`nexusNode leaked child chain views: ${JSON.stringify(nexusInfo.chains)}`)
if (!midEntry) throw new Error(`chain ${MID} not owned by midNode after deploy: ${JSON.stringify(midInfo.chains)}`)
if (!alphaEntry) throw new Error(`chain ${ALPHA} not owned by alphaNode after deploy: ${JSON.stringify(alphaInfo.chains)}`)
if (!betaEntry) throw new Error(`chain ${BETA} not owned by betaNode after deploy: ${JSON.stringify(betaInfo.chains)}`)
console.log(`  ✓ ${MID}.parentDirectory = ${midEntry.parentDirectory}`)
console.log(`  ✓ ${ALPHA}.parentDirectory = ${alphaEntry.parentDirectory}`)
console.log(`  ✓ ${BETA}.parentDirectory = ${betaEntry.parentDirectory}`)

console.log(`\n[D] Waiting for chains to mine blocks...`)
async function totalChildHeight() {
  const [midHeight, alphaHeight, betaHeight] = await Promise.all([
    midNode.height(MID),
    alphaNode.height(ALPHA),
    betaNode.height(BETA),
  ])
  return `${midHeight}:${alphaHeight}:${betaHeight}`
}

await miner.mineUntil(async () => {
  const [midHeight, alphaHeight, betaHeight] = await Promise.all([
    midNode.height(MID),
    alphaNode.height(ALPHA),
    betaNode.height(BETA),
  ])
  if (midHeight >= 3 && alphaHeight >= 3 && betaHeight >= 3) return { midHeight, alphaHeight, betaHeight }
  return null
}, {
  desc: 'initial child heights',
  timeoutMs: 120_000,
  progress: totalChildHeight,
})

const minerMid0 = await midNode.balance(minerAddr, MID)
const minerAlpha0 = await alphaNode.balance(minerAddr, ALPHA)
const minerBeta0 = await betaNode.balance(minerAddr, BETA)
console.log(`  miner balances: ${MID}=${minerMid0} ${ALPHA}=${minerAlpha0} ${BETA}=${minerBeta0}`)

// Chain paths for the hierarchy
const midPath = [nexusDir, MID]
const alphaPath = [nexusDir, MID, ALPHA]
const betaPath = [nexusDir, MID, BETA]

async function awaitStableTip(node, dir, label, { timeoutMs = 120_000, idleMs = 5_000 } = {}) {
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
  await Promise.all([
    awaitStableTip(nexusNode, nexusDir, `${nexusDir} ${label}`),
    awaitStableTip(midNode, MID, `${MID} ${label}`),
    awaitStableTip(alphaNode, ALPHA, `${ALPHA} ${label}`),
    awaitStableTip(betaNode, BETA, `${BETA} ${label}`),
  ])
}

console.log(`\n[E] Pausing mining to verify genesis-premine balances...`)
await miner.stop()
await awaitStableChains('before swap cycles')
await miner.start()

const userMid0 = await midNode.balance(user.address, MID)
const userAlpha0 = await alphaNode.balance(user.address, ALPHA)
const userBeta0 = await betaNode.balance(user.address, BETA)
if (userMid0 !== fundAmount || userAlpha0 !== fundAmount || userBeta0 !== fundAmount) {
  throw new Error(`unexpected genesis premine balances: ${MID}=${userMid0} ${ALPHA}=${userAlpha0} ${BETA}=${userBeta0}`)
}
const expectedDeltas = { [MID]: 0, [ALPHA]: 0, [BETA]: 0 }
console.log(`  user balances: ${MID}=${userMid0} ${ALPHA}=${userAlpha0} ${BETA}=${userBeta0}`)

async function readUserBalances() {
  const [mid, alpha, beta] = await Promise.all([
    midNode.balance(user.address, MID),
    alphaNode.balance(user.address, ALPHA),
    betaNode.balance(user.address, BETA),
  ])
  return { [MID]: mid, [ALPHA]: alpha, [BETA]: beta }
}

function expectedBalances() {
  return {
    [MID]: userMid0 + expectedDeltas[MID],
    [ALPHA]: userAlpha0 + expectedDeltas[ALPHA],
    [BETA]: userBeta0 + expectedDeltas[BETA],
  }
}

function balancesEqualExpected(balances) {
  const expected = expectedBalances()
  return balances[MID] === expected[MID] &&
    balances[ALPHA] === expected[ALPHA] &&
    balances[BETA] === expected[BETA]
}

function balanceSummary(balances) {
  const expected = expectedBalances()
  return [MID, ALPHA, BETA]
    .map(dir => `${dir}=${balances[dir]} expected=${expected[dir]}`)
    .join(' ')
}

async function waitForExpectedBalances(label, { timeoutMs = 180_000 } = {}) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await miner.mineUntil(async () => {
      const balances = await readUserBalances()
      return balancesEqualExpected(balances) ? balances : null
    }, {
      desc: `${label}: expected balances canonical`,
      timeoutMs,
      progress: totalChildHeight,
    })

    await miner.stop()
    await awaitStableChains(`${label} stable balance check ${attempt}`)
    const stableBalances = await readUserBalances()
    if (balancesEqualExpected(stableBalances)) return stableBalances
    console.log(`  ${label}: balances changed after stop (${balanceSummary(stableBalances)}); continuing mining`)
  }
  throw new Error(`${label}: balances never stabilized at expected values (${balanceSummary(await readUserBalances())})`)
}

async function runCycle(grandchild, index) {
  const swapNonceHex = BigInt(index + 1).toString(16).padStart(32, '0')
  const amount = 500
  const fee = 1
  let canonicalDepositFee = fee
  let canonicalDepositKey = null
  let cycleStartBalance = null
  let withdrawalFee = null
  const submittedDepositFees = new Set([fee])
  console.log(`  [cycle ${index}] grandchild=${grandchild} amount=${amount} swapNonce=0x${swapNonceHex.slice(0, 12)}...`)

  const grandchildNode = grandchild === ALPHA ? alphaNode : betaNode
  const grandchildPath = grandchild === ALPHA ? alphaPath : betaPath
  const grandchildPathString = grandchildPath.join('/')

  async function fetchDeposit() {
    const r = await grandchildNode.rpc(
      'GET',
      `/api/deposit?demander=${user.address}&amount=${amount}&nonce=${swapNonceHex}&chainPath=${encodeURIComponent(grandchildPathString)}`,
    )
    if (!r.ok) throw new Error(`deposit lookup failed on ${grandchild}: ${JSON.stringify(r.json)}`)
    if (r.json.chain !== grandchild || r.json.key !== canonicalDepositKey) return null
    return r.json
  }

  function exactDeposit(d) {
    return d &&
      d.exists === true &&
      d.amountDeposited === amount &&
      d.chain === grandchild &&
      typeof d.key === 'string' &&
      d.key.length > 0
      ? d
      : null
  }

  function exactReceipt(r) {
    return r &&
      r.exists === true &&
      r.directory === grandchild &&
      Array.isArray(r.chainPath) &&
      r.chainPath.join('/') === grandchildPathString &&
      r.withdrawer === user.address &&
      typeof r.key === 'string' &&
      r.key.length > 0
      ? r
      : null
  }

  async function rememberCanonicalDeposit(deposit) {
    const balance = await grandchildNode.balance(user.address, grandchild)
    const inferredFee = cycleStartBalance - balance - amount
    if (!Number.isInteger(inferredFee) || !submittedDepositFees.has(inferredFee)) {
      throw new Error(`could not infer canonical ${grandchild} deposit fee: start=${cycleStartBalance} current=${balance} amount=${amount}`)
    }
    canonicalDepositFee = inferredFee
    canonicalDepositKey = deposit.key
    return deposit
  }

  async function ensureDepositCanonical(label, { timeoutMs = 120_000 } = {}) {
    for (let attempt = 0; attempt < 6; attempt++) {
      const existing = await grandchildNode.getDeposit(user.address, amount, swapNonceHex, grandchild)
      const exactExisting = exactDeposit(existing)
      if (exactExisting) {
        return rememberCanonicalDeposit(exactExisting)
      }

      await miner.stop()
      await awaitStableChains(`${label} restage ${attempt} on ${grandchild}`)

      const balance = await grandchildNode.balance(user.address, grandchild)
      const attemptFee = fee + attempt
      if (balance < amount + attemptFee) {
        throw new Error(`insufficient canonical ${grandchild} balance to restage deposit: have=${balance} need=${amount + attemptFee}`)
      }

      const nonce = await grandchildNode.nonce(user.address, grandchild)
      const result = await grandchildNode.submitTx({
        chainPath: grandchildPath, nonce, signers: [user.address], fee: attemptFee,
        accountActions: [{ owner: user.address, delta: -(amount + attemptFee) }],
        depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
      }, grandchild, user)
      if (result.ok) submittedDepositFees.add(attemptFee)
      if (!result.ok) {
        const msg = JSON.stringify(result)
        if (!msg.includes('Duplicate transaction') && !msg.includes('already') && !msg.includes('duplicate')) {
          throw new Error(`deposit restage failed on ${grandchild}: ${msg}`)
        }
      }

      try {
        const deposit = await miner.mineUntil(async () => {
          const r = await grandchildNode.getDeposit(user.address, amount, swapNonceHex, grandchild)
          return exactDeposit(r)
        }, {
          desc: `${label}: deposit canonical on ${grandchild}`,
          timeoutMs,
          progress: totalChildHeight,
        })
        return rememberCanonicalDeposit(deposit)
      } catch (err) {
        if (attempt === 5) throw err
        await sleep(1000)
      }
    }
    throw new Error(`deposit did not become canonical on ${grandchild}`)
  }

  await miner.stop()
  await awaitStableChains(`before deposit on ${grandchild}`)
  const grandchildBalance = await grandchildNode.balance(user.address, grandchild)
  cycleStartBalance = grandchildBalance
  if (grandchildBalance < amount + fee) {
    throw new Error(`insufficient canonical ${grandchild} balance before deposit: have=${grandchildBalance} need=${amount + fee}`)
  }
  const depNonce = await grandchildNode.nonce(user.address, grandchild)
  const depResult = await grandchildNode.submitTx({
    chainPath: grandchildPath, nonce: depNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -(amount + fee) }],
    depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
  }, grandchild, user)
  if (!depResult.ok) throw new Error(`deposit failed: ${JSON.stringify(depResult)}`)
  const initialDeposit = await miner.mineUntil(async () => {
    const r = await grandchildNode.getDeposit(user.address, amount, swapNonceHex, grandchild)
    return exactDeposit(r)
  }, {
    desc: `deposit visible on ${grandchild}`,
    timeoutMs: 120_000,
    progress: totalChildHeight,
  })
  await rememberCanonicalDeposit(initialDeposit)

  await miner.stop()
  await awaitStableChains(`before receipt for ${grandchild}`)
  const recNonce = await midNode.nonce(user.address, MID)
  const recResult = await midNode.submitTx({
    chainPath: midPath, nonce: recNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -fee }],
    receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: grandchild }],
  }, MID, user)
  if (!recResult.ok) throw new Error(`receipt failed: ${JSON.stringify(recResult)}`)
  await miner.mineUntil(async () => {
    const r = await midNode.getReceipt(user.address, amount, swapNonceHex, grandchild)
    return exactReceipt(r)
  }, {
    desc: `receipt visible for ${grandchild}`,
    timeoutMs: 120_000,
    progress: totalChildHeight,
  })

  await ensureDepositCanonical('after receipt')

  let wdResult = null
  let consumed = false
  for (let attempt = 0; attempt < 6 && !consumed; attempt++) {
    const attemptFee = fee + attempt
    await ensureDepositCanonical(`before withdrawal attempt ${attempt}`)

    await miner.stop()
    await awaitStableChains(`before withdrawal on ${grandchild}`)
    const wdNonce = await grandchildNode.nonce(user.address, grandchild)
    wdResult = await grandchildNode.submitTx({
      chainPath: grandchildPath, nonce: wdNonce, signers: [user.address], fee: attemptFee,
      accountActions: [{ owner: user.address, delta: amount - attemptFee }],
      withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
    }, grandchild, user)
    if (wdResult.ok) {
      try {
        await miner.mineUntil(async () => {
          const d = await fetchDeposit()
          return d && d.exists === false ? d : null
        }, {
          desc: `deposit consumed on ${grandchild}`,
          timeoutMs: 120_000,
          progress: totalChildHeight,
        })
        consumed = true
        withdrawalFee = attemptFee
        break
      } catch (err) {
        if (attempt === 5) throw err
        await sleep(1000)
        continue
      }
    }
    const msg = JSON.stringify(wdResult)
    if (!msg.includes('no corresponding deposit') &&
        !msg.includes('RBF underpays conflicting package') &&
        !msg.includes('Duplicate transaction') &&
        !msg.includes('already') &&
        !msg.includes('Nonce')) break
    await sleep(1000)
  }
  if (!wdResult?.ok) throw new Error(`withdrawal failed: ${JSON.stringify(wdResult)}`)
  if (!consumed) throw new Error(`withdrawal did not consume deposit: ${JSON.stringify(wdResult)}`)
  expectedDeltas[MID] -= fee
  expectedDeltas[grandchild] -= canonicalDepositFee + withdrawalFee
  await waitForExpectedBalances(`after ${grandchild} cycle`)

  console.log(`    ✓ cycle complete (expected ${grandchild} delta=${-(canonicalDepositFee + withdrawalFee)}, ${MID} delta=-${fee})`)
}

console.log(`\n[F] Running cycle on ${ALPHA}...`)
await runCycle(ALPHA, 0)

console.log(`\n[G] Running cycle on ${BETA}...`)
await runCycle(BETA, 100)

const finalBalances = await waitForExpectedBalances('final grandchild swap')
const userMid1 = finalBalances[MID]
const userAlpha1 = finalBalances[ALPHA]
const userBeta1 = finalBalances[BETA]

const actualDeltas = {
  [MID]: userMid1 - userMid0,
  [ALPHA]: userAlpha1 - userAlpha0,
  [BETA]: userBeta1 - userBeta0,
}
let failed = false
console.log(`\n=== RESULTS ===`)
for (const [dir, before, after] of [[MID, userMid0, userMid1], [ALPHA, userAlpha0, userAlpha1], [BETA, userBeta0, userBeta1]]) {
  const actual = actualDeltas[dir]
  const expected = expectedDeltas[dir]
  const ok = actual === expected
  if (!ok) failed = true
  console.log(`${dir.padEnd(8)} before=${before}  after=${after}  delta=${actual}  expected=${expected}  ${ok ? '✓' : '✗'}`)
}
if (failed) {
  console.error(`\n✗ final balance deltas did not match expected grandchild swap fees`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`✓ receipt state lived on ${MID} (intermediate parent), validating tree-walk in withdrawalsAreValid`)

net.teardown()
await sleep(500)
process.exit(0)
