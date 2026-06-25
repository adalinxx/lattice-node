// Cross-chain conservation: run a full swap cycle and verify no value
// is created or destroyed across the chain boundary. Sum of all balances
// on both chains must equal premine + coinbase rewards.
//
// Per-process version: the child chain (XChain) runs as a separate process.
// LatticeMiner handles merged mining (Nexus + XChain child blocks together).
// We track coinbase rewards on both chains via balance checks.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('cross-chain-conservation')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, childPorts] = await allocPorts(2)
const CHILD = 'XChain'
const FEE = 1
const WARMUP_WAIT_MS = 240_000
const FUND_WAIT_MS = 180_000
const MINING_WAIT_MS = 180_000

console.log('=== cross-chain conservation smoke test ===')

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

const specResp = await nexusNode.rpc('GET', `/api/chain/spec?chainPath=${nexusDir}`)
if (!specResp.ok) throw new Error(`nexus spec failed: ${JSON.stringify(specResp.json)}`)
const NEXUS_REWARD = specResp.json.initialReward

// Deploy child with premine to a dedicated value owner. The node identity signs
// mining work, but rewards/premine are held by an account whose nonce is not
// advanced by block production.
const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  initialReward: 512,
  premine: 100,
  premineRecipient: funder.address,
})
net.add(childNode)
const childIdent = await childNode.readIdentity()
const childCoinbaseAddr = childIdent.coinbaseAddress ?? childIdent.rewardAddress ?? childNode._keypair.address
const childSpec = await childNode.rpc('GET', `/api/chain/spec?chainPath=${CHILD}`)
if (!childSpec.ok) throw new Error(`child spec failed: ${JSON.stringify(childSpec.json)}`)
const CHILD_REWARD = childSpec.json.initialReward
const CHILD_PREMINE = childSpec.json.premineAmount ?? childSpec.json.premine ?? 100

// One merged-mining coordinator advances BOTH Nexus and the child — including parent
// state-access txs (funding transfers, receipts). The node builds each template with
// full state access; the coordinator only does PoW. No Nexus-only miner needed.
const miner = new LatticeMiner(nexusNode, [childNode])
await miner.start()
net.addMiner(miner)

await nexusNode.waitForHeight(8, nexusDir, { timeoutMs: 2 * WARMUP_WAIT_MS })
await childNode.waitForHeight(3, CHILD, { timeoutMs: FUND_WAIT_MS })

console.log(`\n[1] Snapshot pre-swap balances...`)
await miner.stop()
await nexusNode.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)

const preInfo = await nexusNode.chainInfo()
const preNexusHeight = preInfo.chains.find(c => c.directory === nexusDir)?.height ?? 0
const preChildHeight = await childNode.height(CHILD)
const preMinerNexus = await nexusNode.balance(minerAddr, nexusDir)
const preFunderNexus = await nexusNode.balance(funder.address, nexusDir)
const prePremineOwnerChild = await childNode.balance(funder.address, CHILD)
const preChildCoinbase = await childNode.balance(childCoinbaseAddr, CHILD)
console.log(`  nexus: h=${preNexusHeight} miner=${preMinerNexus} funder=${preFunderNexus}`)
console.log(`  child:  h=${preChildHeight} premineOwner=${prePremineOwnerChild} coinbase=${preChildCoinbase}`)

const expectedPreMinerNexus = 0
const expectedPreFunderNexus = preNexusHeight * NEXUS_REWARD
const sameChildRewardAccount = childCoinbaseAddr === funder.address
const expectedPrePremineOwnerChild = CHILD_PREMINE + (sameChildRewardAccount ? preChildHeight * CHILD_REWARD : 0)
const expectedPreChildCoinbase = sameChildRewardAccount ? expectedPrePremineOwnerChild : preChildHeight * CHILD_REWARD
if (preMinerNexus !== expectedPreMinerNexus) {
  console.error(`  ✗ miner nexus baseline ${preMinerNexus} != ${expectedPreMinerNexus}`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (preFunderNexus !== expectedPreFunderNexus) {
  console.error(`  ✗ funder nexus baseline ${preFunderNexus} != ${expectedPreFunderNexus}`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (prePremineOwnerChild !== expectedPrePremineOwnerChild) {
  console.error(`  ✗ child premine-owner baseline ${prePremineOwnerChild} != ${expectedPrePremineOwnerChild}`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (preChildCoinbase !== expectedPreChildCoinbase) {
  console.error(`  ✗ child coinbase baseline ${preChildCoinbase} != ${expectedPreChildCoinbase}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log('  ✓ pre-swap reward and premine baselines are exact')

console.log(`\n[2] Fund user on both chains...`)
const user = genKeypair()
const FUND = 2000

const mn = await nexusNode.nonce(funder.address, nexusDir)
const fundNexus = await nexusNode.submitTx({
  chainPath: [nexusDir], nonce: mn, signers: [funder.address], fee: FEE,
  accountActions: [
    { owner: funder.address, delta: -(FUND + FEE) },
    { owner: user.address, delta: FUND },
  ],
}, nexusDir, funder)
if (!fundNexus.ok) throw new Error(`fund nexus failed: ${JSON.stringify(fundNexus)}`)

const mc = await childNode.nonce(funder.address, CHILD)
const fundChild = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: mc, signers: [funder.address], fee: FEE,
  accountActions: [
    { owner: funder.address, delta: -(FUND + FEE) },
    { owner: user.address, delta: FUND },
  ],
}, CHILD, funder)
if (!fundChild.ok) throw new Error(`fund child failed: ${JSON.stringify(fundChild)}`)

const miner2 = new LatticeMiner(nexusNode, [childNode])
await miner2.start()
net.addMiner(miner2)

// The merged miner confirms BOTH the Nexus and the child funding txs.
await waitFor(async () => (await nexusNode.balance(user.address, nexusDir)) >= FUND,
  'nexus funded', { timeoutMs: FUND_WAIT_MS })
await waitFor(async () => (await childNode.balance(user.address, CHILD)) >= FUND,
  'child funded', { timeoutMs: FUND_WAIT_MS })

console.log(`\n[3] Run swap: deposit on child, receipt on nexus, withdraw on child...`)
const swapNonce = '00000000000000000000000000000001'
const SWAP_AMOUNT = 500

await miner2.stop()
await nexusNode.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)

const depN = await childNode.nonce(user.address, CHILD)
const deposit = await childNode.submitTx({
  nonce: depN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: -(SWAP_AMOUNT + FEE) }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, amountDeposited: SWAP_AMOUNT }],
}, CHILD, user)
if (!deposit.ok) throw new Error(`deposit failed: ${JSON.stringify(deposit)}`)

const miner3 = new LatticeMiner(nexusNode, [childNode])
await miner3.start()
net.addMiner(miner3)

const depositVisible = await waitFor(async () => {
  const d = await childNode.getDeposit(user.address, SWAP_AMOUNT, swapNonce, CHILD)
  return d.exists &&
    d.amountDeposited === SWAP_AMOUNT &&
    d.chain === CHILD &&
    typeof d.key === 'string' &&
    d.key.length > 0
    ? d
    : null
}, 'deposit visible', { timeoutMs: MINING_WAIT_MS })
const depositKey = depositVisible.key

const recN = await nexusNode.nonce(user.address, nexusDir)
const receipt = await nexusNode.submitTx({
  chainPath: [nexusDir], nonce: recN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: -FEE }],
  receiptActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, directory: CHILD }],
}, nexusDir, user)
if (!receipt.ok) throw new Error(`receipt failed: ${JSON.stringify(receipt)}`)
await waitFor(async () => {
  const r = await nexusNode.getReceipt(user.address, SWAP_AMOUNT, swapNonce, CHILD)
  return r.exists &&
    r.directory === CHILD &&
    Array.isArray(r.chainPath) &&
    r.chainPath.join('/') === `${nexusDir}/${CHILD}` &&
    r.withdrawer === user.address
    ? r
    : null
}, 'receipt visible', { timeoutMs: MINING_WAIT_MS })

const wdN = await childNode.nonce(user.address, CHILD)
const withdrawal = await childNode.submitTx({
  nonce: wdN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: SWAP_AMOUNT - FEE }],
  withdrawalActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, amountWithdrawn: SWAP_AMOUNT }],
}, CHILD, user)
if (!withdrawal.ok) throw new Error(`withdrawal failed: ${JSON.stringify(withdrawal)}`)

const expectedUserChildAfterSwap = FUND - (2 * FEE)
async function childMempoolCount() {
  const r = await childNode.rpc('GET', `/api/mempool?chainPath=${childNode._queryPath(CHILD)}`)
  if (!r.ok) throw new Error(`child mempool query failed: ${JSON.stringify(r.json)}`)
  if (!Number.isInteger(r.json?.count) || r.json.chain !== CHILD) {
    throw new Error(`child mempool response malformed: ${JSON.stringify(r.json)}`)
  }
  return r.json.count
}
async function withdrawalCanonical() {
  const depositResp = await childNode.rpc(
    'GET',
    `/api/deposit?demander=${user.address}&amount=${SWAP_AMOUNT}&nonce=${swapNonce}&chainPath=${childNode._queryPath(CHILD)}`
  )
  if (!depositResp.ok) throw new Error(`deposit-state query failed during withdrawal settlement: ${JSON.stringify(depositResp.json)}`)
  const d = depositResp.json
  if (d.chain !== CHILD || d.key !== depositKey) {
    throw new Error(`deposit-state response malformed during withdrawal settlement: ${JSON.stringify(d)}`)
  }
  const bal = await childNode.balance(user.address, CHILD)
  const mempoolCount = await childMempoolCount()
  return d.exists === false && bal === expectedUserChildAfterSwap && mempoolCount === 0
    ? { balance: bal, mempoolCount }
    : null
}

let settledWithdrawal = null
for (let attempt = 1; attempt <= 3 && !settledWithdrawal; attempt++) {
  await miner3.mineUntil(withdrawalCanonical, {
    desc: `withdrawal canonical on child (attempt ${attempt})`,
    timeoutMs: MINING_WAIT_MS,
    progress: async () => `${await childNode.height(CHILD)}:${await childNode.balance(user.address, CHILD)}:${await childMempoolCount()}`,
  })
  await miner3.stop()
  await nexusNode.awaitQuiesced(nexusDir)
  await childNode.awaitQuiesced(CHILD)
  settledWithdrawal = await withdrawalCanonical()
  if (!settledWithdrawal) {
    console.log(`  withdrawal unsettled after quiescence; continuing mining (attempt ${attempt})`)
  }
}
if (!settledWithdrawal) {
  throw new Error('withdrawal did not remain canonical after quiescence')
}
console.log('  swap complete')

console.log(`\n[4] Verify cross-chain conservation...`)
await miner3.stop()
await nexusNode.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)

const postInfo = await nexusNode.chainInfo()
const postNexusHeight = postInfo.chains.find(c => c.directory === nexusDir)?.height ?? 0
const postChildHeight = await childNode.height(CHILD)
const postMinerNexus = await nexusNode.balance(minerAddr, nexusDir)
const postFunderNexus = await nexusNode.balance(funder.address, nexusDir)
const postPremineOwnerChild = await childNode.balance(funder.address, CHILD)
const postChildCoinbase = await childNode.balance(childCoinbaseAddr, CHILD)
const postUserNexus = await nexusNode.balance(user.address, nexusDir)
const postUserChild = await childNode.balance(user.address, CHILD)

const nexusCoinbase = (postNexusHeight - preNexusHeight) * NEXUS_REWARD
const childCoinbase = (postChildHeight - preChildHeight) * CHILD_REWARD

const totalNexus = postMinerNexus + postFunderNexus + postUserNexus
const totalChild = postPremineOwnerChild + (sameChildRewardAccount ? 0 : postChildCoinbase) + postUserChild
const nexusFundingFee = FEE
const nexusReceiptFee = FEE
const childFundingFee = FEE
const childDepositFee = FEE
const childWithdrawalFee = FEE

const expectedMinerNexus = preMinerNexus
const expectedFunderNexus = preFunderNexus + nexusCoinbase - (FUND + nexusFundingFee) + nexusFundingFee + nexusReceiptFee
const expectedUserNexus = FUND - nexusReceiptFee
const expectedPremineOwnerChild = prePremineOwnerChild - (FUND + childFundingFee) +
  (sameChildRewardAccount ? childCoinbase + childFundingFee + childDepositFee + childWithdrawalFee : 0)
const expectedChildCoinbase = sameChildRewardAccount
  ? expectedPremineOwnerChild
  : preChildCoinbase + childCoinbase + childFundingFee + childDepositFee + childWithdrawalFee
const expectedUserChild = FUND - childDepositFee - childWithdrawalFee
const expectedNexus = expectedMinerNexus + expectedFunderNexus + expectedUserNexus
const expectedChild = expectedPremineOwnerChild + (sameChildRewardAccount ? 0 : expectedChildCoinbase) + expectedUserChild

console.log(`  nexus: h=${postNexusHeight} coinbase=${nexusCoinbase} total=${totalNexus} expected=${expectedNexus}`)
console.log(`    miner=${postMinerNexus} expected=${expectedMinerNexus}  funder=${postFunderNexus} expected=${expectedFunderNexus}  user=${postUserNexus} expected=${expectedUserNexus}`)
console.log(`  child:  h=${postChildHeight} coinbase=${childCoinbase} total=${totalChild} expected=${expectedChild}`)
console.log(`    premineOwner=${postPremineOwnerChild} expected=${expectedPremineOwnerChild}  coinbase=${postChildCoinbase} expected=${expectedChildCoinbase}  user=${postUserChild} expected=${expectedUserChild}`)

const failures = []
for (const [label, actual, expected] of [
  ['nexus total', totalNexus, expectedNexus],
  ['nexus miner identity isolation', postMinerNexus, expectedMinerNexus],
  ['nexus funder fee reconciliation', postFunderNexus, expectedFunderNexus],
  ['nexus user fee spend', postUserNexus, expectedUserNexus],
  ['child total', totalChild, expectedChild],
  ['child premine owner spend', postPremineOwnerChild, expectedPremineOwnerChild],
  ['child coinbase fee reconciliation', postChildCoinbase, expectedChildCoinbase],
  ['child user fee spend', postUserChild, expectedUserChild],
]) {
  if (actual !== expected) failures.push(`${label}: actual=${actual} expected=${expected} diff=${actual - expected}`)
}
if (failures.length > 0) {
  for (const failure of failures) console.error(`  ✗ ${failure}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log('  ✓ exact two-sided conservation on both chains')
console.log('  ✓ fees reconcile to miner balances and user spends')

console.log(`\n✓ cross-chain conservation smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
