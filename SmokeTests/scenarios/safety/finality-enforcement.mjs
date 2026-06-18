// Historical filename retained: this scenario verifies the node-local
// confirmation-depth policy exposed by /api/finality. `isFinal` means "below
// this node's configured local confirmation horizon"; it is not protocol
// finality and this scenario does not assert sync or reorg refusal.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { startMining, stopMining, tipInfo, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('finality-enforcement')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 211 })
const LOCAL_CONFIRMATIONS = 3

console.log('=== finality-enforcement smoke test (local confirmation depth) ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start({ extraArgs: ['--finality-confirmations', String(LOCAL_CONFIRMATIONS)] })
await node.waitForRPC()

const info = await node.rpc('GET', '/api/chain/info')
const nexus = info.json.nexus

console.log('\n[1] Mine blocks past the local confirmation horizon...')
await startMining(node, nexus)
await waitForHeight(node, nexus, 8, 60_000)
await stopMining(node, nexus)
await sleep(2000)

const tip = await tipInfo(node, nexus)
console.log(`  Chain at height=${tip.height}`)

console.log('\n[2] Check local finality config...')
const finalityConfig = await node.rpc('GET', `/api/finality/config?chainPath=${nexus}`)
if (!finalityConfig.ok) {
  throw new Error(`finality/config failed: ${JSON.stringify(finalityConfig.json)}`)
}
const confirmationsRequired = finalityConfig.json?.chains?.[0]?.confirmations
console.log(`  Local confirmation horizon=${confirmationsRequired}`)
if (confirmationsRequired !== LOCAL_CONFIRMATIONS) {
  throw new Error(`Expected local confirmations=${LOCAL_CONFIRMATIONS} got ${confirmationsRequired}`)
}

console.log('\n[3] Check an old block and the current tip...')
const height1Finality = await node.rpc('GET', `/api/finality/1?chainPath=${nexus}`)
if (!height1Finality.ok) {
  throw new Error(`finality query failed: ${JSON.stringify(height1Finality.json)}`)
}
const h1Final = height1Finality.json
console.log(`  Height 1: confirmations=${h1Final.confirmations} required=${h1Final.required} isFinal=${h1Final.isFinal}`)

if (h1Final.confirmations !== tip.height - 1) {
  throw new Error(`Expected confirmations=${tip.height - 1} got ${h1Final.confirmations}`)
}
if (h1Final.required !== LOCAL_CONFIRMATIONS) {
  throw new Error(`Expected required=${LOCAL_CONFIRMATIONS} got ${h1Final.required}`)
}
if (h1Final.isFinal !== true) {
  throw new Error(`Height 1 should be locally final after ${h1Final.confirmations} confirmations`)
}
console.log(`  ✓ old block is locally final after ${h1Final.confirmations} confirmations`)

const currentTipFinality = await node.rpc('GET', `/api/finality/${tip.height}?chainPath=${nexus}`)
if (!currentTipFinality.ok) {
  throw new Error(`tip finality query failed: ${JSON.stringify(currentTipFinality.json)}`)
}
const ctf = currentTipFinality.json
console.log(`  Tip height=${tip.height}: isFinal=${ctf.isFinal} confirmations=${ctf.confirmations}`)
if (ctf.confirmations !== 0) {
  throw new Error(`Expected tip confirmations=0 got ${ctf.confirmations}`)
}
if (ctf.isFinal !== false) {
  throw new Error('Current tip should not be locally final')
}
console.log('  ✓ current tip is not locally final')

console.log('\n[4] Check a future height...')
const futureFinality = await node.rpc('GET', `/api/finality/${tip.height + 100}?chainPath=${nexus}`)
if (futureFinality.ok) {
  const ff = futureFinality.json
  console.log(`  Future block: isFinal=${ff.isFinal} confirmations=${ff.confirmations}`)
  if (ff.isFinal || ff.confirmations > 0) throw new Error('Future block cannot be locally final')
  console.log('  ✓ future height is not locally final')
}

console.log('\n✓ finality-enforcement smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
