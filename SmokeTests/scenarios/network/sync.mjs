// Two-node sync: A (miner) deploys + ANNOUNCES child chain "Payments" and mines
// both Nexus and Payments; B is an UNTRUSTED joiner — peered to A for Nexus only,
// it DISCOVERS Payments from its own synced GenesisState, follows it (no genesis
// hex / peer / subscribe hand-off), self-resolves the genesis, finds A's Payments
// via getChildPeers, and must converge on BOTH tips + the child account state.
// Exercises validated block-receive + child extraction + permissionless join.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, peerCount, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('sync')
const [a, b, childA] = await allocPorts(3, { seed: 91 })
const CHILD = 'Payments'

console.log('=== two-node sync smoke test (Nexus + permissionlessly-joined child) ===')
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

console.log(`\n[2] A: deploy child "${CHILD}" (operator) as a separate process + mine both...`)
const aPayments = net.add(await A.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childA,
  premine: 0,
}))
const paymentsGenesisHash = aPayments._deployInfo.genesisHash
console.log(`  A/${CHILD} process up, genesis=${paymentsGenesisHash.slice(0, 20)}...`)

const NEXUS_TARGET = 18
const CHILD_TARGET = 3
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()

console.log(`\n[3] A: announce ${CHILD} on-chain so untrusted peers can discover it...`)
await A.announceChild({ nexusDir, child: CHILD, genesisHash: paymentsGenesisHash })

console.log(`\n[4] Boot B: peer A for Nexus ONLY (+ supervise children) — no child genesis/peer...`)
B.start(['--peer', A.peerArg(), '--supervise-children'])
await B.waitForRPC()
await waitFor(async () => (await peerCount(A)) >= 1 && (await peerCount(B)) >= 1,
  'Nexus peers connected', { timeoutMs: 15_000 })

console.log(`\n[5] B: DISCOVER + FOLLOW ${CHILD} (no genesis-hex / peer / subscribe supplied)...`)
const bPayments = await B.followChild({ nexusDir, child: CHILD, expectGenesis: paymentsGenesisHash })
console.log(`  B/${CHILD} joined permissionlessly, endpoint=${bPayments.endpoint}`)

console.log(`\n[6] Mine A until Nexus ≥ ${NEXUS_TARGET}, ${CHILD} ≥ ${CHILD_TARGET}, then freeze...`)
await waitFor(async () => {
  const [nxH, chH] = await Promise.all([A.height(nexusDir), aPayments.height(CHILD)])
  return nxH >= NEXUS_TARGET && chH >= CHILD_TARGET ? [nxH, chH] : null
}, `A heights Nexus ≥ ${NEXUS_TARGET}, ${CHILD} ≥ ${CHILD_TARGET}`, { timeoutMs: 120_000 })
await miner.stop()
await A.awaitQuiesced(nexusDir)
await aPayments.awaitQuiesced(CHILD)
await sleep(2000)

const minerAddr = computeAddress(aIdent.publicKey)
const aNxH = await A.height(nexusDir)
const aChH = await aPayments.height(CHILD)
console.log(`  A frozen: ${nexusDir}@${aNxH}, ${CHILD}@${aChH}`)

// Compare B against A's CURRENT (now-frozen) state each poll: the external miner can
// land an in-flight block or two after awaitQuiesced, so we chase A's actual final
// tip and require A itself stable across the poll (never compare a mid-flight A tip).
console.log(`\n[7] Wait for B to converge on Nexus tip AND the joined child's state...`)
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
    bPayments.height(),
    bPayments.tip(),
    bPayments.balance(minerAddr),
  ])
  return bNxTip === aNxTipNow &&
    bChH === aChHNow &&
    bChTip === aChTipNow &&
    bChildBalance === aChildBalNow ? true : null
}, 'B converged on Nexus tip and joined child state', { timeoutMs: 240_000 })

console.log(`✓ B converged: ${nexusDir}@${aNxH}, ${CHILD}@${aChH} (child joined permissionlessly)`)
console.log('✓ two-node sync smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
