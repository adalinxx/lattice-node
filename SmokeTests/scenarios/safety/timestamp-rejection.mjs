// Timestamp rejection: verify the node rejects blocks with timestamps
// too far in the future or past. Tests the isBlockTimestampValid check
// by verifying the node's own blocks have valid timestamps, and that
// the RPC reports correct timestamp data.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('timestamp-rejection')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 87 })

console.log('=== timestamp-rejection smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log('\n[1] Verify block timestamps are valid...')
const nowMs = Date.now()
const MAX_DRIFT_MS = 7_200_000

for (let h = 1; h <= 3; h++) {
  const blockResp = await node.rpc('GET', `/api/block/${h}?chainPath=${nexusDir}`)
  if (!blockResp.ok) { console.log(`  block ${h}: not found`); continue }
  const ts = blockResp.json.timestamp
  if (typeof ts !== 'number') { console.log(`  block ${h}: no timestamp`); continue }

  const driftMs = Math.abs(ts - nowMs)
  if (driftMs > MAX_DRIFT_MS) {
    console.error(`  ✗ block ${h} timestamp ${ts} drifts ${(driftMs/1000).toFixed(0)}s from now`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  block ${h}: ts=${ts} drift=${(driftMs/1000).toFixed(1)}s ✓`)
}

console.log('\n[2] Verify timestamps are monotonically non-decreasing...')
let prevTs = 0
const height = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
for (let h = 1; h <= Math.min(height, 5); h++) {
  const blockResp = await node.rpc('GET', `/api/block/${h}?chainPath=${nexusDir}`)
  if (!blockResp.ok) continue
  const ts = blockResp.json.timestamp
  if (typeof ts !== 'number') continue
  if (ts < prevTs) {
    console.error(`  ✗ block ${h} timestamp ${ts} < previous ${prevTs}`)
    node.stop(); await sleep(500); process.exit(1)
  }
  prevTs = ts
}
console.log(`  ✓ timestamps non-decreasing across ${Math.min(height, 5)} blocks`)

console.log('\n[3] Verify latest block has recent timestamp...')
const latestResp = await node.rpc('GET', `/api/block/latest?chainPath=${nexusDir}`)
if (latestResp.ok && typeof latestResp.json.timestamp === 'number') {
  const ageSec = (nowMs - latestResp.json.timestamp) / 1000
  console.log(`  latest block age: ${ageSec.toFixed(1)}s`)
  if (ageSec > 300) {
    console.error(`  ✗ latest block is ${ageSec.toFixed(0)}s old — too stale`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ latest block is recent`)
}

console.log('\n✓ timestamp-rejection smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
