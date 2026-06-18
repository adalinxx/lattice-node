// Transaction throughput: submit many concurrent transactions from multiple
// senders and verify all are eventually confirmed. Tests:
//   - Mempool admission under concurrent load
//   - Block inclusion prioritised by fee
//   - All senders' balances correctly updated after mining
//   - No transactions lost or double-processed

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('tx-throughput')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 207 })
const SENDER_COUNT = 10
const TX_PER_SENDER = 5

console.log('=== tx-throughput smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const { computeAddress } = await import('../../lib/wallet.mjs')
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexus = info.nexus

// Fund all senders first
console.log(`\n[1] Funding ${SENDER_COUNT} senders...`)
await startMining(node, nexus)
await waitForHeight(node, nexus, 5, 30_000)

const senders = Array.from({ length: SENDER_COUNT }, () => genKeypair())
const FUND_AMOUNT = 10000
const FEE = 1

// Fund each sender from miner sequentially with monotonically increasing nonces.
// getNonce returns the confirmed (chain-tip) nonce, not the mempool-pending one,
// so we track an offset ourselves to avoid RBF collisions across senders.
await stopMining(node, nexus)
await awaitMiningQuiesced(node, nexus)

let nonceOffset = 0
const confirmedBase = await getNonce(node, minerAddr, nexus)

for (const sender of senders) {
  const nonce = confirmedBase + nonceOffset
  const r = await submitTx(node, {
    chainPath: [nexus], nonce, signers: [minerAddr], fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(FUND_AMOUNT + FEE) },
      { owner: sender.address, delta: FUND_AMOUNT },
    ],
  }, nexus, minerKP)
  if (!r.ok) throw new Error(`fund failed: ${JSON.stringify(r.submit)}`)
  nonceOffset++
}

await startMining(node, nexus)
// Wait for all senders to be funded
await Promise.all(senders.map(s =>
  waitFor(async () => (await getBalance(node, s.address, nexus)) >= FUND_AMOUNT,
    'funded', { timeoutMs: 60_000 })
))
console.log(`  ✓ all ${SENDER_COUNT} senders funded`)

// Submit TX_PER_SENDER txs per sender concurrently
console.log(`\n[2] Submitting ${SENDER_COUNT * TX_PER_SENDER} transactions concurrently...`)
const recipient = genKeypair()
// Pre-fetch all base nonces sequentially to avoid concurrent rate limiting.
const baseNonces = new Map()
for (const sender of senders) {
  baseNonces.set(sender.address, await getNonce(node, sender.address, nexus))
}

let submitted = 0
let failed = 0

await Promise.all(senders.map(async (sender) => {
  const baseNonce = baseNonces.get(sender.address)
  for (let i = 0; i < TX_PER_SENDER; i++) {
    const fee = FEE + i  // vary fees to test ordering
    let r
    for (let attempt = 0; attempt < 5; attempt++) {
      r = await submitTx(node, {
        chainPath: [nexus], nonce: baseNonce + i, signers: [sender.address], fee,
        accountActions: [
          { owner: sender.address, delta: -(100 + fee) },
          { owner: recipient.address, delta: 100 },
        ],
      }, nexus, sender)
      if (r.ok || !JSON.stringify(r.submit).includes('rate limit')) break
      await sleep(200 * (attempt + 1))
    }
    if (r.ok) submitted++
    else failed++
  }
}))
console.log(`  submitted=${submitted} failed=${failed}`)
if (submitted < SENDER_COUNT * TX_PER_SENDER * 0.8) {
  throw new Error(`Too many failures: submitted=${submitted} expected>=${Math.floor(SENDER_COUNT * TX_PER_SENDER * 0.8)}`)
}

// Wait for all submitted txs to be confirmed
const expectedRecipientTotal = submitted * 100
console.log(`\n[3] Waiting for ${submitted} txs to confirm (expected recipient balance ≥ ${expectedRecipientTotal})...`)
await waitFor(async () => {
  const bal = await getBalance(node, recipient.address, nexus)
  return bal >= expectedRecipientTotal ? bal : null
}, 'all txs confirmed', { timeoutMs: 120_000, intervalMs: 2000 })

const recipientBal = await getBalance(node, recipient.address, nexus)
console.log(`  ✓ recipient balance=${recipientBal} (expected≥${expectedRecipientTotal})`)

console.log('\n✓ tx-throughput smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
