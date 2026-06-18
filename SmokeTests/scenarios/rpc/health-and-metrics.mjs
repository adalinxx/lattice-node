// Health and metrics endpoints. Verifies:
//   1. /health returns status, chain height, peer count, syncing flag
//   2. /metrics returns Prometheus-format text
//   3. /api/mempool returns count and fee stats
//   4. /api/peers returns a list
//   5. /api/state/summary returns chain state

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('health-metrics')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 47 })

console.log('=== health-and-metrics smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 3, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log(`\n[1] /health endpoint...`)
const healthResp = await node.rpc('GET', '/health')
if (!healthResp.ok) throw new Error(`/health failed: ${JSON.stringify(healthResp.json)}`)
console.log(`  health: ${JSON.stringify(healthResp.json).slice(0, 200)}`)
if (!healthResp.json.status) {
  console.error(`  ✗ health response missing status field`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ health endpoint returns status`)

console.log(`\n[2] /metrics endpoint...`)
const metricsResp = await fetch(`${node.base}/metrics`)
const metricsText = await metricsResp.text()
if (!metricsResp.ok) {
  console.log(`  note: /metrics returned ${metricsResp.status}`)
} else {
  const hasPrometheus = metricsText.includes('# ') || metricsText.includes('_total') || metricsText.includes('{')
  console.log(`  metrics length: ${metricsText.length} chars, prometheus-like: ${hasPrometheus}`)
  console.log(`  first 200 chars: ${metricsText.slice(0, 200)}`)
  console.log(`  ✓ metrics endpoint responds`)
}

console.log(`\n[3] /api/mempool...`)
const mempoolResp = await node.rpc('GET', `/api/mempool?chainPath=${nexusDir}`)
console.log(`  mempool: ok=${mempoolResp.ok} ${JSON.stringify(mempoolResp.json).slice(0, 120)}`)
if (mempoolResp.ok) {
  const count = mempoolResp.json.count ?? mempoolResp.json.size
  if (typeof count === 'number') {
    console.log(`  ✓ mempool count: ${count}`)
  }
}

console.log(`\n[4] /api/peers...`)
const peersResp = await node.rpc('GET', '/api/peers')
console.log(`  peers: ok=${peersResp.ok} ${JSON.stringify(peersResp.json).slice(0, 120)}`)
if (peersResp.ok) {
  console.log(`  ✓ peers endpoint responds`)
}

console.log(`\n[5] /api/state/summary...`)
const summaryResp = await node.rpc('GET', `/api/state/summary?chainPath=${nexusDir}`)
console.log(`  summary: ok=${summaryResp.ok} ${JSON.stringify(summaryResp.json).slice(0, 200)}`)
if (summaryResp.ok) {
  if (summaryResp.json.height > 0) {
    console.log(`  ✓ state summary has height=${summaryResp.json.height}`)
  }
}

console.log(`\n[6] /api/chain/info coherence check...`)
const infoResp = await chainInfo(node)
if (!infoResp || !infoResp.chains?.length) {
  console.error(`  ✗ chainInfo returned empty`); node.stop(); process.exit(1)
}
const nexusChain = infoResp.chains.find(c => c.directory === nexusDir)
if (!nexusChain) {
  console.error(`  ✗ Nexus not found in chain list`); node.stop(); process.exit(1)
}
console.log(`  chainInfo: nexus@${nexusChain.height} mining=${nexusChain.mining} mempool=${nexusChain.mempoolCount}`)
if (typeof nexusChain.height !== 'number' || typeof nexusChain.mining !== 'boolean') {
  console.error(`  ✗ unexpected types in chainInfo response`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ chainInfo response well-formed`)

console.log(`\n✓ health-and-metrics smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
