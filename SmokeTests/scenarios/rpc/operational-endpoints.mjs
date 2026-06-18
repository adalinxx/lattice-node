// Operational endpoints: verify /health, /metrics, and rate limiting
// work correctly for production monitoring.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('operational-endpoints')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 105 })

console.log('=== operational-endpoints smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const nexusDir = (await chainInfo(node)).nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 3, 60_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log('\n[1] Health endpoint...')
const health = await fetch(`http://127.0.0.1:${rpcPort}/health`)
const hj = await health.json()
if (hj.status !== 'ok' && hj.status !== 'degraded') {
  console.error(`  ✗ unexpected status: ${hj.status}`)
  node.stop(); await sleep(500); process.exit(1)
}
if (typeof hj.chainHeight !== 'number' || hj.chainHeight < 1) {
  console.error(`  ✗ chainHeight missing or zero`)
  node.stop(); await sleep(500); process.exit(1)
}
if (typeof hj.uptimeSeconds !== 'number') {
  console.error(`  ✗ uptimeSeconds missing`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ status=${hj.status} height=${hj.chainHeight} chains=${hj.chains} uptime=${hj.uptimeSeconds}s`)

console.log('\n[2] Metrics endpoint (Prometheus format)...')
const metricsResp = await fetch(`http://127.0.0.1:${rpcPort}/metrics`)
const metricsText = await metricsResp.text()
const requiredMetrics = [
  'lattice_chain_height',
  'lattice_peer_count',
  'lattice_chain_count',
  'lattice_mempool_size',
]
for (const m of requiredMetrics) {
  if (!metricsText.includes(m)) {
    console.error(`  ✗ missing metric: ${m}`)
    node.stop(); await sleep(500); process.exit(1)
  }
}
const heightMatch = metricsText.match(/lattice_chain_height\{chain="Nexus"\}\s+(\d+)/)
if (!heightMatch || Number(heightMatch[1]) < 1) {
  console.error(`  ✗ chain height metric is zero or missing`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ all required metrics present, Nexus height=${heightMatch[1]}`)

console.log('\n[3] Rate limiting...')
let ok = 0, limited = 0
const burst = 150
for (let i = 0; i < burst; i++) {
  const r = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)
  if (r.ok) ok++; else if (r.status === 429) limited++
}
if (limited === 0) {
  console.error(`  ✗ no requests were rate-limited (sent ${burst})`)
  node.stop(); await sleep(500); process.exit(1)
}
if (ok === 0) {
  console.error(`  ✗ all requests were rate-limited`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${ok} passed, ${limited} throttled out of ${burst}`)

console.log('\n✓ operational-endpoints smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
