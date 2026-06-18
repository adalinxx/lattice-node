// Late-joiner: A mines Nexus + per-process Payments to meaningful depth, then B boots
// fresh and discovers the Payments chain via genesis discovery from A. Tests the
// realistic per-process late-join flow:
//   1. B syncs Nexus from A
//   2. B fetches Payments genesis hex from A (on-chain discovery via /chain/genesis)
//   3. B starts per-process B-Payments with that genesis hex
//   4. B-Payments syncs to A-Payments tip

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('late-joiner')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, payPorts, bPorts, bPayPorts] = await allocPorts(4)
const CHILD = 'Payments'
const NEXUS_TARGET_HEIGHT = 10
const CHILD_TARGET_HEIGHT = 7

console.log('=== late-joiner smoke (per-process child; B joins after history is established) ===')
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
console.log('  A/Payments process up')

console.log(`\n[2] Mine Nexus to height ≥ ${NEXUS_TARGET_HEIGHT} and ${CHILD} to height ≥ ${CHILD_TARGET_HEIGHT}...`)
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()
await waitFor(async () => {
  const [nxH, chH] = await Promise.all([A.height(nexusDir), aPayments.height(CHILD)])
  process.stdout.write(`\r  A: Nexus@${nxH} ${CHILD}@${chH}   `)
  return nxH >= NEXUS_TARGET_HEIGHT && chH >= CHILD_TARGET_HEIGHT ? true : null
}, `A heights ≥ Nexus ${NEXUS_TARGET_HEIGHT} / ${CHILD} ${CHILD_TARGET_HEIGHT}`, { timeoutMs: 180_000, intervalMs: 500 })
await miner.stop()
await Promise.all([
  A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 }),
  aPayments.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 6_000 }),
])

const aNxH = await A.height(nexusDir)
const aChH = await aPayments.height(CHILD)
const aNexusP2P = (await A.chainInfo()).p2pAddress
console.log(`\n  A frozen: Nexus@${aNxH} ${CHILD}@${aChH}`)

console.log('\n[3] Boot B, sync Nexus from A...')
B.start(['--peer', A.peerArg()])
await B.waitForRPC()
const bNexus = await waitFor(async () => {
  const [aTip, bTip, aHeight, bHeight] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir), A.height(nexusDir), B.height(nexusDir),
  ])
  return bTip && bTip === aTip ? { height: bHeight, aHeight, tip: bTip } : null
}, 'B Nexus converged', { timeoutMs: 90_000, intervalMs: 1000 })
console.log(`  ✓ B Nexus converged at height ${bNexus.height}`)

console.log('\n[4] B fetches Payments genesis from A (on-chain discovery)...')
const genesisR = await A.rpc('GET', `/api/chain/genesis?chainPath=${encodeURIComponent(`Nexus/${CHILD}`)}`)
if (!genesisR.ok || !genesisR.json?.genesisHex) throw new Error('genesis fetch failed')
const { genesisHex, chainP2PAddress } = genesisR.json
console.log(`  ✓ genesis obtained, peer: ${chainP2PAddress?.slice(0, 30) ?? 'none'}`)

console.log('\n[5] B starts per-process B-Payments, syncs from A-Payments...')
const bPayments = net.add(new LatticeNode({
  name: `B-${CHILD}`, dir: `${ROOT}/B-${CHILD}`,
  port: bPayPorts.port, rpcPort: bPayPorts.rpcPort,
}))
bPayments.start([
  '--genesis-hex', genesisHex,
  '--chain-directory', CHILD,
  '--chain-path', `${nexusDir}/${CHILD}`,
  '--subscribe-p2p', aNexusP2P,
  ...(chainP2PAddress ? ['--peer', chainP2PAddress] : []),
])
await bPayments.waitForRPC()

console.log('\n[6] Waiting for B-Payments to converge...')
const bChild = await waitFor(async () => {
  const [aTip, bTip, aHeight, bHeight] = await Promise.all([
    aPayments.tip(CHILD), bPayments.tip(CHILD), aPayments.height(CHILD), bPayments.height(CHILD),
  ])
  return bTip && bTip === aTip ? { height: bHeight, aHeight, tip: bTip } : null
}, 'B-Payments converged', { timeoutMs: 180_000, intervalMs: 1000 })

console.log(`\n✓ B late-joined: Nexus@${bNexus.height}, ${CHILD}@${bChild.height}`)
console.log('✓ late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
