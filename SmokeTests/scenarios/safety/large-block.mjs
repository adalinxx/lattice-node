// Large block: submit many txs in one mining round, approaching the
// maxTransactionsPerBlock limit. Verify all txs are included and the
// block is valid.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, genKeypair, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('large-block')
const [{ port, rpcPort }, childPorts] = await allocPorts(2, { seed: 71 })
const CHILD = 'PackTest'
const TX_COUNT = 40
const FEE = 1

console.log('=== large-block smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort }))
node.start()
await node.waitForRPC()
await node.readIdentity()

const info = await node.chainInfo()
const nexusDir = info.nexus

console.log(`\n[1] Deploy fast child chain (per-process, maxTx=100)...`)
// Child runs as its own process; the coordinator merge-mines it via --child-node.
// The child node's own --coinbase-address funds the staged txs.
const childNode = await node.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
  initialReward: 1024,
})
net.add(childNode)
const minerAddr = childNode._keypair.address
const minerKP = { privateKey: childNode._identity.privateKey, publicKey: childNode._identity.publicKey }

// One merged miner advances both chains from genesis; the child syncs the parent and
// advances via extracted candidates. (No separate Nexus-only warm-up: the node builds
// each template with full state access.)
const miner = new LatticeMiner(node, [childNode])
await miner.start()
net.addMiner(miner)
await node.waitForHeight(5, nexusDir, { timeoutMs: 2 * 180_000 })
await childNode.waitForHeight(5, CHILD, { timeoutMs: 180_000 })
await miner.stop()
await childNode.awaitQuiesced(CHILD)

console.log(`\n[2] Stage ${TX_COUNT} txs while mining is stopped...`)
const recipients = []
let submitted = 0
const baseNonce = await childNode.nonce(minerAddr, CHILD)
for (let i = 0; i < TX_COUNT; i++) {
  const recip = genKeypair()
  recipients.push(recip)
  const r = await childNode.submitTx({
    chainPath: [nexusDir, CHILD], nonce: baseNonce + i, signers: [minerAddr], fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(10 + FEE) },
      { owner: recip.address, delta: 10 },
    ],
  }, CHILD, minerKP)
  if (r.ok) submitted++
  else console.log(`  tx ${i} rejected: ${(r.error ?? '').slice(0, 60)}`)
}
console.log(`  staged ${submitted}/${TX_COUNT} txs`)

const mempoolResp = await childNode.rpc('GET', `/api/mempool?chainPath=${childNode._queryPath(CHILD)}`)
console.log(`  mempool count: ${mempoolResp.json?.count}`)

console.log(`\n[3] Mine and verify txs are included...`)
const preHeight = await childNode.height(CHILD)
async function countFundedRecipients() {
  let funded = 0
  for (const r of recipients) {
    const bal = await childNode.balance(r.address, CHILD)
    if (bal >= 10) funded++
  }
  return funded
}
async function childMempoolCount() {
  const r = await childNode.rpc('GET', `/api/mempool?chainPath=${childNode._queryPath(CHILD)}`)
  return r.json?.count ?? 0
}
await miner.mineUntil(
  async () => {
    const remaining = await childMempoolCount()
    return remaining <= submitted * 0.2 ? remaining : null
  },
  {
    desc: 'large-block mempool drain',
    timeoutMs: 180_000,
    intervalMs: 1000,
    progress: async () => String(await childNode.height(CHILD)),
  }
)
await miner.stop()
await childNode.awaitQuiesced(CHILD)

const postHeight = await childNode.height(CHILD)
console.log(`  height: ${preHeight} → ${postHeight} (${postHeight - preHeight} blocks)`)

const funded = await countFundedRecipients()
console.log(`  recipients funded: ${funded}/${submitted}`)

if (funded < submitted * 0.8) {
  console.error(`  ✗ too few txs landed: ${funded}/${submitted}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${funded} txs confirmed`)

const postMempool = await childNode.rpc('GET', `/api/mempool?chainPath=${childNode._queryPath(CHILD)}`)
console.log(`  remaining mempool: ${postMempool.json?.count}`)

console.log(`\n✓ large-block smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
