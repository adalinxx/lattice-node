// Balance overdraft: attempt to spend more than an account holds.
// Tests:
//   1. User with balance 1000 sends 2000 → rejected
//   2. User sends exactly balance - fee → accepted (drain to zero)
//   3. Verify drained account has balance 0

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('balance-overdraft')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 61 })

console.log('=== balance-overdraft smoke test ===')
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

const user = genKeypair()
const FUND = 1000
const FEE = 1

await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const mn = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce: mn, signers: [minerAddr], fee: FEE,
  accountActions: [
    { owner: minerAddr, delta: -(FUND + FEE) },
    { owner: user.address, delta: FUND },
  ],
}, nexusDir, minerKP)
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= FUND,
  'user funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
console.log(`  user funded with ${FUND}`)

console.log(`\n[1] Overdraft: send 2000 from account with 1000...`)
const recip1 = genKeypair()
const un1 = await getNonce(node, user.address, nexusDir)
const od = await submitTx(node, {
  chainPath: [nexusDir], nonce: un1, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(2000 + FEE) },
    { owner: recip1.address, delta: 2000 },
  ],
}, nexusDir, user)
if (od.ok) {
  await startMining(node, nexusDir)
  await sleep(3000)
  await stopMining(node, nexusDir)
  await awaitMiningQuiesced(node, nexusDir)
  const bal = await getBalance(node, recip1.address, nexusDir)
  if (bal > 0) {
    console.error(`  ✗ overdraft tx credited ${bal} to recipient!`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ⚠ submit accepted but not applied at block level`)
} else {
  console.log(`  ✓ overdraft rejected: ${(od.submit?.error ?? JSON.stringify(od.submit)).slice(0, 80)}`)
}

console.log(`\n[2] Exact drain: send balance - fee...`)
const recip2 = genKeypair()
const un2 = await getNonce(node, user.address, nexusDir)
const bal2 = await getBalance(node, user.address, nexusDir)
const sendAll = bal2 - FEE
const drain = await submitTx(node, {
  chainPath: [nexusDir], nonce: un2, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(sendAll + FEE) },
    { owner: recip2.address, delta: sendAll },
  ],
}, nexusDir, user)
if (!drain.ok) {
  console.error(`  ✗ exact-drain tx rejected: ${JSON.stringify(drain.submit)}`)
  node.stop(); await sleep(500); process.exit(1)
}
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, recip2.address, nexusDir)) >= sendAll,
  'drain tx mined', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
console.log(`  ✓ exact drain accepted (sent ${sendAll})`)

console.log(`\n[3] Verify drained account has balance 0...`)
const finalBal = await getBalance(node, user.address, nexusDir)
if (finalBal !== 0) {
  console.error(`  ✗ drained account has balance ${finalBal} (expected 0)`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ account balance is 0`)

console.log(`\n✓ balance-overdraft smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
