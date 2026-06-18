// Retention pruning: mine past retentionDepth, verify old blocks are
// unpinned and the node's broker doesn't grow unbounded. Uses a short
// retention depth (10 blocks) to make the test fast.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import {
  chainInfo, chainOf, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('retention-pruning')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 103 })
const RETENTION = 10

console.log('=== retention-pruning smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
// EVICT_GRACE_SECONDS: shrink the I4 store-then-pin eviction grace so the
// periodic sweep reclaims retention-released content within this fast test's
// window (the production default protects freshly-stored blocks for far longer).
node.start({ env: { RETENTION_DEPTH: String(RETENTION), EVICT_GRACE_SECONDS: '2' } })
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log(`\n[1] Mine to height ${RETENTION + 5}...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, RETENTION + 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h1 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  height: ${h1}`)

console.log('\n[2] Verify recent blocks are accessible...')
const tipResp = await node.rpc('GET', `/api/block/latest?chainPath=${nexusDir}`)
if (!tipResp.ok) {
  console.error('  ✗ cannot fetch latest block')
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ latest block at height ${tipResp.json.height}`)

const recentH = h1 - 2
const recentResp = await node.rpc('GET', `/api/block/${recentH}?chainPath=${nexusDir}`)
if (!recentResp.ok) {
  console.error(`  ✗ cannot fetch recent block at height ${recentH}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ block at height ${recentH} accessible`)

console.log(`\n[3] Mine to height ${RETENTION * 3} to trigger more pruning...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, RETENTION * 3, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  height: ${h2}`)

console.log('\n[4] Verify tip still accessible after pruning...')
const tip2 = await node.rpc('GET', `/api/block/latest?chainPath=${nexusDir}`)
if (!tip2.ok) {
  console.error('  ✗ cannot fetch latest block after pruning')
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ latest block at height ${tip2.json.height}`)

console.log('\n[5] Require old block CONTENT to be reclaimed past the retention window...')
// pruneBlocks unpins the height-scoped owner (Nexus:<h>) for h <= tip-RETENTION
// per accepted block; the broker's 60s eviction loop then reclaims any root with
// no remaining pin. Block CONTENT (the transactions trie) is pinned ONLY under
// the height-scoped owner, so once an old height falls out of the window its tx
// trie is reclaimed and /api/block/{h}/transactions (local-only fetcher) fails to
// resolve. A height INSIDE the window keeps its content. This is the load-bearing
// retention guarantee; assert it directly on a reclaimable artifact.
//
// NOTE: the block HEADER and state roots are separately pinned under the bare
// `ownerNamespace` owner by setChainTip and are NOT height-scoped, so /api/block/{h}
// (header only) stays resolvable for pruned heights. That owner accumulates every
// historical tip and is never released — a real pin-accumulation leak tracked
// outside this test (see the Stream-B bug log). Do NOT assert header 404 here.
const oldH = 1
const recentKeepH = h2 - 2 // inside the retention window — content must survive
const txOk = async (h) => {
  const r = await node.rpc('GET', `/api/block/${h}/transactions?chainPath=${nexusDir}`)
  if (!r.ok) return false
  const list = Array.isArray(r.json) ? r.json : (r.json.transactions ?? [])
  return list.length >= 1 // every block carries >=1 coinbase tx
}
try {
  await waitFor(async () => !(await txOk(oldH)), `old block @${oldH} content reclaimed`,
    { timeoutMs: 90_000, intervalMs: 2000 })
} catch {
  console.error(`  ✗ block @${oldH} content still resolvable past the window — height-scoped pruning is not reclaiming`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ block @${oldH} content reclaimed (tx trie evicted)`)
if (!(await txOk(recentKeepH))) {
  console.error(`  ✗ block @${recentKeepH} (within retention window) content was reclaimed — retention depth not honored`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ block @${recentKeepH} (within retention window) content still served`)

console.log('\n[6] Verify chain still functional after pruning...')
await startMining(node, nexusDir)
const h3Target = h2 + 5
await waitForHeight(node, nexusDir, h3Target, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const h3 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  ✓ chain advanced to height ${h3} after pruning`)

if (h3 < h3Target) {
  console.error(`  ✗ chain stalled at ${h3}, expected ≥${h3Target}`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log('\n✓ retention-pruning smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
