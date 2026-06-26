// Restart with child chains: mine Nexus + 2 per-process child chains, submit
// txs on each child, SIGTERM, restart all processes against the same data dirs,
// verify heights and balances, then mine more and submit a new child tx.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, waitForProgress, genKeypair, computeAddress,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('restart-with-children')
const [nexusPorts, alphaPorts, betaPorts] = await allocPorts(3, { seed: 99 })
const CHILD1 = 'Alpha'
const CHILD2 = 'Beta'

console.log('=== restart-with-children smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
}))
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await node.chainInfo()
const nexusDir = info.nexus
let parentP2P = info.p2pAddress

console.log('\n[1] Deploy 2 per-process child chains, mine...')
let alpha = await node.spawnChild({
  directory: CHILD1,
  parentDirectory: nexusDir,
  ports: alphaPorts,
  premine: 20_000,
  premineRecipient: minerAddr,
})
let beta = await node.spawnChild({
  directory: CHILD2,
  parentDirectory: nexusDir,
  ports: betaPorts,
  premine: 20_000,
  premineRecipient: minerAddr,
})
net.add(alpha)
net.add(beta)

const alphaDeploy = alpha._deployInfo
const betaDeploy = beta._deployInfo
const alphaPath = [nexusDir, CHILD1]
const betaPath = [nexusDir, CHILD2]

let miner = new LatticeMiner(node, [alpha, beta])
net.addMiner(miner)
await miner.start()
await waitFor(async () => {
  const [nh, ah, bh] = await Promise.all([
    node.height(nexusDir),
    alpha.height(CHILD1),
    beta.height(CHILD2),
  ])
  return nh >= 5 && ah >= 5 && bh >= 5 ? { nexus: nh, alpha: ah, beta: bh } : null
}, 'Nexus + Alpha + Beta height 5', { timeoutMs: 120_000, intervalMs: 500 })

async function restartMiner() {
  await miner.stop()
  miner = new LatticeMiner(node, [alpha, beta])
  net.addMiner(miner)
  await miner.start()
}

async function stopNodeAndWaitDown(target, { timeoutMs = 30_000 } = {}) {
  await target.stop()
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      await fetch(`${target.base}/api/chain/info`, { signal: AbortSignal.timeout(500) })
    } catch {
      return
    }
    await sleep(500)
  }
  throw new Error(`${target.name} failed to shut down within ${timeoutMs}ms`)
}

console.log('\n[2] Transfer on each child chain...')
const userA = genKeypair()
const userB = genKeypair()
await miner.stop()
await node.awaitQuiesced(nexusDir)
await alpha.awaitQuiesced(CHILD1)
await beta.awaitQuiesced(CHILD2)

const n1 = await alpha.nonce(minerAddr, CHILD1)
const txA = await alpha.submitTx({
  chainPath: alphaPath,
  nonce: n1,
  signers: [minerAddr],
  fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -1001 },
    { owner: userA.address, delta: 1000 },
  ],
}, CHILD1, minerKP)
if (!txA.ok) throw new Error(`submit ${CHILD1} tx failed: ${JSON.stringify(txA)}`)

const n2 = await beta.nonce(minerAddr, CHILD2)
const txB = await beta.submitTx({
  chainPath: betaPath,
  nonce: n2,
  signers: [minerAddr],
  fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -2001 },
    { owner: userB.address, delta: 2000 },
  ],
}, CHILD2, minerKP)
if (!txB.ok) throw new Error(`submit ${CHILD2} tx failed: ${JSON.stringify(txB)}`)

await restartMiner()
await waitFor(async () => (await alpha.balance(userA.address, CHILD1)) >= 1000,
  'userA funded', { timeoutMs: 120_000, intervalMs: 1_000 })
await waitFor(async () => (await beta.balance(userB.address, CHILD2)) >= 2000,
  'userB funded', { timeoutMs: 120_000, intervalMs: 1_000 })
await miner.stop()
await node.awaitQuiesced(nexusDir)
await alpha.awaitQuiesced(CHILD1)
await beta.awaitQuiesced(CHILD2)

const preNx = await node.height(nexusDir)
const preCh1 = await alpha.height(CHILD1)
const preCh2 = await beta.height(CHILD2)
console.log(`  pre-restart: ${nexusDir}@${preNx}, ${CHILD1}@${preCh1}, ${CHILD2}@${preCh2}`)
console.log(`  userA balance on ${CHILD1}: ${await alpha.balance(userA.address, CHILD1)}`)
console.log(`  userB balance on ${CHILD2}: ${await beta.balance(userB.address, CHILD2)}`)

console.log('\n[3] SIGTERM + restart...')
await stopNodeAndWaitDown(alpha)
await stopNodeAndWaitDown(beta)
await stopNodeAndWaitDown(node)

node.start()
await node.waitForRPC(120_000)
parentP2P = (await node.chainInfo()).p2pAddress
alpha.start([
  '--genesis-hex', alphaDeploy.genesisHex,
  '--chain-directory', CHILD1,
  '--chain-path', alphaPath.join('/'),
  '--subscribe-p2p', parentP2P,
  '--peer', alphaDeploy.chainP2PAddress ?? parentP2P,
])
beta.start([
  '--genesis-hex', betaDeploy.genesisHex,
  '--chain-directory', CHILD2,
  '--chain-path', betaPath.join('/'),
  '--subscribe-p2p', parentP2P,
  '--peer', betaDeploy.chainP2PAddress ?? parentP2P,
])
await Promise.all([alpha.waitForRPC(120_000), beta.waitForRPC(120_000)])
console.log('  RPC ready after restart')

console.log('\n[4] Verify all chains restored...')
const postNx = await node.height(nexusDir)
const postCh1 = await alpha.height(CHILD1)
const postCh2 = await beta.height(CHILD2)

if (postNx < preNx - 1) {
  console.error(`  nexus regressed: ${postNx} < ${preNx}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ${nexusDir}@${postNx} (was ${preNx})`)

if (postCh1 < preCh1 - 1) {
  console.error(`  ${CHILD1} regressed: ${postCh1} < ${preCh1}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ${CHILD1}@${postCh1} (was ${preCh1})`)

if (postCh2 < preCh2 - 1) {
  console.error(`  ${CHILD2} regressed: ${postCh2} < ${preCh2}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ${CHILD2}@${postCh2} (was ${preCh2})`)

console.log('\n[5] Verify balances preserved...')
const balA = await alpha.balance(userA.address, CHILD1)
const balB = await beta.balance(userB.address, CHILD2)
if (balA < 1000) {
  console.error(`  userA balance on ${CHILD1}: ${balA} (expected >=1000)`)
  net.teardown(); await sleep(500); process.exit(1)
}
if (balB < 2000) {
  console.error(`  userB balance on ${CHILD2}: ${balB} (expected >=2000)`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  userA=${balA} userB=${balB}`)

console.log('\n[6] Mine + new tx after restart...')
const checker = genKeypair()
await restartMiner()
await waitForProgress(
  async () => node.height(nexusDir),
  (h) => h > postNx,
  'Nexus advances after restart',
  { stallMs: 90_000, intervalMs: 1_000 },
)
await miner.stop()
await node.awaitQuiesced(nexusDir)
await alpha.awaitQuiesced(CHILD1)

const cn = await alpha.nonce(minerAddr, CHILD1)
const txC = await alpha.submitTx({
  chainPath: alphaPath,
  nonce: cn,
  signers: [minerAddr],
  fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -501 },
    { owner: checker.address, delta: 500 },
  ],
}, CHILD1, minerKP)
if (!txC.ok) throw new Error(`post-restart child tx failed: ${JSON.stringify(txC)}`)
await restartMiner()
await waitFor(async () => (await alpha.balance(checker.address, CHILD1)) >= 500,
  'post-restart tx confirmed', { timeoutMs: 120_000, intervalMs: 1_000 })
console.log('  new tx confirmed on child chain after restart')

console.log('\nrestart-with-children smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
