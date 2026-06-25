// Variable-rate cross-chain swap: amountDeposited (child tokens locked) differs
// from amountDemanded (parent tokens demanded). Asserts the (deposited, demanded)
// pair is preserved end-to-end and the on-chain overclaim guard is satisfied.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('vrs')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts] = await allocPorts(1)
const CHILD = 'FastTest'

console.log('=== variable-rate cross-chain swap smoke test ===')

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
console.log(`chains: ${info.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

const fundAmount = 5000

console.log(`deploying ${CHILD}...`)
const [childPorts] = await allocPorts(1)
const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  // Premine the user on the child so no child fund tx is needed.
  premine: fundAmount * 10 + 1000,
  premineRecipient: user.address,
})
net.add(childNode)

// One merged-mining coordinator advances BOTH Nexus and the child — including the
// parent funding transfer and the swap receipt (the node builds each template with
// full state access; the coordinator only does PoW). A separate payout key keeps
// reward-only blocks from consuming the funder's nonce if a block lands on a fork.
const miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)
await miner.start()

// Let the funder earn Nexus coinbase, then fund the user on Nexus. Stop-for-stable-tip
// to read a stable nonce; the merged miner then confirms the funding tx.
await waitFor(async () => (await nexusNode.balance(funder.address, nexusDir)) >= fundAmount + 1,
  'funder nexus coinbase', { timeoutMs: 2 * 120_000, intervalMs: 500 })
await miner.stop()
await nexusNode.awaitQuiesced(nexusDir)
const nexusFundNonce = await nexusNode.nonce(funder.address, nexusDir)
const nexusFundR = await nexusNode.submitTx({
  nonce: nexusFundNonce, signers: [funder.address], fee: 1,
  accountActions: [{ owner: funder.address, delta: -(fundAmount + 1) }, { owner: user.address, delta: fundAmount }],
}, nexusDir, funder)
if (!nexusFundR.ok) throw new Error(`nexus fund failed: ${JSON.stringify(nexusFundR)}`)
await miner.start()
await waitFor(async () => (await nexusNode.balance(user.address, nexusDir)) >= fundAmount,
  'user nexus funded', { timeoutMs: 2 * 90_000 })

await waitFor(async () => (await childNode.height(CHILD)) >= 10,
  `${CHILD} height 10`, { timeoutMs: 210_000, intervalMs: 500 })
// Keep miner running through the swap cycle to confirm swap TXs.

await waitFor(async () => (await nexusNode.balance(user.address, nexusDir)) >= fundAmount,
  'user Nexus funded', { timeoutMs: 60_000 })
await waitFor(async () => (await childNode.balance(user.address, CHILD)) >= fundAmount,
  `user ${CHILD} funded`, { timeoutMs: 60_000 })

const nexusBal0 = await nexusNode.balance(user.address, nexusDir)
const childBal0 = await childNode.balance(user.address, CHILD)
console.log(`user balances  Nexus=${nexusBal0}  ${CHILD}=${childBal0}`)

const swapNonceHex = Date.now().toString(16).padStart(32, '0').slice(-32)
const amountDeposited = 100
const amountDemanded = 250
const fee = 1
console.log(`\nvariable-rate: deposited=${amountDeposited} ${CHILD} demanded=${amountDemanded} Nexus`)
console.log(`rate ${(amountDemanded / amountDeposited).toFixed(2)}x  swapNonce=0x${swapNonceHex}`)

const depNonce = await childNode.nonce(user.address, CHILD)
console.log(`\n[1/3] Deposit on ${CHILD} (acct nonce=${depNonce})`)
const depResult = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -(amountDeposited + fee) }],
  depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded, amountDeposited }],
}, CHILD, user)
if (!depResult.ok) { net.teardown(); process.exit(1) }

const depState = await waitFor(async () => {
  const r = await childNode.getDeposit(user.address, amountDemanded, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'deposit visible', { timeoutMs: 60_000 })
console.log(`  ✓ deposit in state: amountDeposited=${depState.amountDeposited} (demanded=${amountDemanded})`)
if (Number(depState.amountDeposited) !== amountDeposited) {
  console.error(`  ✗ expected amountDeposited=${amountDeposited}, got ${depState.amountDeposited}`)
  net.teardown(); process.exit(1)
}

const recNonce = await nexusNode.nonce(user.address, nexusDir)
console.log(`\n[2/3] Receipt on ${nexusDir} (acct nonce=${recNonce}) paying ${amountDemanded}`)
const recResult = await nexusNode.submitTx({
  nonce: recNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -fee }],
  receiptActions: [{
    withdrawer: user.address, nonce: swapNonceHex, demander: user.address,
    amountDemanded, directory: CHILD,
  }],
}, nexusDir, user)
if (!recResult.ok) { net.teardown(); process.exit(1) }
await waitFor(async () => {
  const r = await nexusNode.getReceipt(user.address, amountDemanded, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'receipt visible', { timeoutMs: 60_000 })
console.log(`  ✓ receipt visible`)

const wdNonce = await childNode.nonce(user.address, CHILD)
console.log(`\n[3/3] Withdrawal on ${CHILD} (acct nonce=${wdNonce}) unlocking ${amountDeposited}`)
const wdResult = await childNode.submitTx({
  chainPath: [nexusDir, CHILD], nonce: wdNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: amountDeposited - fee }],
  withdrawalActions: [{
    withdrawer: user.address, nonce: swapNonceHex, demander: user.address,
    amountDemanded, amountWithdrawn: amountDeposited,
  }],
}, CHILD, user)
if (!wdResult.ok) { net.teardown(); process.exit(1) }
await waitFor(async () => {
  const r = await childNode.getDeposit(user.address, amountDemanded, swapNonceHex, CHILD)
  return !r.exists
}, 'deposit consumed', { timeoutMs: 60_000 })
console.log(`  ✓ deposit consumed`)

await miner.stop()
await nexusNode.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)
const nexusBal1 = await nexusNode.balance(user.address, nexusDir)
const childBal1 = await childNode.balance(user.address, CHILD)
const actualNexusDelta = nexusBal1 - nexusBal0
const actualChildDelta = childBal1 - childBal0
const expectedNexusDelta = -fee
const expectedChildDelta = -2 * fee
console.log(`\n=== RESULTS ===`)
console.log(`Nexus     before=${nexusBal0}  after=${nexusBal1}  delta=${actualNexusDelta}  expected=${expectedNexusDelta}  ${actualNexusDelta === expectedNexusDelta ? '✓' : '✗'}`)
console.log(`${CHILD}  before=${childBal0}  after=${childBal1}  delta=${actualChildDelta}  expected=${expectedChildDelta}  ${actualChildDelta === expectedChildDelta ? '✓' : '✗'}`)
if (actualNexusDelta !== expectedNexusDelta || actualChildDelta !== expectedChildDelta) {
  console.error(`\n✗ final balance deltas did not match expected variable-rate swap fees`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`✓ rate ${(amountDemanded / amountDeposited).toFixed(2)}x preserved through all three steps`)

net.teardown()
await sleep(500)
process.exit(0)
