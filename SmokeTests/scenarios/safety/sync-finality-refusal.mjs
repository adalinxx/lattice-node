// Historical filename retained: this scenario used to assert sync-time
// "finality refusal." Lattice has no protocol finality floor; /api/finality
// reports node-local confirmation depth only. A block can be locally "final"
// under --finality-confirmations while a strictly heavier same-genesis sync is
// still accepted by heaviest-work fork choice.
//
// Scenario:
//   A mines 8 blocks with --finality-confirmations 3 and verifies height 1 is
//   locally final according to A's confirmation-depth policy.
//   B mines an alternative same-genesis chain to height 12.
//   When A connects to B, A should adopt B's heavier tip. Local finality status
//   must not be treated as protocol finality or a sync-refusal rule.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('sync-finality-refusal')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, bPorts] = await allocPorts(2)
const LOCAL_CONFIRMATIONS = 3

console.log('=== sync-finality-refusal smoke test (no protocol finality floor) ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

// A: reports local finality after 3 confirmations
const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
// B: mines an independent same-genesis branch
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

console.log('\n[1] Boot A with --finality-confirmations 3, mine to height 8...')
A.start(['--finality-confirmations', String(LOCAL_CONFIRMATIONS)])
await A.waitForRPC()
await A.readIdentity()
const aInfo = await A.chainInfo()
const nexusDir = aInfo.nexus
const aGenesis = aInfo.genesisHash

await A.startMining(nexusDir)
await A.waitForHeight(8, nexusDir, { timeoutMs: 180_000 })
await A.stopMining(nexusDir)
await A.awaitQuiesced(nexusDir)
const aTip = await A.tip(nexusDir)
const aHeight = await A.height(nexusDir)
console.log(`  A: height=${aHeight} tip=${aTip.slice(0, 12)}…`)

const localFinalityResp = await A.rpc('GET', `/api/finality/1?chainPath=${nexusDir}`)
if (!localFinalityResp.ok) {
  throw new Error(`A finality query failed: ${JSON.stringify(localFinalityResp.json)}`)
}
const localFinality = localFinalityResp.json
console.log(`  A height 1 local status: confirmations=${localFinality.confirmations} required=${localFinality.required} isFinal=${localFinality.isFinal}`)
if (localFinality.required !== LOCAL_CONFIRMATIONS || localFinality.confirmations !== aHeight - 1 || localFinality.isFinal !== true) {
  throw new Error(`Unexpected local finality status: ${JSON.stringify(localFinality)}`)
}

console.log('\n[2] Boot B independently on the same dev genesis, mine to height 12...')
B.start()
await B.waitForRPC()
const bInfo = await B.chainInfo()
const bNexus = bInfo.nexus
if (bInfo.genesisHash !== aGenesis) {
  throw new Error(`Expected same dev genesis; A=${aGenesis} B=${bInfo.genesisHash}`)
}
await B.startMining(bNexus)
await B.waitForHeight(12, bNexus, { timeoutMs: 240_000 })
await B.stopMining(bNexus)
await B.awaitQuiesced(bNexus)
const bTip = await B.tip(bNexus)
const bHeight = await B.height(bNexus)
console.log(`  B: height=${bHeight} tip=${bTip.slice(0, 12)}…`)

// Verify they're on different branches of the same genesis chain.
if (aTip === bTip) {
  console.error('  ✗ A and B already share tip — no competing branch to sync')
  net.teardown(); await sleep(500); process.exit(1)
}
if (bHeight <= aHeight) {
  console.error(`  ✗ B is not heavier by height: A=${aHeight} B=${bHeight}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log('\n[3] Connect A to B (B is heavier, checkSyncNeeded fires)...')
await B.readIdentity()
const bP2P = B.peerArg()

// Restart A with B as peer so sync attempt fires.
await A.stop()
async function portFree(port) {
  try {
    const { createServer } = await import('node:net')
    const srv = createServer()
    return new Promise((res) => { srv.once('error', () => res(false)); srv.listen(port, '127.0.0.1', () => { srv.close(); res(true) }) })
  } catch { return false }
}
await waitFor(async () => {
  const [p, r] = await Promise.all([portFree(aPorts.port), portFree(aPorts.rpcPort)])
  if (!p || !r) return null
  await sleep(300)
  const [p2, r2] = await Promise.all([portFree(aPorts.port), portFree(aPorts.rpcPort)])
  return p2 && r2 ? true : null
}, 'A ports free', { timeoutMs: 15_000, intervalMs: 500 })
A.invalidateChainInfoCache()
A.start(['--finality-confirmations', String(LOCAL_CONFIRMATIONS), '--peer', bP2P])
await A.waitForRPC(30_000)

await waitFor(async () => {
  const t = await A.tip(nexusDir)
  return t === bTip ? t : null
}, 'A adopted B heavier sync tip', { timeoutMs: 120_000, intervalMs: 2000 })

const aTipAfter = await A.tip(nexusDir)
const aHeightAfter = await A.height(nexusDir)
console.log(`\n[4] Check A accepted the heavier same-genesis sync...`)
console.log(`  A before: tip=${aTip.slice(0, 12)}… height=${aHeight}`)
console.log(`  A after:  tip=${aTipAfter.slice(0, 12)}… height=${aHeightAfter}`)
console.log(`  B:        tip=${bTip.slice(0, 12)}… height=${bHeight}`)

if (aTipAfter !== bTip) {
  console.error(`  ✗ FAILURE: A did not adopt B's heavier same-genesis chain`)
  console.error(`    Local finality status must not act as protocol finality.`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`  ✓ A adopted B's heavier chain; local confirmation depth did not refuse sync`)
console.log('\n✓ sync-finality-refusal passed.')
await net.teardown()
await sleep(500)
process.exit(0)
