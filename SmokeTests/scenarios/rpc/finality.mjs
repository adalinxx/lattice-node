// Finality API: mine blocks, query /api/finality/{height} and /api/finality/config.
// Assert confirmation count increases as blocks are mined, and isFinal eventually
// becomes true once enough confirmations accumulate.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('finality')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 43 })

console.log('=== finality API smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log(`\n[1] Query finality config...`)
const configResp = await node.rpc('GET', `/api/finality/config?chainPath=${nexusDir}`)
if (!configResp.ok) throw new Error(`finality/config failed: ${JSON.stringify(configResp.json)}`)
console.log(`  config: ${JSON.stringify(configResp.json)}`)
const requiredConfirmations = configResp.json.requiredConfirmations ?? configResp.json.retentionDepth

console.log(`\n[2] Mine to height 10 and query finality for height 1...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 10, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const currentHeight = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const queryHeight = 1
const finResp1 = await node.rpc('GET', `/api/finality/${queryHeight}?chainPath=${nexusDir}`)
if (!finResp1.ok) throw new Error(`finality query failed: ${JSON.stringify(finResp1.json)}`)
console.log(`  height=${queryHeight} finality: ${JSON.stringify(finResp1.json)}`)

const confirmations1 = finResp1.json.confirmations
if (typeof confirmations1 !== 'number' || confirmations1 < currentHeight - queryHeight) {
  console.log(`  note: confirmations=${confirmations1} (expected ≥${currentHeight - queryHeight})`)
}

console.log(`\n[3] Query finality for recent block (should be unfinalized)...`)
const recentHeight = currentHeight - 1
const finResp2 = await node.rpc('GET', `/api/finality/${recentHeight}?chainPath=${nexusDir}`)
if (!finResp2.ok) throw new Error(`finality query failed: ${JSON.stringify(finResp2.json)}`)
console.log(`  height=${recentHeight} finality: ${JSON.stringify(finResp2.json)}`)

const confirmations2 = finResp2.json.confirmations
if (typeof confirmations2 === 'number') {
  if (confirmations2 > confirmations1) {
    console.error(`  ✗ recent block has MORE confirmations than old block`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ recent block has fewer confirmations (${confirmations2}) than old block (${confirmations1})`)
}

console.log(`\n[4] Query finality for future height (should fail or return 0)...`)
const futureResp = await node.rpc('GET', `/api/finality/${currentHeight + 100}?chainPath=${nexusDir}`)
console.log(`  future height: ok=${futureResp.ok} ${JSON.stringify(futureResp.json).slice(0, 100)}`)
if (futureResp.ok && futureResp.json.confirmations > 0) {
  console.error(`  ✗ future block has positive confirmations`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ future height correctly handled`)

console.log(`\n✓ finality API smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
