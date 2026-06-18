// Two-node sync: A (miner) deploys child chain "Payments" and mines both Nexus
// and Payments; B (follower) bootstraps from A and must converge on both tips.
// Exercises validated block-receive plus child-chain extraction from
// merged-mined Nexus blocks.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, peerCount, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('sync')
const [a, b, childA, childB] = await allocPorts(4, { seed: 91 })
const CHILD = 'Payments'

console.log('=== two-node sync smoke test (Nexus + child) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

console.log('\n[1] Boot node A (miner)...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
const aIdent = await A.readIdentity()
console.log(`  A pubkey: ${aIdent.publicKey.slice(0, 32)}...`)
console.log(`  nexus directory: ${nexusDir}`)

console.log(`\n[2] Deploy child chain "${CHILD}" on A as a separate process...`)
// spawnChild deploys on A and starts the child as a per-process node.
const aPayments = net.add(await A.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childA,
  premine: 0,
}))
const { genesisHex: paymentsGenesisHex, chainP2PAddress: paymentsP2POnA } = aPayments._deployInfo
const aNexusInfo = await A.chainInfo()
const aNexusP2P = aNexusInfo.p2pAddress
// Read A-Payments identity so B-Payments can peer with A-Payments directly for block sync.
const aPaymentsIdent = await aPayments.readIdentity()
const aPaymentsPeerArg = aPayments.peerArg()
console.log(`  A/${CHILD} process up, chainP2P=${paymentsP2POnA}`)

console.log(`\n[3] Boot node B with --peer <A>...`)
B.start([
  '--peer', A.peerArg(),
])
await B.waitForRPC()

// B's Payments child uses A's genesis hex so it shares the same chain.
// It subscribes to A's nexus P2P to extract new Payments blocks via gossip,
// and peers directly with A-Payments for historical block sync.
const bPayments = net.add(new LatticeNode({
  name: `B-${CHILD}`,
  dir: `${ROOT}/B-${CHILD}`,
  port: childB.port,
  rpcPort: childB.rpcPort,
  chainPath: [nexusDir, CHILD],
}))
bPayments.start([
  '--genesis-hex', paymentsGenesisHex,
  '--chain-directory', CHILD,
  '--chain-path', `${nexusDir}/${CHILD}`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', aPaymentsPeerArg,
])
await bPayments.waitForRPC()
console.log(`  B/${CHILD} process up`)

console.log('  letting peers connect...')
await waitFor(async () => (await peerCount(A)) >= 1 && (await peerCount(B)) >= 1,
  'peers connected', { timeoutMs: 15_000 })
await waitFor(async () => (await peerCount(aPayments)) >= 1 && (await peerCount(bPayments)) >= 1,
  `${CHILD} peers connected`, { timeoutMs: 15_000 })
console.log(`  peer counts: A=${await peerCount(A)} B=${await peerCount(B)} A/${CHILD}=${await peerCount(aPayments)} B/${CHILD}=${await peerCount(bPayments)}`)

const NEXUS_TARGET = 18
const CHILD_TARGET = 3
console.log(`\n[4] Mining on A using LatticeMiner until Nexus reaches height ${NEXUS_TARGET} and ${CHILD} reaches height ${CHILD_TARGET}...`)
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()

await waitFor(async () => {
  const [nxH, chH] = await Promise.all([A.height(nexusDir), aPayments.height(CHILD)])
  return nxH >= NEXUS_TARGET && chH >= CHILD_TARGET ? [nxH, chH] : null
}, `A heights Nexus ≥ ${NEXUS_TARGET}, ${CHILD} ≥ ${CHILD_TARGET}`, { timeoutMs: 90_000 })

console.log(`\n[5] Stopping miner to freeze the tip...`)
await miner.stop()
await A.awaitQuiesced(nexusDir)
await aPayments.awaitQuiesced(CHILD)
await sleep(2000)

const aNxH = await A.height(nexusDir)
const aChH = await aPayments.height(CHILD)
const aNxTip = await A.tip(nexusDir)
const aChTip = await aPayments.tip(CHILD)
const minerAddr = computeAddress(aIdent.publicKey)
const aChildBalance = await aPayments.balance(minerAddr, CHILD)
console.log(`  A frozen: ${nexusDir}@${aNxH} tip=${aNxTip.slice(0, 20)}...`)
console.log(`  A frozen: ${CHILD}@${aChH} tip=${aChTip.slice(0, 20)}...`)

// Compare B against A's CURRENT (now-frozen) state each poll, not the values
// captured above: the external miner can land an in-flight block or two after
// awaitQuiesced returns, nudging A's real tip past the snapshot. B correctly
// converges on A's actual final tip, so chasing the live value (stable once the
// miner is truly stopped) is what we must assert — a stale snapshot would never
// match. Require A itself to be stable across the poll so we never compare
// against a mid-flight A tip.
console.log(`\n[6] Waiting for B to converge on both chains...`)
let lastANxTip = null
let lastAChTip = null
await waitFor(async () => {
  const [aNxTipNow, aChHNow, aChTipNow, aChildBalNow] = await Promise.all([
    A.tip(nexusDir),
    aPayments.height(CHILD),
    aPayments.tip(CHILD),
    aPayments.balance(minerAddr, CHILD),
  ])
  const aStable = aNxTipNow === lastANxTip && aChTipNow === lastAChTip
  lastANxTip = aNxTipNow
  lastAChTip = aChTipNow
  if (!aStable) return null
  const [bNxTip, bChH, bChTip, bChildBalance] = await Promise.all([
    B.tip(nexusDir),
    bPayments.height(CHILD),
    bPayments.tip(CHILD),
    bPayments.balance(minerAddr, CHILD),
  ])
  return bNxTip === aNxTipNow &&
    bChH === aChHNow &&
    bChTip === aChTipNow &&
    bChildBalance === aChildBalNow ? true : null
}, 'B converged on Nexus tip and child state', { timeoutMs: 240_000 })

console.log(`✓ B converged: ${nexusDir}@${aNxH}, ${CHILD}@${aChH}`)
console.log('✓ two-node sync smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
