// Investor issuance smoke test.
//
// An investor must be able to verify, from the PUBLIC API alone, the locked
// Nexus monetary policy and that emission is exactly the coinbase subsidy per
// block (no hidden inflation) before the first halving.
//
// Asserts (hard):
//   1. GET /api/chain/spec exposes the locked NexusGenesis issuance params
//      (initialReward, halvingInterval, premine, premineAmount) at their exact
//      committed values, and premineAmount == premine * initialReward.
//   2. Emission is exactly initialReward per accepted block: the node-owned
//      coinbase balance equals height * initialReward (pre-halving, no txs).

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, chainOf, getBalance,
  startMining, stopMining, awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'

// Locked Nexus genesis constants — Sources/LatticeNode/Chain/NexusGenesis.swift.
// Changing these is a flag-day genesis change; this test pins them to the API.
const INITIAL_REWARD = 1_048_576
const HALVING_INTERVAL = 876_600
const PREMINE = 175_320
const PREMINE_AMOUNT = 183_836_344_320 // premine * initialReward

const ROOT = smokeRoot('investor-issuance')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 61 })

console.log('=== investor-issuance smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

function fail(msg) {
  console.error(`  ✗ ${msg}`)
  node.stop()
  process.exit(1)
}

const minerIdent = await node.readIdentity()
const minerAddr = computeAddress(minerIdent.publicKey)
const info = await chainInfo(node)
const nexusDir = info.nexus

console.log('\n[1] Public chain/spec exposes the locked Nexus issuance params...')
const specResp = await node.rpc('GET', `/api/chain/spec?chainPath=${nexusDir}`)
if (!specResp.ok) fail(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const s = specResp.json
const checks = [
  ['initialReward', Number(s.initialReward), INITIAL_REWARD],
  ['halvingInterval', Number(s.halvingInterval), HALVING_INTERVAL],
  ['premine', Number(s.premine), PREMINE],
  ['premineAmount', Number(s.premineAmount), PREMINE_AMOUNT],
]
for (const [name, got, want] of checks) {
  if (got !== want) fail(`${name}=${got} expected ${want}`)
}
if (Number(s.premineAmount) !== Number(s.premine) * Number(s.initialReward)) {
  fail(`premineAmount ${s.premineAmount} != premine*initialReward ${Number(s.premine) * Number(s.initialReward)}`)
}
console.log(`  ✓ initialReward=${s.initialReward} halvingInterval=${s.halvingInterval} premine=${s.premine} premineAmount=${s.premineAmount}`)

console.log('\n[2] Emission == initialReward per block (no inflation, pre-halving)...')
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

// Read height and coinbase balance from the SAME quiesced snapshot so they agree.
const info2 = await chainInfo(node)
const height = chainOf(info2, nexusDir)?.height ?? 0
if (height < 5) fail(`expected height >= 5, got ${height}`)
const minerBal = await getBalance(node, minerAddr, nexusDir)
const expected = height * INITIAL_REWARD
if (minerBal !== expected) {
  fail(`coinbase balance ${minerBal} != height*initialReward ${expected} (height=${height}) — emission is not exactly the subsidy`)
}
console.log(`  ✓ height=${height} coinbase=${minerBal} == ${height}*${INITIAL_REWARD}`)

console.log('\n✓ investor-issuance smoke test passed.')
await node.stop()
await sleep(500)
process.exit(0)
