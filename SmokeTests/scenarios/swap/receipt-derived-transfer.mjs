// Receipt-derived transfer: the nexus receipt step must debit the withdrawer
// and credit a distinct demander. Existing swap smokes use the same account for
// both roles, which cannot catch a missing or inverted implicit receipt effect.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress, sign,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('receipt-derived-transfer')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, childPorts] = await allocPorts(2)
const CHILD = 'ReceiptRoles'
const FEE = 1
const FUND = 5_000
const AMOUNT = 500

console.log('=== receipt-derived transfer smoke test ===')

// Keep setup funding off the node identity: coinbase rewards are signed by the
// node, but paid to this funder, so reward-only side forks never consume the
// funder's nonce or invalidate restaged setup transfers.
const funder = genKeypair()
const nexusNode = new LatticeNode({
  name: 'nexus',
  dir: `${ROOT}/nexus`,
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
const nodeAddr = computeAddress(minerIdent.publicKey)
const withdrawer = genKeypair()
const demander = genKeypair()

const info = await nexusNode.chainInfo()
const nexusDir = info.nexus
const childPath = [nexusDir, CHILD]

console.log(`node signer: ${nodeAddr}`)
console.log(`funder:     ${funder.address}`)
console.log(`withdrawer: ${withdrawer.address}`)
console.log(`demander:  ${demander.address}`)
console.log(`deploying ${CHILD}...`)

const childNode = await nexusNode.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  initialReward: 512,
  premine: 10_000,
  premineRecipient: funder.address,
})
net.add(childNode)

const miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)

async function submitMultiSig(node, body, keypairs) {
  let prep
  for (let attempt = 0; attempt < 8; attempt++) {
    prep = await node.rpc('POST', '/api/transaction/prepare', body)
    if (prep.ok || !JSON.stringify(prep.json).includes('rate limit')) break
    await sleep(100 * (attempt + 1))
  }
  if (!prep.ok) throw new Error(`prepare multisig tx failed: ${JSON.stringify(prep.json)}`)
  const preimage = prep.json.signingPreimage ?? prep.json.bodyCID
  const signatures = Object.fromEntries(keypairs.map((kp) => [kp.publicKey, sign(preimage, kp.privateKey)]))
  const sub = await node.rpc('POST', '/api/transaction', {
    signatures,
    bodyCID: prep.json.bodyCID,
    bodyData: prep.json.bodyData,
    chainPath: body.chainPath,
  })
  return { ok: sub.ok, ...sub.json }
}

async function fundNexusRoles(amount) {
  const nonce = await nexusNode.nonce(funder.address, nexusDir)
  const r = await nexusNode.submitTx({
    chainPath: [nexusDir],
    nonce,
    signers: [funder.address],
    fee: FEE,
    accountActions: [
      { owner: funder.address, delta: -((amount * 2) + FEE) },
      { owner: withdrawer.address, delta: amount },
      { owner: demander.address, delta: amount },
    ],
  }, nexusDir, funder)
  if (!r.ok && !JSON.stringify(r).includes('Duplicate')) {
    throw new Error(`fund Nexus role accounts failed: ${JSON.stringify(r)}`)
  }
}

async function fundChild(address, amount) {
  const nonce = await childNode.nonce(funder.address, CHILD)
  const r = await childNode.submitTx({
    chainPath: childPath,
    nonce,
    signers: [funder.address],
    fee: FEE,
    accountActions: [
      { owner: funder.address, delta: -(amount + FEE) },
      { owner: address, delta: amount },
    ],
  }, CHILD, funder)
  if (!r.ok) throw new Error(`fund ${CHILD} ${address} failed: ${JSON.stringify(r)}`)
}

console.log('\n[1] Mine initial funds and fund the role accounts...')
await nexusNode.startMining(nexusDir)
await waitFor(async () => (await nexusNode.height(nexusDir)) >= 5,
  'nexus height 5', { timeoutMs: 180_000, intervalMs: 500 })
await nexusNode.stopMining(nexusDir)
await nexusNode.awaitQuiesced(nexusDir)

async function nexusRolesFunded() {
  const [w, d] = await Promise.all([
    nexusNode.balance(withdrawer.address, nexusDir),
    nexusNode.balance(demander.address, nexusDir),
  ])
  return w >= FUND && d >= FUND ? { withdrawer: w, demander: d } : null
}

let fundedRoles = null
for (let attempt = 1; attempt <= 3 && !fundedRoles; attempt++) {
  await fundNexusRoles(FUND)
  try {
    await nexusNode.mineUntil(nexusRolesFunded, nexusDir, {
      desc: `nexus role accounts funded (attempt ${attempt})`,
      timeoutMs: 180_000,
      intervalMs: 500,
      progress: async () => String(await nexusNode.height(nexusDir)),
    })
  } catch (err) {
    if (attempt === 3) throw err
  }
  await nexusNode.stopMining(nexusDir)
  await nexusNode.awaitQuiesced(nexusDir)
  fundedRoles = await nexusRolesFunded()
  if (!fundedRoles) console.log(`  Nexus role funding reorged out; restaging (attempt ${attempt})`)
}
if (!fundedRoles) throw new Error('nexus role accounts funding did not remain canonical')

await miner.mineUntil(
  async () => (await childNode.height(CHILD)) >= 3,
  {
    desc: `${CHILD} mining`,
    timeoutMs: 180_000,
    progress: async () => String(await childNode.height(CHILD)),
  }
)
await miner.stop()
await childNode.awaitQuiesced(CHILD)

await fundChild(withdrawer.address, FUND)
await miner.mineUntil(
  async () => (await childNode.balance(withdrawer.address, CHILD)) >= FUND,
  {
    desc: 'withdrawer child account funded',
    timeoutMs: 120_000,
    progress: async () => String(await childNode.height(CHILD)),
  }
)
await miner.stop()
await nexusNode.awaitQuiesced(nexusDir)
await childNode.awaitQuiesced(CHILD)

const nexusWithdrawerBefore = await nexusNode.balance(withdrawer.address, nexusDir)
const nexusDemanderBefore = await nexusNode.balance(demander.address, nexusDir)
console.log(`  Nexus before receipt: withdrawer=${nexusWithdrawerBefore} demander=${nexusDemanderBefore}`)

console.log('\n[2] Deposit on child with distinct withdrawer/demander roles...')
const swapNonce = Date.now().toString(16).padStart(32, '0').slice(-32)
const depositNonce = await childNode.nonce(withdrawer.address, CHILD)
const deposit = await submitMultiSig(childNode, {
  chainPath: childPath,
  nonce: depositNonce,
  signers: [withdrawer.address, demander.address],
  fee: FEE,
  accountActions: [{ owner: withdrawer.address, delta: -(AMOUNT + FEE) }],
  depositActions: [{
    nonce: swapNonce,
    demander: demander.address,
    amountDemanded: AMOUNT,
    amountDeposited: AMOUNT,
  }],
}, [withdrawer, demander])
if (!deposit.ok) {
  console.error(`  ✗ deposit rejected: ${JSON.stringify(deposit)}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}

await miner.mineUntil(
  async () => {
    const d = await childNode.getDeposit(demander.address, AMOUNT, swapNonce, CHILD)
    return d.exists ? d : null
  },
  {
    desc: 'distinct-role deposit visible',
    timeoutMs: 120_000,
    progress: async () => String(await childNode.height(CHILD)),
  }
)
await miner.stop()
await childNode.awaitQuiesced(CHILD)
console.log('  ✓ deposit visible under demander key')

console.log('\n[3] Receipt on Nexus must move value from withdrawer to demander...')
const receiptNonce = await nexusNode.nonce(withdrawer.address, nexusDir)
const receipt = await nexusNode.submitTx({
  chainPath: [nexusDir],
  nonce: receiptNonce,
  signers: [withdrawer.address],
  fee: FEE,
  accountActions: [{ owner: withdrawer.address, delta: -FEE }],
  receiptActions: [{
    withdrawer: withdrawer.address,
    nonce: swapNonce,
    demander: demander.address,
    amountDemanded: AMOUNT,
    directory: CHILD,
  }],
}, nexusDir, withdrawer)
if (!receipt.ok) {
  console.error(`  ✗ receipt rejected: ${JSON.stringify(receipt)}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}

await nexusNode.startMining(nexusDir)
await waitFor(async () => {
  const r = await nexusNode.getReceipt(demander.address, AMOUNT, swapNonce, CHILD)
  return r.exists ? r : null
}, 'receipt visible on Nexus', { timeoutMs: 120_000, intervalMs: 500 })
await nexusNode.stopMining(nexusDir)
await nexusNode.awaitQuiesced(nexusDir)

const nexusWithdrawerAfter = await nexusNode.balance(withdrawer.address, nexusDir)
const nexusDemanderAfter = await nexusNode.balance(demander.address, nexusDir)
const withdrawerDelta = nexusWithdrawerAfter - nexusWithdrawerBefore
const demanderDelta = nexusDemanderAfter - nexusDemanderBefore

console.log(`  Nexus after receipt:  withdrawer=${nexusWithdrawerAfter} demander=${nexusDemanderAfter}`)
console.log(`  deltas: withdrawer=${withdrawerDelta} demander=${demanderDelta}`)

if (withdrawerDelta !== -(AMOUNT + FEE)) {
  console.error(`  ✗ withdrawer delta should be -${AMOUNT + FEE}, got ${withdrawerDelta}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}
if (demanderDelta !== AMOUNT) {
  console.error(`  ✗ demander delta should be +${AMOUNT}, got ${demanderDelta}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}

console.log('  ✓ receipt-derived debit and credit applied to distinct accounts')

console.log('\n✓ receipt-derived transfer smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
