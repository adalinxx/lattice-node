// SIGTERM under load: mine while submitting a stream of txs, SIGTERM the
// node, restart against the same data-dir, verify the chain advances and
// state is consistent (no DB corruption from mid-write shutdown).

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('sigterm-under-load')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 39 })

console.log('=== sigterm-under-load smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 30_000)

console.log(`\n[1] Blast 20 txs while mining...`)
const recipients = []
let submitted = 0
for (let i = 0; i < 20; i++) {
  const recip = genKeypair()
  recipients.push(recip)
  try {
    const n = await getNonce(node, minerAddr, nexusDir)
    const r = await submitTx(node, {
      chainPath: [nexusDir], nonce: n, signers: [minerAddr], fee: 1,
      accountActions: [
        { owner: minerAddr, delta: -101 },
        { owner: recip.address, delta: 100 },
      ],
    }, nexusDir, minerKP)
    if (r.ok) submitted++
  } catch {
    // node might be slow under load
  }
}
console.log(`  submitted ${submitted}/20 txs`)
await sleep(2000)

const preHeight = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  pre-kill height=${preHeight}`)

console.log(`\n[2] SIGTERM (hard kill)...`)
await node.restart()
await node.waitForRPC(300_000)
console.log(`  ✓ node restarted`)

const postInfo = await chainInfo(node)
const postHeight = postInfo.chains.find(c => c.directory === nexusDir).height
console.log(`  post-restart height=${postHeight}`)
if (postHeight < preHeight - 1) {
  console.error(`  ✗ height regressed from ${preHeight} to ${postHeight}`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`\n[3] Resume mining; verify chain advances...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, postHeight + 5, 60_000)
console.log(`  ✓ chain advancing after restart`)

console.log(`\n[4] Verify state consistency: submit a new tx...`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const postBal = await getBalance(node, minerAddr, nexusDir)
console.log(`  miner balance after restart: ${postBal}`)
if (postBal <= 0) {
  console.error(`  ✗ miner balance is 0 — state lost`)
  node.stop(); await sleep(500); process.exit(1)
}

const checker = genKeypair()
const cn = await getNonce(node, minerAddr, nexusDir)
const cr = await submitTx(node, {
  chainPath: [nexusDir], nonce: cn, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -501 },
    { owner: checker.address, delta: 500 },
  ],
}, nexusDir, minerKP)
if (!cr.ok) throw new Error(`post-restart tx failed: ${JSON.stringify(cr.submit)}`)
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, checker.address, nexusDir)) >= 500,
  'post-restart tx confirmed', { timeoutMs: 30_000 })

console.log(`  ✓ post-restart tx confirmed`)
console.log(`\n✓ sigterm-under-load smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
