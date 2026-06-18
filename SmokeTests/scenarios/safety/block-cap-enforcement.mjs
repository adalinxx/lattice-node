// Block cap enforcement.
//
// A child chain with a small maxTransactionsPerBlock must NEVER pack more than
// the cap (including the one reserved coinbase slot) into a single block; excess
// user transactions spill to later blocks and NONE are lost. Replaces the lenient
// "80% landed under a 100-cap" check in large-block.mjs with an exact
// cap-holds + no-loss + forced-spillover check.
//
// Funds the staged txs from a PREMINED account (not the child's coinbase signer):
// the coinbase is signed by the child identity and consumes one of its nonces per
// block, so funding from that identity would collide with staged-tx nonces once
// the txs span multiple capped blocks.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, genKeypair } from 'lattice-node-sdk'

const ROOT = smokeRoot('block-cap-enforcement')
const [{ port, rpcPort }, childPorts] = await allocPorts(2, { seed: 73 })
const CHILD = 'CapTest'
const MAX_TX = 4            // total per block INCLUDING the reserved coinbase slot
const USER_CAP = MAX_TX - 1 // 3 user txs/block; producer reserves 1 for coinbase
const TX_COUNT = 12         // > USER_CAP so it must span >= ceil(12/3)=4 blocks
const FEE = 1

console.log('=== block-cap-enforcement smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort }))
node.start()
await node.waitForRPC()
await node.readIdentity()
const info = await node.chainInfo()
const nexusDir = info.nexus

function fail(m) { console.error(`  ✗ ${m}`); net.teardown(); process.exit(1) }

const funder = genKeypair()
console.log(`\n[1] Deploy child maxTransactionsPerBlock=${MAX_TX}, premine a funder account...`)
const child = net.add(await node.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: childPorts,
  initialReward: 1024, maxTransactionsPerBlock: MAX_TX,
  premine: 1, premineRecipient: funder.address, // premineAmount = 1*1024 = 1024 > 12*11
}))

await node.mineToHeight(5, nexusDir, { timeoutMs: 180_000 })
const miner = new LatticeMiner(node, [child])
await miner.start()
net.addMiner(miner)
await child.waitForHeight(5, CHILD, { timeoutMs: 120_000 })
await miner.stop()
await child.awaitQuiesced(CHILD)

const funderBal = await child.balance(funder.address, CHILD)
if (funderBal < TX_COUNT * (10 + FEE)) fail(`funder premine ${funderBal} insufficient for ${TX_COUNT} txs`)

console.log(`\n[2] Stage ${TX_COUNT} txs (> cap) from premined funder...`)
const recipients = []
const baseNonce = await child.nonce(funder.address, CHILD)
let staged = 0
for (let i = 0; i < TX_COUNT; i++) {
  const recip = genKeypair()
  recipients.push(recip)
  const r = await child.submitTx({
    chainPath: [nexusDir, CHILD], nonce: baseNonce + i, signers: [funder.address], fee: FEE,
    accountActions: [{ owner: funder.address, delta: -(10 + FEE) }, { owner: recip.address, delta: 10 }],
  }, CHILD, funder)
  if (r.ok) staged++
}
if (staged !== TX_COUNT) fail(`only staged ${staged}/${TX_COUNT} txs`)
console.log(`  staged ${staged}/${TX_COUNT}`)

const preHeight = await child.height(CHILD)
console.log(`\n[3] Mine; require ALL ${TX_COUNT} included (no loss)...`)
await miner.start()
let funded = 0
try {
  await waitFor(async () => {
    funded = 0
    for (const r of recipients) { if ((await child.balance(r.address, CHILD)) >= 10) funded++ }
    return funded === TX_COUNT ? funded : null
  }, `all ${TX_COUNT} capped txs landed`, { timeoutMs: 180_000, intervalMs: 1000 })
} catch {}
if (funded < TX_COUNT) {
  // One last direct sample before stopping the miner keeps the failure message
  // exact while still letting waitFor apply the suite's timeout scale above.
  funded = 0
  for (const r of recipients) { if ((await child.balance(r.address, CHILD)) >= 10) funded++ }
}
await miner.stop()
await child.awaitQuiesced(CHILD)
const postHeight = await child.height(CHILD)
if (funded !== TX_COUNT) fail(`only ${funded}/${TX_COUNT} txs landed — excess dropped (cap must spill, not drop)`)
console.log(`  ✓ all ${TX_COUNT} txs confirmed across heights ${preHeight}..${postHeight}`)

console.log(`\n[4] Assert NO block exceeds maxTransactionsPerBlock=${MAX_TX} (incl coinbase) + cap forced spillover...`)
// /block/{h}/transactions INCLUDES the coinbase, and the producer reserves one
// slot for it, so per block: total <= MAX_TX and user txs (total-1) <= USER_CAP.
let maxUserSeen = 0, userBlocks = 0
const queryPath = child._queryPath(CHILD)
for (let h = preHeight + 1; h <= postHeight; h++) {
  const tr = await child.rpc('GET', `/api/block/${h}/transactions?chainPath=${queryPath}`)
  if (!tr.ok) fail(`block ${h} transactions fetch failed: ${JSON.stringify(tr.json)}`)
  const list = Array.isArray(tr.json) ? tr.json : (tr.json.transactions ?? [])
  if (list.length > MAX_TX) fail(`block ${h} has ${list.length} txs (incl coinbase) > cap ${MAX_TX}`)
  const userTx = Math.max(0, list.length - 1) // exclude the single coinbase
  if (userTx > USER_CAP) fail(`block ${h} packed ${userTx} user txs > cap ${USER_CAP}`)
  if (userTx > 0) userBlocks++
  if (userTx > maxUserSeen) maxUserSeen = userTx
}
const minBlocks = Math.ceil(TX_COUNT / USER_CAP)
if (userBlocks < minBlocks) fail(`user txs spread over only ${userBlocks} blocks; cap ${USER_CAP}/block for ${TX_COUNT} txs requires >= ${minBlocks} (cap not actually limiting)`)
console.log(`  ✓ max user txs in any block = ${maxUserSeen} <= ${USER_CAP}; spread over ${userBlocks} blocks (>= ${minBlocks})`)

console.log(`\n✓ block-cap-enforcement smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
