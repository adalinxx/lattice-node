// Premine correctness: deploy a per-process child chain with an explicit
// premine amount and premineRecipient, verify the recipient receives the
// configured premine, and verify merged-mined child rewards credit the child
// process coinbase address.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, genKeypair } from 'lattice-node-sdk'

const ROOT = smokeRoot('premine-correctness')
const [{ port, rpcPort }, childPorts] = await allocPorts(2, { seed: 69 })
const CHILD = 'PremineTest'
const PREMINE = 50000
const REWARD = 512

console.log('=== premine-correctness smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort }))
node.start()
await node.waitForRPC()
await node.readIdentity()

const info = await node.chainInfo()
const nexusDir = info.nexus

const premineRecipient = genKeypair()
console.log(`  premineRecipient: ${premineRecipient.address.slice(0, 24)}...`)

console.log(`\n[1] Deploy child chain (per-process) with premine=${PREMINE} to recipient...`)
// The child runs as its own process; the coordinator merge-mines it via
// --child-node. The child signs and receives coinbase locally.
const childNode = await node.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  initialReward: REWARD,
  premine: PREMINE,
  premineRecipient: premineRecipient.address,
})
net.add(childNode)
const childRewardAddr = childNode._keypair.address

// Mine Nexus solo first so the child syncs the parent chain from genesis (its
// parent-block view builds in order); then merge-mine so the child advances via
// extracted candidates.
await node.mineToHeight(5, nexusDir, { timeoutMs: 180_000 })

const miner = new LatticeMiner(node, [childNode])
await miner.start()
net.addMiner(miner)
await childNode.waitForHeight(5, CHILD, { timeoutMs: 120_000 })
await miner.stop()
await childNode.awaitQuiesced(CHILD)

console.log(`\n[2] Check premine recipient balance...`)
const recipBal = await childNode.balance(premineRecipient.address, CHILD)
console.log(`  recipient balance: ${recipBal}`)

const expectedPremine = PREMINE * REWARD
if (recipBal < expectedPremine) {
  console.error(`  ✗ premine recipient has ${recipBal}, expected at least ${expectedPremine}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ premine recipient has ≥${expectedPremine}`)

console.log(`\n[3] Check child coinbase accumulation...`)
const minerBal = await childNode.balance(childRewardAddr, CHILD)
const childHeight = await childNode.height(CHILD)
const expectedMiner = childHeight * REWARD
console.log(`  child coinbase balance: ${minerBal} (height=${childHeight}, expected coinbase≈${expectedMiner})`)

if (minerBal < expectedMiner - REWARD * 2) {
  console.error(`  ✗ child coinbase balance too low — coinbase not accumulating`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ child coinbase receives rewards`)

console.log(`\n[4] Verify premine didn't go to child coinbase (if recipient != coinbase)...`)
if (premineRecipient.address !== childRewardAddr) {
  const totalExpected = recipBal + minerBal
  console.log(`  total tracked: ${totalExpected} (premine + coinbase)`)
  if (minerBal > expectedMiner + REWARD * 2) {
    console.error(`  ✗ child coinbase balance too high — premine may have leaked to coinbase`)
    net.teardown(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ premine correctly separated from coinbase`)
}

console.log(`\n✓ premine-correctness smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
