// Mempool eviction: fill the per-account mempool limit, verify the
// lowest-fee tx is replaced when a higher-fee tx arrives at the same nonce.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('mempool-eviction')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 83 })

console.log('=== mempool-eviction smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start({ extraArgs: ['--mempool', '0'] })
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

async function fail(message) {
  console.error(`  ✗ ${message}`)
  node.stop(); await sleep(500); process.exit(1)
}

async function mempoolStats() {
  let r
  for (let attempt = 0; attempt < 10; attempt++) {
    r = await node.rpc('GET', `/api/mempool?chainPath=${nexusDir}`)
    if (r.ok) return r.json
    if (!JSON.stringify(r.json).includes('rate limit')) break
    await sleep(150 * (attempt + 1))
  }
  throw new Error(`mempool failed: ${JSON.stringify(r?.json)}`)
}

async function submitPayment({ signerAddr, keypair, nonce, fee, recipient, amount = 1 }) {
  let result
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      result = await submitTx(node, {
        chainPath: [nexusDir], nonce, signers: [signerAddr], fee,
        accountActions: [
          { owner: signerAddr, delta: -(amount + fee) },
          { owner: recipient.address, delta: amount },
        ],
      }, nexusDir, keypair)
    } catch (err) {
      if (String(err).includes('rate limit')) {
        await sleep(150 * (attempt + 1))
        continue
      }
      throw err
    }
    if (result.ok || !JSON.stringify(result.submit).includes('rate limit')) return result
    await sleep(150 * (attempt + 1))
  }
  return result
}

console.log(`\n[1] Saturate per-account cap (64 txs) and reject one more...`)
const baseNonce = await getNonce(node, minerAddr, nexusDir)
const PER_ACCOUNT_CAP = 64
const capRecipients = Array.from({ length: PER_ACCOUNT_CAP }, () => genKeypair())
for (let i = 0; i < PER_ACCOUNT_CAP; i++) {
  const r = await submitPayment({
    signerAddr: minerAddr, keypair: minerKP, nonce: baseNonce + i, fee: 1,
    recipient: capRecipients[i], amount: 10,
  })
  if (!r.ok) await fail(`cap tx ${i} rejected: ${JSON.stringify(r.submit)}`)
}
const capStats = await mempoolStats()
console.log(`  mempool after cap fill: count=${capStats.count} totalFees=${capStats.totalFees}`)
if (capStats.count !== PER_ACCOUNT_CAP || capStats.totalFees !== PER_ACCOUNT_CAP) {
  await fail(`expected ${PER_ACCOUNT_CAP} fee=1 txs, got ${JSON.stringify(capStats)}`)
}

const overCapRecipient = genKeypair()
const overCap = await submitPayment({
  signerAddr: minerAddr, keypair: minerKP, nonce: baseNonce + PER_ACCOUNT_CAP, fee: 10,
  recipient: overCapRecipient, amount: 10,
})
if (overCap.ok) await fail(`65th same-account tx was accepted: ${JSON.stringify(overCap.submit)}`)
console.log(`  ✓ 65th same-account tx rejected: ${(overCap.submit?.error ?? '').slice(0, 100)}`)

console.log(`\n[2] RBF replace lowest nonce and assert old package is evicted...`)
const rbfRecipient = genKeypair()
const rbfFee = 100
const rbf = await submitPayment({
  signerAddr: minerAddr, keypair: minerKP, nonce: baseNonce, fee: rbfFee,
  recipient: rbfRecipient, amount: 20,
})
if (!rbf.ok) await fail(`RBF replacement rejected: ${JSON.stringify(rbf.submit)}`)

const rbfStats = await mempoolStats()
console.log(`  mempool after RBF: count=${rbfStats.count} totalFees=${rbfStats.totalFees}`)
if (rbfStats.count !== 1 || rbfStats.totalFees !== rbfFee) {
  await fail(`RBF did not leave exactly the replacement resident: ${JSON.stringify(rbfStats)}`)
}

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, rbfRecipient.address, nexusDir)) >= 20,
  'RBF replacement mined', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const originalBalance = await getBalance(node, capRecipients[0].address, nexusDir)
const rbfBalance = await getBalance(node, rbfRecipient.address, nexusDir)
if (originalBalance !== 0 || rbfBalance !== 20) {
  await fail(`RBF mined wrong body: original=${originalBalance} replacement=${rbfBalance}`)
}
console.log(`  ✓ replacement mined; original low-fee body did not apply`)

console.log(`\n[3] Fill global mempool cap and assert lowest-fee eviction...`)
const fillerA = genKeypair()
const fillerB = genKeypair()
const evictor = genKeypair()
const FILLER_FUND = 1000
const fundBase = await getNonce(node, minerAddr, nexusDir)
for (const [i, recipient] of [fillerA, fillerB, evictor].entries()) {
  const r = await submitPayment({
    signerAddr: minerAddr, keypair: minerKP, nonce: fundBase + i, fee: 1,
    recipient, amount: FILLER_FUND,
  })
  if (!r.ok) await fail(`fund ${i} rejected: ${JSON.stringify(r.submit)}`)
}
await startMining(node, nexusDir)
await Promise.all([fillerA, fillerB, evictor].map((account) =>
  waitFor(async () => (await getBalance(node, account.address, nexusDir)) >= FILLER_FUND,
    `${account.address} funded`, { timeoutMs: 120_000 })
))
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const GLOBAL_CAP = 100
// These accounts were only funded as recipients, so their signer nonces start at 0.
const fillerAFillBase = 0
const fillerBFillBase = 0
const lowFeeRecipient = genKeypair()
for (let i = 0; i < 64; i++) {
  const r = await submitPayment({
    signerAddr: fillerA.address, keypair: fillerA, nonce: fillerAFillBase + i, fee: 2,
    recipient: genKeypair(), amount: 1,
  })
  if (!r.ok) await fail(`global filler A fill ${i} rejected: ${JSON.stringify(r.submit)}`)
}
for (let i = 0; i < 36; i++) {
  const isUniqueLowest = i === 35
  const r = await submitPayment({
    signerAddr: fillerB.address, keypair: fillerB, nonce: fillerBFillBase + i,
    fee: isUniqueLowest ? 1 : 2,
    recipient: isUniqueLowest ? lowFeeRecipient : genKeypair(), amount: 1,
  })
  if (!r.ok) await fail(`global filler B fill ${i} rejected: ${JSON.stringify(r.submit)}`)
}

const fullStats = await mempoolStats()
console.log(`  mempool full: count=${fullStats.count} totalFees=${fullStats.totalFees}`)
if (fullStats.count !== GLOBAL_CAP || fullStats.totalFees !== 199) {
  await fail(`expected global cap full with totalFees=199, got ${JSON.stringify(fullStats)}`)
}

const highFeeRecipient = genKeypair()
const evictNonce = 0
const evicting = await submitPayment({
  signerAddr: evictor.address, keypair: evictor, nonce: evictNonce, fee: 100,
  recipient: highFeeRecipient, amount: 1,
})
if (!evicting.ok) await fail(`high-fee entrant rejected: ${JSON.stringify(evicting.submit)}`)

const evictedStats = await mempoolStats()
console.log(`  mempool after eviction: count=${evictedStats.count} totalFees=${evictedStats.totalFees}`)
if (evictedStats.count !== GLOBAL_CAP || evictedStats.totalFees !== 298) {
  await fail(`expected lowest fee evicted and high fee admitted, got ${JSON.stringify(evictedStats)}`)
}

await startMining(node, nexusDir)
await waitFor(async () => {
  const stats = await mempoolStats()
  return stats.count === 0 ? stats : null
}, 'global mempool drained', { timeoutMs: 120_000, intervalMs: 1000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const lowFeeBalance = await getBalance(node, lowFeeRecipient.address, nexusDir)
const highFeeBalance = await getBalance(node, highFeeRecipient.address, nexusDir)
if (lowFeeBalance !== 0 || highFeeBalance !== 1) {
  await fail(`global eviction mined wrong body: low=${lowFeeBalance} high=${highFeeBalance}`)
}
console.log(`  ✓ lowest-fee tx evicted; high-fee entrant mined`)

console.log(`\n[4] Verify mempool is empty...`)
const postMempool = await mempoolStats()
console.log(`  remaining mempool: ${postMempool.count}`)
if (postMempool.count !== 0) {
  await fail(`mempool not empty after mining: ${JSON.stringify(postMempool)}`)
}

console.log(`\n✓ mempool-eviction smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
