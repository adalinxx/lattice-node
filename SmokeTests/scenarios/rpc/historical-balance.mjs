// Historical balance query: verify /api/block/{height}/state/account/{addr}
// returns correct balance at past heights after transfers.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('historical-balance')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 95 })

async function fail(message) {
  console.error(`  ✗ ${message}`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log('=== historical-balance smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

const specResp = await node.rpc('GET', `/api/chain/spec?chainPath=${nexusDir}`)
if (!specResp.ok) await fail(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const REWARD = specResp.json.initialReward

console.log('\n[1] Mine to height 5, snapshot miner balance...')
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h1 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const balAt3 = await node.rpc('GET', `/api/block/3/state/account/${minerAddr}?chainPath=${nexusDir}`)
console.log(`  balance at block 3: ${JSON.stringify(balAt3.json).slice(0, 100)}`)

if (!balAt3.ok || typeof balAt3.json.balance !== 'number') {
  await fail(`historical account query at height 3 failed: ${JSON.stringify(balAt3.json)}`)
}
if (balAt3.json.blockHeight !== 3 || balAt3.json.address !== minerAddr || balAt3.json.chain !== nexusDir || balAt3.json.exists !== true) {
  await fail(`historical account metadata at height 3 was wrong: ${JSON.stringify(balAt3.json)}`)
}
const expected3 = 3 * REWARD
if (balAt3.json.balance !== expected3) {
  await fail(`balance at height 3 is ${balAt3.json.balance}, expected ${expected3}`)
}
console.log(`  ✓ balance at height 3 matches expected (${expected3})`)

console.log('\n[2] Transfer, mine more, check historical balance...')
const user = genKeypair()
const SEND = 5000
const nonce = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -(SEND + 1) },
    { owner: user.address, delta: SEND },
  ],
}, nexusDir, minerKP)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= SEND,
  'user funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  current height: ${h2}`)

console.log('\n[3] Query user balance at height before transfer...')
const userAtH1 = await node.rpc('GET', `/api/block/${h1}/state/account/${user.address}?chainPath=${nexusDir}`)
if (!userAtH1.ok) {
  await fail(`historical query at pre-transfer height failed: ${JSON.stringify(userAtH1.json)}`)
}
if (userAtH1.json.blockHeight !== h1 || userAtH1.json.address !== user.address || userAtH1.json.chain !== nexusDir || userAtH1.json.exists !== false) {
  await fail(`pre-transfer account metadata was wrong: ${JSON.stringify(userAtH1.json)}`)
}
const balBefore = userAtH1.json.balance ?? 0
console.log(`  user at height ${h1} (before transfer): ${balBefore}`)
if (balBefore !== 0) {
  await fail(`user had balance before transfer`)
}
console.log(`  ✓ user balance was 0 before transfer`)

console.log('\n[4] Query user balance at current height...')
const userAtH2 = await node.rpc('GET', `/api/block/${h2}/state/account/${user.address}?chainPath=${nexusDir}`)
if (!userAtH2.ok) {
  await fail(`historical query at current height failed: ${JSON.stringify(userAtH2.json)}`)
}
if (userAtH2.json.blockHeight !== h2 || userAtH2.json.address !== user.address || userAtH2.json.chain !== nexusDir || userAtH2.json.exists !== true) {
  await fail(`post-transfer account metadata was wrong: ${JSON.stringify(userAtH2.json)}`)
}
console.log(`  user at height ${h2} (after transfer): ${userAtH2.json.balance}`)
if (userAtH2.json.balance !== SEND) {
  await fail(`user balance at height ${h2} is ${userAtH2.json.balance}, expected ${SEND}`)
}
console.log(`  ✓ user balance exact at current height`)

console.log('\n[5] Verify miner balance decreases between heights...')
const minerAtH1 = await node.rpc('GET', `/api/block/${h1}/state/account/${minerAddr}?chainPath=${nexusDir}`)
const minerAtH2 = await node.rpc('GET', `/api/block/${h2}/state/account/${minerAddr}?chainPath=${nexusDir}`)
if (!minerAtH1.ok || !minerAtH2.ok) {
  await fail(`miner historical query failed: h${h1}=${JSON.stringify(minerAtH1.json)} h${h2}=${JSON.stringify(minerAtH2.json)}`)
}
if (minerAtH1.json.blockHeight !== h1 || minerAtH2.json.blockHeight !== h2 || minerAtH1.json.address !== minerAddr || minerAtH2.json.address !== minerAddr) {
  await fail(`miner historical metadata was wrong: h${h1}=${JSON.stringify(minerAtH1.json)} h${h2}=${JSON.stringify(minerAtH2.json)}`)
}
const m1 = minerAtH1.json.balance
const m2 = minerAtH2.json.balance
const coinbase = (h2 - h1) * REWARD
const expectedDelta = coinbase - SEND
const actualDelta = m2 - m1
console.log(`  miner: h${h1}=${m1} h${h2}=${m2} delta=${actualDelta} expected=${expectedDelta}`)
if (actualDelta !== expectedDelta) {
  await fail(`miner delta mismatch: got ${actualDelta}, expected ${expectedDelta}`)
}
console.log(`  ✓ miner balance delta matches exactly`)

console.log('\n✓ historical-balance smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
