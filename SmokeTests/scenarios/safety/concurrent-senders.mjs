// Concurrent senders: multiple users submit txs simultaneously while the
// miner is running. Verifies mempool handles contention correctly and all
// valid txs eventually land in blocks with correct final balances.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('concurrent-senders')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 65 })
const NUM_USERS = 5
const FUND = 5000
const SEND = 100
const FEE = 1

console.log('=== concurrent-senders smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await sleep(2000)

console.log(`\n[1] Fund ${NUM_USERS} users...`)
const users = Array.from({ length: NUM_USERS }, () => genKeypair())

await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
let fundNonce = await getNonce(node, minerAddr, nexusDir)
for (let i = 0; i < users.length; i++) {
  const r = await submitTx(node, {
    chainPath: [nexusDir], nonce: fundNonce + i, signers: [minerAddr], fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(FUND + FEE) },
      { owner: users[i].address, delta: FUND },
    ],
  }, nexusDir, minerKP)
  if (!r.ok) throw new Error(`fund user ${i} failed: ${JSON.stringify(r.submit)}`)
}
await startMining(node, nexusDir)
for (const u of users) {
  await waitFor(async () => (await getBalance(node, u.address, nexusDir)) >= FUND,
    `user funded`, { timeoutMs: 120_000 })
}
console.log(`  all ${NUM_USERS} users funded with ${FUND}`)

console.log(`\n[2] All users send concurrently while mining...`)
const recipient = genKeypair()
const submissions = await Promise.all(users.map(async (user) => {
  const nonce = await getNonce(node, user.address, nexusDir)
  const r = await submitTx(node, {
    chainPath: [nexusDir], nonce, signers: [user.address], fee: FEE,
    accountActions: [
      { owner: user.address, delta: -(SEND + FEE) },
      { owner: recipient.address, delta: SEND },
    ],
  }, nexusDir, user)
  return { address: user.address, ok: r.ok, nonce }
}))

const accepted = submissions.filter(s => s.ok).length
const rejected = submissions.filter(s => !s.ok).length
console.log(`  submitted: ${accepted} accepted, ${rejected} rejected`)

if (accepted === 0) {
  console.error(`  ✗ no concurrent txs accepted`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`\n[3] Wait for all txs to land...`)
await sleep(5000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const recipBal = await getBalance(node, recipient.address, nexusDir)
console.log(`  recipient balance: ${recipBal} (expected ${accepted * SEND})`)

if (recipBal !== accepted * SEND) {
  console.error(`  ✗ recipient got ${recipBal}, expected ${accepted * SEND}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ recipient received exactly ${accepted} × ${SEND} = ${recipBal}`)

let totalUserBal = 0
for (const user of users) {
  totalUserBal += await getBalance(node, user.address, nexusDir)
}
const expectedTotalUser = NUM_USERS * FUND - accepted * (SEND + FEE)
console.log(`  total user balance: ${totalUserBal} (expected ${expectedTotalUser})`)

if (totalUserBal !== expectedTotalUser) {
  console.error(`  ✗ user balances don't add up`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ balances consistent across all accounts`)

console.log(`\n✓ concurrent-senders smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
