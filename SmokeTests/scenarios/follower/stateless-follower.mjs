// Stateless-follower: realistic permissionless child subscription with no disk.
//
// Real-world flow:
//   1. Entity A deploys a child chain + ANNOUNCES it on-chain (genesisAction).
//   2. A mines Nexus + the child to deep history.
//   3. B boots STATELESS, peers A for Nexus only, and syncs Nexus.
//   4. B DISCOVERS the child from its OWN synced GenesisState — not by querying A
//      for the genesis — and follows it (no genesis-hex / peer / subscribe hand-off).
//      Its reconciler self-resolves the genesis and spawns a STATELESS supervised
//      child (statelessness is inherited from the parent).
//   5. B converges on both tips while holding (almost) no local CAS.
//
// Asserts:
//   - B converges on both tips (Nexus + permissionlessly-joined child)
//   - B stays under the disk budget (stateless mode + stateless followed child leak nothing)

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, dirSizeBytes } from 'lattice-node-sdk'

const ROOT = smokeRoot('stateless-follower')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [a, b, childA] = await allocPorts(3)
const CHILD = 'Payments'
const TARGET_HEIGHT = 15
const DISK_BUDGET_MB = 10

console.log('=== stateless-follower smoke (deep parent history; B permissionlessly follows with no disk) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

console.log('\n[1] Boot A, deploy Payments child chain...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
await A.readIdentity()

const aPayments = net.add(await A.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: childA, premine: 0,
}))
await aPayments.waitForRPC()
const paymentsGenesis = aPayments._deployInfo.genesisHash
console.log('  A/Payments process up')

console.log(`\n[2] Mine + announce ${CHILD}, reach height ≥ ${TARGET_HEIGHT}, freeze...`)
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()
await A.announceChild({ nexusDir, child: CHILD, genesisHash: paymentsGenesis })
await waitFor(async () => {
  const [nxH, chH] = await Promise.all([A.height(nexusDir), aPayments.height(CHILD)])
  process.stdout.write(`\r  A: Nexus@${nxH} ${CHILD}@${chH}   `)
  return nxH >= TARGET_HEIGHT && chH >= TARGET_HEIGHT ? [nxH, chH] : null
}, `A heights ≥ ${TARGET_HEIGHT}`, { timeoutMs: 10 * 60_000, intervalMs: 1000 })
await miner.stop()
await Promise.all([
  A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 }),
  aPayments.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 6_000 }),
])
const aNxH = await A.height(nexusDir)
const aChH = await aPayments.height(CHILD)
console.log(`\n  A frozen: ${nexusDir}@${aNxH} ${CHILD}@${aChH}`)

console.log('\n[3] Boot B STATELESS, peer A for Nexus ONLY + supervise children...')
B.start(['--peer', A.peerArg(), '--stateless', '--supervise-children'])
await B.waitForRPC()
const bNexus = await waitFor(async () => {
  const [aTip, bTip, bHeight] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir), B.height(nexusDir),
  ])
  return bTip && bTip === aTip ? { height: bHeight, tip: bTip } : null
}, 'B synced Nexus to A tip', { timeoutMs: 120_000, intervalMs: 1000 })
console.log(`  ✓ B Nexus converged at height ${bNexus.height} — B now has ${CHILD} in its GenesisState`)

console.log(`\n[4] B: DISCOVER + FOLLOW ${CHILD} from its OWN GenesisState (stateless supervised child)...`)
const bPayments = await B.followChild({ nexusDir, child: CHILD, expectGenesis: paymentsGenesis })
console.log(`  ✓ B/${CHILD} joined permissionlessly (stateless), endpoint=${bPayments.endpoint}`)

console.log(`\n[5] Waiting for B to converge on both chains...`)
const bConverged = await waitFor(async () => {
  const [aNxTip, bNxTip, aChTip, bChTip, bNxH, bChH] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir),
    aPayments.tip(CHILD), bPayments.tip(),
    B.height(nexusDir), bPayments.height(),
  ])
  if (!bNxTip || bNxTip !== aNxTip) return null
  if (!bChTip || bChTip !== aChTip) return null
  return { nexus: bNxH, child: bChH }
}, 'B converged on both tips', { timeoutMs: 180_000, intervalMs: 1000 })

console.log('\n[6] Stop B (and its supervised child), check disk budget...')
await B.stop()
await sleep(2000)

// Supervised children store under B.dir/children/<dir>, so B.dir covers both the
// Nexus follower AND the stateless followed child.
const bTotalSize = dirSizeBytes(B.dir)
const bSizeMB = (bTotalSize / (1024 * 1024)).toFixed(2)
console.log(`  B data-dir total size: ${bSizeMB} MB (budget ${DISK_BUDGET_MB} MB)`)
if (bTotalSize > DISK_BUDGET_MB * 1024 * 1024) {
  console.error(`  ✗ B exceeded disk budget — stateless mode is leaking pins`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ B stayed under disk budget`)

console.log(`\n✓ B converged at ${nexusDir}@${bConverged.nexus}, ${CHILD}@${bConverged.child} with ${bSizeMB}MB on disk`)
console.log('✓ stateless-follower smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
