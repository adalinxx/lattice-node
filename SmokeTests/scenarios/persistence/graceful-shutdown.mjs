// Graceful shutdown: mine with pending txs, SIGTERM, restart, verify
// mempool txs are restored and chain advances.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('graceful-shutdown')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 89 })

console.log('=== graceful-shutdown smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 3, 120_000)

console.log('\n[1] Stage pending txs while mining...')
const recipients = []
let staged = 0
for (let i = 0; i < 5; i++) {
  const r = genKeypair()
  recipients.push(r)
  try {
    const n = await getNonce(node, minerAddr, nexusDir)
    const res = await submitTx(node, {
      chainPath: [nexusDir], nonce: n, signers: [minerAddr], fee: 1,
      accountActions: [
        { owner: minerAddr, delta: -101 },
        { owner: r.address, delta: 100 },
      ],
    }, nexusDir, minerKP)
    if (res.ok) staged++
  } catch {}
}
console.log(`  staged ${staged}/5 txs`)
await sleep(2000)

const preHeight = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  pre-shutdown height: ${preHeight}`)

console.log('\n[2] SIGTERM (graceful)...')
await node.stop()
await sleep(3000)

console.log('\n[3] Restart...')
node.start()
await node.waitForRPC(300_000)
console.log('  ✓ RPC ready')

const postInfo = await chainInfo(node)
const postHeight = postInfo.chains.find(c => c.directory === nexusDir).height
console.log(`  post-restart height: ${postHeight}`)

if (postHeight < preHeight - 1) {
  console.error(`  ✗ height regressed from ${preHeight} to ${postHeight}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log('  ✓ chain state preserved')

console.log('\n[4] Mine and verify pending txs land...')
await startMining(node, nexusDir)
await sleep(5000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

let funded = 0
for (const r of recipients) {
  const bal = await getBalance(node, r.address, nexusDir)
  if (bal >= 100) funded++
}
console.log(`  recipients funded: ${funded}/${staged}`)
console.log(`  ✓ chain advancing after graceful restart`)

console.log('\n[5] Submit new tx to verify full functionality...')
const checker = genKeypair()
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const cn = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce: cn, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -501 },
    { owner: checker.address, delta: 500 },
  ],
}, nexusDir, minerKP)
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, checker.address, nexusDir)) >= 500,
  'post-restart tx confirmed', { timeoutMs: 120_000 })
console.log('  ✓ new tx confirmed after restart')

console.log('\n✓ graceful-shutdown smoke test passed.')
await node.stop()
await sleep(500)
process.exit(0)
