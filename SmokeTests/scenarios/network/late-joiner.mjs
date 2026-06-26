// Late-joiner: A mines Nexus + per-process Payments to meaningful depth, then B
// boots fresh as an UNTRUSTED joiner — peered to A for Nexus only — DISCOVERS
// Payments from its OWN synced GenesisState (not by querying A for the genesis),
// follows it (no genesis-hex / peer / subscribe hand-off), self-resolves the
// genesis, finds A's Payments via getChildPeers, and backfills to A's tip.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('late-joiner')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, payPorts, bPorts] = await allocPorts(3)
const CHILD = 'Payments'
const NEXUS_TARGET_HEIGHT = 10
const CHILD_TARGET_HEIGHT = 7

console.log('=== late-joiner smoke (per-process child; B permissionlessly joins after history) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

console.log('\n[1] Boot A, deploy Payments as per-process child...')
A.start()
await A.waitForRPC()
await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus

const aPayments = net.add(await A.spawnChild({
  directory: CHILD, parentDirectory: nexusDir,
  ports: payPorts, premine: 0,
}))
await aPayments.waitForRPC()
const paymentsGenesis = aPayments._deployInfo.genesisHash
console.log('  A/Payments process up')

console.log(`\n[2] Mine + announce ${CHILD}, reach Nexus ≥ ${NEXUS_TARGET_HEIGHT} / ${CHILD} ≥ ${CHILD_TARGET_HEIGHT}, freeze...`)
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()
await A.announceChild({ nexusDir, child: CHILD, genesisHash: paymentsGenesis })
await waitFor(async () => {
  const [nxH, chH] = await Promise.all([A.height(nexusDir), aPayments.height(CHILD)])
  process.stdout.write(`\r  A: Nexus@${nxH} ${CHILD}@${chH}   `)
  return nxH >= NEXUS_TARGET_HEIGHT && chH >= CHILD_TARGET_HEIGHT ? true : null
}, `A heights ≥ Nexus ${NEXUS_TARGET_HEIGHT} / ${CHILD} ${CHILD_TARGET_HEIGHT}`, { timeoutMs: 240_000, intervalMs: 500 })
await miner.stop()
await Promise.all([
  A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 }),
  aPayments.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 6_000 }),
])

const aNxH = await A.height(nexusDir)
const aChH = await aPayments.height(CHILD)
console.log(`\n  A frozen: Nexus@${aNxH} ${CHILD}@${aChH}`)

console.log('\n[3] Boot B (late joiner): peer A for Nexus ONLY + supervise children...')
B.start(['--peer', A.peerArg(), '--supervise-children'])
await B.waitForRPC()
const bNexus = await waitFor(async () => {
  const [aTip, bTip, bHeight] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir), B.height(nexusDir),
  ])
  return bTip && bTip === aTip ? { height: bHeight, tip: bTip } : null
}, 'B Nexus converged', { timeoutMs: 90_000, intervalMs: 1000 })
console.log(`  ✓ B Nexus converged at height ${bNexus.height}`)

console.log(`\n[4] B: DISCOVER + FOLLOW ${CHILD} from its OWN GenesisState (no genesis/peer hand-off)...`)
const bPayments = await B.followChild({ nexusDir, child: CHILD, expectGenesis: paymentsGenesis })
console.log(`  B/${CHILD} joined permissionlessly, endpoint=${bPayments.endpoint}`)

console.log('\n[5] Waiting for B-Payments to backfill + converge...')
const bChild = await waitFor(async () => {
  const [aTip, bTip, bHeight] = await Promise.all([
    aPayments.tip(CHILD), bPayments.tip(), bPayments.height(),
  ])
  return bTip && bTip === aTip ? { height: bHeight, tip: bTip } : null
}, 'B-Payments converged', { timeoutMs: 180_000, intervalMs: 1000 })

console.log(`\n✓ B late-joined permissionlessly: Nexus@${bNexus.height}, ${CHILD}@${bChild.height}`)
console.log('✓ late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
