// Multi-child miner revenue.
//
// A merged miner running Nexus + >=2 children must collect, ON EACH CHAIN
// SEPARATELY, exactly: coinbase subsidy per block + the fees of that chain's
// included transactions — credited to THAT chain's own coinbase address (not
// pooled to the parent/coordinator). This exercises rewards AND fees and
// cross-validates that each per-process child credits its own --coinbase-address.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, genKeypair } from 'lattice-node-sdk'

const ROOT = smokeRoot('multi-child-miner-revenue')
const [{ port, rpcPort }, c1Ports, c2Ports] = await allocPorts(3, { seed: 77 })
const REWARD = 1024
const K = 3   // fee-bearing txs per child
const FEE = 7

console.log('=== multi-child-miner-revenue smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort }))
node.start()
await node.waitForRPC()
await node.readIdentity()
const info = await node.chainInfo()
const nexusDir = info.nexus
function fail(m) { console.error(`  ✗ ${m}`); net.teardown(); process.exit(1) }

console.log('\n[1] Deploy two children, each premining its own funder...')
const f1 = genKeypair(), f2 = genKeypair()
const c1 = net.add(await node.spawnChild({ directory: 'RevA', parentDirectory: nexusDir, ports: c1Ports, initialReward: REWARD, premine: 1, premineRecipient: f1.address }))
const c2 = net.add(await node.spawnChild({ directory: 'RevB', parentDirectory: nexusDir, ports: c2Ports, initialReward: REWARD, premine: 1, premineRecipient: f2.address }))
const cb1 = c1._keypair.address, cb2 = c2._keypair.address
if (cb1 === cb2) fail('children share a coinbase address')

await node.mineToHeight(5, nexusDir, { timeoutMs: 180_000 })
const miner = new LatticeMiner(node, [c1, c2])
await miner.start()
net.addMiner(miner)
await c1.waitForHeight(3, 'RevA', { timeoutMs: 120_000 })
await c2.waitForHeight(3, 'RevB', { timeoutMs: 120_000 })
await miner.stop()
await c1.awaitQuiesced('RevA'); await c2.awaitQuiesced('RevB')

async function stageOnChild(child, dir, funder) {
  const base = await child.nonce(funder.address, dir)
  const recips = []
  for (let i = 0; i < K; i++) {
    const r = genKeypair(); recips.push(r)
    const sub = await child.submitTx({
      chainPath: [nexusDir, dir], nonce: base + i, signers: [funder.address], fee: FEE,
      accountActions: [{ owner: funder.address, delta: -(10 + FEE) }, { owner: r.address, delta: 10 }],
    }, dir, funder)
    if (!sub.ok) fail(`${dir}: stage tx ${i} rejected: ${JSON.stringify(sub).slice(0, 140)}`)
  }
  return recips
}

console.log('\n[2] Stage fee-bearing txs on each child...')
const r1 = await stageOnChild(c1, 'RevA', f1)
const r2 = await stageOnChild(c2, 'RevB', f2)

console.log('\n[3] Merge-mine; wait for all txs on both children...')
await miner.start()
async function allFunded(child, dir, recips) {
  let n = 0; for (const r of recips) { if ((await child.balance(r.address, dir)) >= 10) n++ }
  return n === recips.length
}
for (let t = 0; t < 120; t++) {
  if (await allFunded(c1, 'RevA', r1) && await allFunded(c2, 'RevB', r2)) break
  await sleep(1000)
}
await miner.stop()
await c1.awaitQuiesced('RevA'); await c2.awaitQuiesced('RevB')

if (!(await allFunded(c1, 'RevA', r1))) fail('RevA txs did not all confirm')
if (!(await allFunded(c2, 'RevB', r2))) fail('RevB txs did not all confirm')

console.log('\n[4] Assert per-chain revenue = height*reward + collected fees, on each chain separately...')
async function checkRevenue(child, dir, cbAddr) {
  const h = await child.height(dir)
  const cbBal = await child.balance(cbAddr, dir)
  const expected = h * REWARD + K * FEE // subsidy per block + this chain's collected tx fees
  if (cbBal !== expected) fail(`${dir}: coinbase ${cbBal} != height*reward + fees ${expected} (h=${h}, reward=${REWARD}, fees=${K}*${FEE})`)
  console.log(`  ✓ ${dir}: coinbase=${cbBal} == ${h}*${REWARD} + ${K}*${FEE}`)
}
await checkRevenue(c1, 'RevA', cb1)
await checkRevenue(c2, 'RevB', cb2)

// Cross-validate the bug-#1 fix: each child's reward is on ITS OWN coinbase, not
// pooled onto the parent node's address on the child chain.
const nodeAddrOnC1 = await c1.balance(node._keypair.address, 'RevA')
if (nodeAddrOnC1 !== 0) fail(`parent address holds ${nodeAddrOnC1} on RevA — child reward leaked to coordinator`)
console.log(`  ✓ child rewards credited to each child's own coinbase (parent address holds 0 on child)`)

console.log('\n✓ multi-child-miner-revenue smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
