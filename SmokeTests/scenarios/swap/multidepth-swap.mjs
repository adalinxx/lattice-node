// Multi-depth cross-chain swap. Tree:
//
//     Nexus ─┬─ ChainB ── ChainD
//            └─ ChainC ── ChainE ── ChainG
//
// Runs swap cycles where the receipt chain is at depths 0, 1, and 2 — the
// deepest receipt chain (E for source G) exercises the recursive tree-walk in
// `withdrawalsAreValid` at depth-2 from the nexus.

import { rmSync, mkdirSync, readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, genKeypair, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('multidepth')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [{ port, rpcPort }] = await allocPorts(1)

console.log('=== multi-depth cross-chain swap smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const funder = genKeypair()
const node = net.add(new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port,
  rpcPort,
  coinbaseAddress: funder.address,
}))
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()
console.log(`miner address: ${minerAddr}`)
console.log(`funder address: ${funder.address}`)
console.log(`user address:  ${user.address}`)

const info = await node.chainInfo()
const NEXUS = info.nexus
const B = 'ChainB', C = 'ChainC', D = 'ChainD', E = 'ChainE', G = 'ChainG'
// This scenario stresses multi-depth swap validation, not difficulty retargeting.
// Keep local child production at max target so the deepest child advances deterministically.
const fastChildSpec = { targetBlockTime: 1 }
const premineUnits = 5
const fundAmount = premineUnits * 1024
const PATH = {
  [NEXUS]: [NEXUS],
  [B]: [NEXUS, B], [C]: [NEXUS, C],
  [D]: [NEXUS, B, D], [E]: [NEXUS, C, E],
  [G]: [NEXUS, C, E, G],
}
const PARENT = { [B]: NEXUS, [C]: NEXUS, [D]: B, [E]: C, [G]: E }

async function registerWithNexus(child) {
  const authToken = readFileSync(`${child.dir}/.cookie`, 'utf8').trim()
  const r = await node.rpc('POST', '/api/chain/register-rpc', {
    chainPath: child.chainPath,
    endpoint: child.base,
    authToken,
  })
  if (!r.ok) throw new Error(`register ${child.name} with Nexus failed: ${JSON.stringify(r.json)}`)
}

console.log(`\n[A] Deploying ${B}, ${C} as children of ${NEXUS}...`)
const nodeB = net.add(await node.spawnChild({ directory: B, parentDirectory: NEXUS, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const nodeC = net.add(await node.spawnChild({ directory: C, parentDirectory: NEXUS, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))

console.log(`\n[B] Deploying ${D} under ${B}, ${E} under ${C}...`)
const nodeD = net.add(await nodeB.spawnChild({ directory: D, parentDirectory: B, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const nodeE = net.add(await nodeC.spawnChild({ directory: E, parentDirectory: C, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))

console.log(`\n[C] Deploying ${G} under ${E}...`)
const nodeG = net.add(await nodeE.spawnChild({ directory: G, parentDirectory: E, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))

for (const child of [nodeB, nodeC, nodeD, nodeE, nodeG]) await registerWithNexus(child)

const chainNode = {
  [NEXUS]: node,
  [B]: nodeB,
  [C]: nodeC,
  [D]: nodeD,
  [E]: nodeE,
  [G]: nodeG,
}

async function awaitStableTip(dir, { timeoutMs = 90_000, idleMs = 5_000 } = {}) {
  const nodeForChain = chainNode[dir]
  const start = Date.now()
  let lastHeight = await nodeForChain.height(dir)
  let lastTip = await nodeForChain.tip(dir)
  let stableSince = Date.now()
  while (Date.now() - start < timeoutMs) {
    await sleep(500)
    const [height, tip] = await Promise.all([
      nodeForChain.height(dir),
      nodeForChain.tip(dir),
    ])
    if (height === lastHeight && tip === lastTip) {
      if (Date.now() - stableSince >= idleMs) return { height, tip }
    } else {
      lastHeight = height
      lastTip = tip
      stableSince = Date.now()
    }
  }
  throw new Error(`timed out waiting for ${dir} stable tip`)
}

console.log(`\n[D] Verifying chain topology...`)
for (const [dir, expectedParent] of [[B, NEXUS], [C, NEXUS], [D, B], [E, C], [G, E]]) {
  const info = await chainNode[dir].chainInfo()
  const chain = info.chains.find((c) => c.directory === dir)
  if (!chain) throw new Error(`chain ${dir} not present`)
  if (chain.parentDirectory !== expectedParent) {
    throw new Error(`${dir}: expected parent=${expectedParent} got ${chain.parentDirectory}`)
  }
  console.log(`  ✓ ${dir}.parentDirectory = ${chain.parentDirectory}`)
}

console.log(`\n[E] Waiting for chains to mine blocks...`)
const childNodes = [nodeB, nodeC, nodeD, nodeE, nodeG]
async function totalHeightProgress() {
  const heights = await Promise.all([NEXUS, B, C, D, E, G].map((dir) => chainNode[dir].height(dir)))
  return heights.join(':')
}
await node.mineUntil(async () => {
  const heights = await Promise.all([B, C, D, E, G].map((dir) => chainNode[dir].height(dir)))
  return heights.every((height) => height >= 3) ? heights : null
}, NEXUS, {
  childNodes,
  desc: 'multi-depth child heights',
  timeoutMs: 120_000,
  progress: totalHeightProgress,
})

const rootFunderBalance = await node.balance(funder.address, PATH[NEXUS])
if (rootFunderBalance < fundAmount + 100) {
  console.error(`Insufficient funder balance on ${NEXUS}: ${rootFunderBalance}`); net.teardown(); process.exit(1)
}

console.log(`\n[F] Pausing mining to stage Nexus fund tx...`)
await node.stopMining(NEXUS)
for (const dir of [NEXUS, B, C, D, E, G]) await chainNode[dir].awaitQuiesced(dir)

async function stageFund(chain) {
  const chainPath = PATH[chain]
  for (let attempt = 0; attempt < 6; attempt++) {
    const base = await node.nonce(funder.address, PATH[chain])
    for (const n of [base, base + 1]) {
      const r = await node.submitTx({
        chainPath, nonce: n, signers: [funder.address], fee: 1,
        accountActions: [
          { owner: funder.address, delta: -(fundAmount + 1) },
          { owner: user.address, delta: fundAmount },
        ],
      }, chain, funder)
      if (r.ok) { console.log(`  staged ${chain} nonce=${n}`); return }
      const msg = JSON.stringify(r)
      if (msg.includes('Duplicate transaction')) {
        console.log(`  staged ${chain} nonce=${n} (already pending)`)
        return
      }
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

console.log(`\n[G] Funding user on Nexus; child balances come from genesis premine...`)
await stageFund(NEXUS)

console.log(`\n[H] Resuming mining; waiting for fund inclusion...`)
let funded = false
for (let round = 0; round < 5 && !funded; round++) {
  await node.mineUntil(async () => {
    const balance = await node.balance(user.address, PATH[NEXUS])
    if (balance > fundAmount) throw new Error(`duplicate Nexus setup funding detected: ${balance} > ${fundAmount}`)
    return balance === fundAmount ? balance : null
  }, NEXUS, {
    childNodes,
    desc: 'multi-depth Nexus funding balance',
    timeoutMs: 180_000,
    progress: totalHeightProgress,
  })
  await node.stopMining(NEXUS)
  for (const dir of [NEXUS, B, C, D, E, G]) await awaitStableTip(dir)
  const nexusBalance = await node.balance(user.address, PATH[NEXUS])
  if (nexusBalance === fundAmount) {
    funded = true
    break
  }
  if (nexusBalance > fundAmount) throw new Error(`duplicate Nexus setup funding detected after stable stop: ${nexusBalance} > ${fundAmount}`)
  console.log(`  Nexus funding reorged out; restaging`)
  await stageFund(NEXUS)
}
if (!funded) throw new Error('funding did not survive reorg settling')
for (const dir of [B, C, D, E, G]) {
  const balance = await node.balance(user.address, PATH[dir])
  if (balance !== fundAmount) throw new Error(`unexpected ${dir} genesis premine balance: ${balance}`)
}
await node.startMining(NEXUS, { childNodes })

const before = {}
for (const dir of [NEXUS, B, C, D, E, G]) before[dir] = await node.balance(user.address, PATH[dir])
console.log(`  user balances: ${Object.entries(before).map(([k, v]) => `${k}=${v}`).join(' ')}`)

const expectedDeltas = Object.fromEntries([NEXUS, B, C, D, E, G].map((dir) => [dir, 0]))
let swapCounter = 0

async function readUserBalances() {
  const entries = await Promise.all([NEXUS, B, C, D, E, G].map(async (dir) => [dir, await node.balance(user.address, PATH[dir])]))
  return Object.fromEntries(entries)
}

function balancesEqualExpected(balances) {
  return [NEXUS, B, C, D, E, G].every((dir) => balances[dir] === before[dir] + expectedDeltas[dir])
}

function balanceSummary(balances) {
  return [NEXUS, B, C, D, E, G]
    .map((dir) => `${dir}=${balances[dir]} expected=${before[dir] + expectedDeltas[dir]}`)
    .join(' ')
}

async function waitForExpectedBalances(label, { timeoutMs = 180_000 } = {}) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await node.mineUntil(async () => {
      const balances = await readUserBalances()
      return balancesEqualExpected(balances) ? balances : null
    }, NEXUS, {
      childNodes,
      desc: `${label}: expected balances canonical`,
      timeoutMs,
      progress: totalHeightProgress,
    })

    await node.stopMining(NEXUS)
    for (const dir of [NEXUS, B, C, D, E, G]) await awaitStableTip(dir)
    const stableBalances = await readUserBalances()
    if (balancesEqualExpected(stableBalances)) return stableBalances
    console.log(`  ${label}: balances changed after stop (${balanceSummary(stableBalances)}); continuing mining`)
  }
  throw new Error(`${label}: balances never stabilized at expected values (${balanceSummary(await readUserBalances())})`)
}

async function runCycle(source, label) {
  const receiptChain = PARENT[source]
  const swapNonceHex = BigInt(++swapCounter).toString(16).padStart(32, '0')
  const amount = 500
  const fee = 1
  const sourceBalanceBefore = await node.balance(user.address, PATH[source])
  const receiptBalanceBefore = await node.balance(user.address, PATH[receiptChain])
  const sourcePathString = PATH[source].join('/')
  let canonicalDepositFee = null
  let canonicalDepositKey = null
  let receiptFee = null
  let withdrawalFee = null
  const submittedDepositFees = new Set()
  const submittedReceiptFees = new Set()
  const submittedWithdrawalFees = new Set()
  console.log(`  [${label}] source=${source} receiptChain=${receiptChain} amount=${amount}`)

  async function fetchDeposit(expectedKey = null) {
    const r = await node.rpc(
      'GET',
      `/api/deposit?demander=${user.address}&amount=${amount}&nonce=${swapNonceHex}&chainPath=${encodeURIComponent(sourcePathString)}`,
    )
    if (r.status === 0) return null
    if (!r.ok) throw new Error(`deposit lookup failed for ${label}: ${JSON.stringify(r.json)}`)
    if (r.json.chain !== source) return null
    if (expectedKey && r.json.key !== expectedKey) return null
    return r.json
  }

  async function fetchReceipt() {
    const r = await node.rpc(
      'GET',
      `/api/receipt-state?demander=${user.address}&amount=${amount}&nonce=${swapNonceHex}&chainPath=${encodeURIComponent(sourcePathString)}`,
    )
    if (r.status === 0) return null
    if (!r.ok) throw new Error(`receipt lookup failed for ${label}: ${JSON.stringify(r.json)}`)
    return r.json
  }

  function exactDeposit(r) {
    return r &&
      r.exists === true &&
      r.amountDeposited === amount &&
      r.chain === source &&
      typeof r.key === 'string' &&
      r.key.length > 0
      ? r
      : null
  }

  function exactReceipt(r) {
    return r &&
      r.exists === true &&
      r.directory === source &&
      Array.isArray(r.chainPath) &&
      r.chainPath.join('/') === sourcePathString &&
      r.withdrawer === user.address &&
      typeof r.key === 'string' &&
      r.key.length > 0
      ? r
      : null
  }

  async function rememberCanonicalDeposit(deposit) {
    const balance = await node.balance(user.address, PATH[source])
    const inferredFee = sourceBalanceBefore - balance - amount
    if (!Number.isInteger(inferredFee) || !submittedDepositFees.has(inferredFee)) {
      throw new Error(`could not infer canonical deposit fee for ${label}: start=${sourceBalanceBefore} current=${balance} amount=${amount}`)
    }
    canonicalDepositFee = inferredFee
    canonicalDepositKey = deposit.key
    return deposit
  }

  async function rememberCanonicalReceipt(receipt) {
    const balance = await node.balance(user.address, PATH[receiptChain])
    const inferredFee = receiptBalanceBefore - balance
    if (!Number.isInteger(inferredFee) || !submittedReceiptFees.has(inferredFee)) {
      throw new Error(`could not infer canonical receipt fee for ${label}: start=${receiptBalanceBefore} current=${balance}`)
    }
    receiptFee = inferredFee
    return receipt
  }

  async function rememberCanonicalWithdrawal(consumedDeposit) {
    const balance = await node.balance(user.address, PATH[source])
    const inferredFee = sourceBalanceBefore - canonicalDepositFee - balance
    if (!Number.isInteger(inferredFee) || !submittedWithdrawalFees.has(inferredFee)) {
      throw new Error(`could not infer canonical withdrawal fee for ${label}: start=${sourceBalanceBefore} current=${balance} depositFee=${canonicalDepositFee}`)
    }
    withdrawalFee = inferredFee
    return consumedDeposit
  }

  async function ensureDepositVisible(labelSuffix, { timeoutMs = 90_000 } = {}) {
    let depResult = null
    for (let attempt = 0; attempt < 6; attempt++) {
      const existing = exactDeposit(await fetchDeposit())
      if (existing) return { deposit: await rememberCanonicalDeposit(existing), result: depResult }

      const attemptFee = fee + attempt
      const balance = await node.balance(user.address, PATH[source])
      if (balance < amount + attemptFee) {
        throw new Error(`insufficient ${source} balance to stage deposit: have=${balance} need=${amount + attemptFee}`)
      }

      const depNonce = await node.nonce(user.address, PATH[source])
      depResult = await node.submitTx({
        chainPath: PATH[source], nonce: depNonce, signers: [user.address], fee: attemptFee,
        accountActions: [{ owner: user.address, delta: -(amount + attemptFee) }],
        depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
      }, source, user)
      if (depResult.ok) submittedDepositFees.add(attemptFee)
      if (!depResult.ok) {
        const msg = JSON.stringify(depResult)
        if (!msg.includes('Nonce') &&
            !msg.includes('confirmed') &&
            !msg.includes('RBF') &&
            !msg.includes('Duplicate') &&
            !msg.includes('already')) {
          throw new Error(`deposit on ${source} failed: ${msg}`)
        }
        await sleep(1000)
        continue
      }

      try {
        const deposit = await node.mineUntil(async () => {
          const r = await fetchDeposit()
          return exactDeposit(r)
        }, NEXUS, {
          childNodes,
          desc: `${labelSuffix}: deposit visible on ${source}`,
          timeoutMs,
          progress: totalHeightProgress,
        })
        return { deposit: await rememberCanonicalDeposit(deposit), result: depResult }
      } catch (err) {
        if (attempt === 5) throw err
        await sleep(1000)
      }
    }
    throw new Error(`${labelSuffix}: deposit on ${source} did not become visible`)
  }

  const initialDeposit = await ensureDepositVisible(label)
  if (!initialDeposit.deposit) {
    throw new Error(`deposit on ${source} failed: ${JSON.stringify(initialDeposit.result)}`)
  }

  let recResult = null
  let receiptVisible = false
  for (let attempt = 0; attempt < 6 && !receiptVisible; attempt++) {
    const existing = exactReceipt(await fetchReceipt())
    if (existing) {
      await rememberCanonicalReceipt(existing)
      receiptVisible = true
      break
    }

    const attemptFee = fee + attempt
    const recNonce = await node.nonce(user.address, PATH[receiptChain])
    recResult = await node.submitTx({
      chainPath: PATH[receiptChain], nonce: recNonce, signers: [user.address], fee: attemptFee,
      accountActions: [{ owner: user.address, delta: -attemptFee }],
      receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: source }],
    }, receiptChain, user)
    if (recResult.ok) submittedReceiptFees.add(attemptFee)
    if (!recResult.ok) {
      const msg = JSON.stringify(recResult)
      if (!msg.includes('Nonce') && !msg.includes('confirmed') && !msg.includes('RBF')) break
      await sleep(1000)
      continue
    }
    try {
      const receipt = await node.mineUntil(async () => {
        const r = await fetchReceipt()
        return exactReceipt(r)
      }, NEXUS, {
        childNodes,
        desc: `receipt visible for ${source} on ${receiptChain}`,
        timeoutMs: 90_000,
        progress: totalHeightProgress,
      })
      await rememberCanonicalReceipt(receipt)
      receiptVisible = true
      break
    } catch (err) {
      if (attempt === 5) throw err
      await sleep(1000)
    }
  }
  if (!recResult?.ok || !receiptVisible) throw new Error(`receipt on ${receiptChain} failed: ${JSON.stringify(recResult)}`)

  let wdResult = null
  let consumed = false
  for (let attempt = 0; attempt < 6 && !consumed; attempt++) {
    const attemptFee = fee + attempt
    await ensureDepositVisible(`before withdrawal attempt ${attempt}`)
    const wdNonce = await node.nonce(user.address, PATH[source])
    wdResult = await node.submitTx({
      chainPath: PATH[source], nonce: wdNonce, signers: [user.address], fee: attemptFee,
      accountActions: [{ owner: user.address, delta: amount - attemptFee }],
      withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
    }, source, user)
    if (wdResult.ok) submittedWithdrawalFees.add(attemptFee)
    if (wdResult.ok) {
      try {
        const consumedDeposit = await node.mineUntil(async () => {
          const d = await fetchDeposit(canonicalDepositKey)
          return d && d.exists === false ? d : null
        }, NEXUS, {
          childNodes,
          desc: `deposit consumed on ${source}`,
          timeoutMs: 120_000,
          progress: totalHeightProgress,
        })
        await rememberCanonicalWithdrawal(consumedDeposit)
        consumed = true
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
  if (!wdResult?.ok) throw new Error(`withdrawal on ${source} failed: ${JSON.stringify(wdResult)}`)
  if (!consumed) throw new Error(`withdrawal on ${source} did not consume deposit: ${JSON.stringify(wdResult)}`)

  expectedDeltas[source] -= canonicalDepositFee + withdrawalFee
  expectedDeltas[receiptChain] -= receiptFee
  await waitForExpectedBalances(`after ${label}`)
  console.log(`    ✓ cycle ${label} complete`)
}

console.log(`\n[I] Running swap cycles...`)
await runCycle(B, 'cycle-B-on-Nexus')
await runCycle(C, 'cycle-C-on-Nexus')
await runCycle(D, 'cycle-D-on-B')
await runCycle(E, 'cycle-E-on-C')
await runCycle(G, 'cycle-G-on-E')
await runCycle(D, 'cycle-D-on-B-#2')
await runCycle(G, 'cycle-G-on-E-#2')

const finalBalances = await waitForExpectedBalances('final multi-depth swaps')

const after = finalBalances

console.log(`\n=== RESULTS ===`)
let failed = false
for (const dir of [NEXUS, B, C, D, E, G]) {
  const actual = after[dir] - before[dir]
  const expected = expectedDeltas[dir]
  const ok = actual === expected
  if (!ok) failed = true
  console.log(`  ${dir.padEnd(8)} before=${before[dir]}  after=${after[dir]}  delta=${actual}  expected=${expected}  ${ok ? '✓' : '✗'}`)
}

if (failed) {
  console.error(`\n✗ Balance deltas did not match exact multi-depth swap fees`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`\n✓ Multi-depth cross-chain swap cycles succeeded`)
net.teardown()
await sleep(500)
process.exit(0)
