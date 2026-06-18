// Wallet under attack: one real node, several funded users, one mining pass.
// Covers bad signatures, duplicate submit, RBF, double-spend, nonce replay, and
// far-future nonce rejection through the public RPC surface.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, sign, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('wallet-under-attack')
const [{ port, rpcPort }] = await allocPorts(1)
const FUND = 5000
const FEE = 1

console.log('=== wallet-under-attack smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })

async function fail(message) {
  console.error(`  x ${message}`)
  await node.stop().catch(() => {})
  await sleep(500)
  process.exit(1)
}

node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const nexusDir = (await chainInfo(node)).nexus

console.log('\n[1] Warm chain and fund attack accounts...')
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 60_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const users = {
  sig: genKeypair(),
  idem: genKeypair(),
  rbf: genKeypair(),
  double: genKeypair(),
}
const fundBase = await getNonce(node, minerAddr, nexusDir)
let offset = 0
for (const user of Object.values(users)) {
  const r = await submitTx(node, {
    chainPath: [nexusDir], nonce: fundBase + offset, signers: [minerAddr], fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(FUND + FEE) },
      { owner: user.address, delta: FUND },
    ],
  }, nexusDir, minerKP)
  if (!r.ok) await fail(`funding rejected: ${JSON.stringify(r.submit)}`)
  offset++
}

await startMining(node, nexusDir)
await waitFor(async () => {
  const balances = await Promise.all(Object.values(users).map((u) => getBalance(node, u.address, nexusDir)))
  return balances.every((b) => b >= FUND) ? balances : null
}, 'all attack accounts funded', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
console.log('  funded sig, idem, rbf, and double-spend accounts')

async function prepareSignedTx({ user, nonce, recipient, amount, fee = FEE }) {
  const prep = await node.rpc('POST', '/api/transaction/prepare', {
    chainPath: [nexusDir], nonce, signers: [user.address], fee,
    accountActions: [
      { owner: user.address, delta: -(amount + fee) },
      { owner: recipient.address, delta: amount },
    ],
  })
  if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
  return {
    bodyCID: prep.json.bodyCID,
    bodyData: prep.json.bodyData,
    signingPreimage: prep.json.signingPreimage ?? prep.json.bodyCID,
    chainPath: [nexusDir],
  }
}

async function submitRaw(tx, user, signature = sign(tx.signingPreimage, user.privateKey)) {
  return node.rpc('POST', '/api/transaction', {
    signatures: { [user.publicKey]: signature },
    bodyCID: tx.bodyCID,
    bodyData: tx.bodyData,
    chainPath: tx.chainPath,
  })
}

async function trySubmitTx(node, body, chain, keypair) {
  try {
    return await submitTx(node, body, chain, keypair)
  } catch (error) {
    return { ok: false, submit: { error: error.message } }
  }
}

console.log('\n[2] Reject malformed signatures, then accept the real one...')
const sigRecipient = genKeypair()
const sigReplayRecipient = genKeypair()
const sigNonce = await getNonce(node, users.sig.address, nexusDir)
const sigTx = await prepareSignedTx({ user: users.sig, nonce: sigNonce, recipient: sigRecipient, amount: 100 })
const realSig = sign(sigTx.signingPreimage, users.sig.privateKey)
const flipped = realSig.slice(0, 4) + (realSig[4] === '0' ? '1' : '0') + realSig.slice(5)
const wrongKey = genKeypair()
const wrongSig = sign(sigTx.signingPreimage, wrongKey.privateKey)

for (const [label, body] of [
  ['flipped signature', { signatures: { [users.sig.publicKey]: flipped } }],
  ['wrong key', { signatures: { [wrongKey.publicKey]: wrongSig } }],
  ['empty signatures', { signatures: {} }],
]) {
  const r = await node.rpc('POST', '/api/transaction', {
    ...body,
    bodyCID: sigTx.bodyCID,
    bodyData: sigTx.bodyData,
    chainPath: [nexusDir],
  })
  if (r.ok) await fail(`${label} accepted`)
}
if (!(await submitRaw(sigTx, users.sig)).ok) await fail('valid signature rejected after invalid attempts')
console.log('  bad signatures rejected; valid tx staged')

console.log('\n[3] Submit the same signed body twice...')
const idemRecipient = genKeypair()
const idemNonce = await getNonce(node, users.idem.address, nexusDir)
const idemTx = await prepareSignedTx({ user: users.idem, nonce: idemNonce, recipient: idemRecipient, amount: 100 })
const idemSubmit = {
  signatures: { [users.idem.publicKey]: sign(idemTx.signingPreimage, users.idem.privateKey) },
  bodyCID: idemTx.bodyCID,
  bodyData: idemTx.bodyData,
  chainPath: [nexusDir],
}
const idem1 = await node.rpc('POST', '/api/transaction', idemSubmit)
const idem2 = await node.rpc('POST', '/api/transaction', idemSubmit)
if (!idem1.ok) await fail(`first idempotent submit rejected: ${JSON.stringify(idem1.json)}`)
console.log(`  duplicate submit returned ok=${idem2.ok}`)

console.log('\n[4] Replace one pending tx by fee...')
const rbfRecipient = genKeypair()
const rbfNonce = await getNonce(node, users.rbf.address, nexusDir)
const rbfOriginal = await prepareSignedTx({ user: users.rbf, nonce: rbfNonce, recipient: rbfRecipient, amount: 100, fee: 1 })
const rbfBump = await prepareSignedTx({ user: users.rbf, nonce: rbfNonce, recipient: rbfRecipient, amount: 120, fee: 10 })
if (!(await submitRaw(rbfOriginal, users.rbf)).ok) await fail('original RBF tx rejected')
const rbfReplace = await submitRaw(rbfBump, users.rbf)
if (!rbfReplace.ok) await fail(`higher-fee RBF replacement rejected: ${JSON.stringify(rbfReplace.json)}`)
console.log('  higher-fee replacement accepted')

console.log('\n[5] Stage two same-nonce spends...')
const doubleA = genKeypair()
const doubleB = genKeypair()
const doubleNonce = await getNonce(node, users.double.address, nexusDir)
const doubleSpendA = await submitTx(node, {
  chainPath: [nexusDir], nonce: doubleNonce, signers: [users.double.address], fee: FEE,
  accountActions: [
    { owner: users.double.address, delta: -1001 },
    { owner: doubleA.address, delta: 1000 },
  ],
}, nexusDir, users.double)
const doubleSpendB = await submitTx(node, {
  chainPath: [nexusDir], nonce: doubleNonce, signers: [users.double.address], fee: FEE,
  accountActions: [
    { owner: users.double.address, delta: -901 },
    { owner: doubleB.address, delta: 900 },
  ],
}, nexusDir, users.double)
if (!doubleSpendA.ok && !doubleSpendB.ok) await fail('both same-nonce spends rejected')
console.log(`  same-nonce submits: A=${doubleSpendA.ok} B=${doubleSpendB.ok}`)

console.log('\n[6] Mine once and assert final wallet state...')
await startMining(node, nexusDir)
await waitFor(async () => {
  const [sigBal, idemBal, rbfBal, da, db] = await Promise.all([
    getBalance(node, sigRecipient.address, nexusDir),
    getBalance(node, idemRecipient.address, nexusDir),
    getBalance(node, rbfRecipient.address, nexusDir),
    getBalance(node, doubleA.address, nexusDir),
    getBalance(node, doubleB.address, nexusDir),
  ])
  return sigBal >= 100 && idemBal >= 100 && rbfBal >= 120 && (da >= 1000 || db >= 900)
    ? { sigBal, idemBal, rbfBal, da, db }
    : null
}, 'staged attack txs mined', { timeoutMs: 120_000, intervalMs: 1000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const sigBal = await getBalance(node, sigRecipient.address, nexusDir)
const idemBal = await getBalance(node, idemRecipient.address, nexusDir)
const rbfBal = await getBalance(node, rbfRecipient.address, nexusDir)
const doubleABal = await getBalance(node, doubleA.address, nexusDir)
const doubleBBal = await getBalance(node, doubleB.address, nexusDir)
const idemFinalNonce = await getNonce(node, users.idem.address, nexusDir)

if (sigBal !== 100) await fail(`valid-after-bad-signature balance ${sigBal} != 100`)
if (idemBal !== 100 || idemFinalNonce !== idemNonce + 1) {
  await fail(`duplicate submit applied more than once: balance=${idemBal} nonce=${idemFinalNonce}`)
}
if (rbfBal !== 120) await fail(`RBF winner balance ${rbfBal} != 120`)
if ((doubleABal === 1000) === (doubleBBal === 900)) {
  await fail(`double-spend result must have exactly one winner: A=${doubleABal} B=${doubleBBal}`)
}

console.log('\n[7] Reject replay and far-future nonce after mining...')
const replay = await trySubmitTx(node, {
  chainPath: [nexusDir], nonce: sigNonce, signers: [users.sig.address], fee: FEE,
  accountActions: [
    { owner: users.sig.address, delta: -51 },
    { owner: sigReplayRecipient.address, delta: 50 },
  ],
}, nexusDir, users.sig)
if (replay.ok) await fail('mined nonce replay accepted')

const gapNonce = await getNonce(node, users.sig.address, nexusDir) + 100
const gapRecipient = genKeypair()
const gap = await trySubmitTx(node, {
  chainPath: [nexusDir], nonce: gapNonce, signers: [users.sig.address], fee: FEE,
  accountActions: [
    { owner: users.sig.address, delta: -51 },
    { owner: gapRecipient.address, delta: 50 },
  ],
}, nexusDir, users.sig)
if (gap.ok) await fail('far-future nonce accepted')

console.log('  replay and far-future nonce rejected')
console.log('\n✓ wallet-under-attack smoke test passed.')
await node.stop()
await sleep(500)
process.exit(0)
