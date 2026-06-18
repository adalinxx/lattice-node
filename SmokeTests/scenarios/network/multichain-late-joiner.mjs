// Multi-chain late joiner: A mines Nexus + 2 child chains beyond the
// headers-first catch-up threshold.
// B joins fresh, subscribes to both children, and must discover + sync
// all 3 chains. Follows the same frozen-tip pattern as late-joiner.mjs.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('multichain-late-joiner')
const [a, b, alphaA, betaA, alphaB, betaB] = await allocPorts(6, { seed: 93 })
const CHILD1 = 'Alpha'
const CHILD2 = 'Beta'
const TARGET = 6

console.log('=== multichain-late-joiner smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

console.log('\n[1] Boot A, deploy 2 child chains, mine to depth...')
A.start()
await A.waitForRPC()
await A.readIdentity()

const infoA = await A.chainInfo()
const nexusDir = infoA.nexus
const aNexusP2P = infoA.p2pAddress

// Deploy both child chains as separate processes.
const aAlpha = net.add(await A.spawnChild({
  directory: CHILD1,
  parentDirectory: nexusDir,
  ports: alphaA,
  premine: 0,
}))
const alphaDeploy = aAlpha._deployInfo

const aBeta = net.add(await A.spawnChild({
  directory: CHILD2,
  parentDirectory: nexusDir,
  ports: betaA,
  premine: 0,
}))
const betaDeploy = aBeta._deployInfo

console.log(`  A/${CHILD1} up  A/${CHILD2} up`)

const miner = net.addMiner(new LatticeMiner(A, [aAlpha, aBeta], { workers: 2 }))
await miner.start()

await waitFor(async () => {
  const [nxH, a1H, a2H] = await Promise.all([
    A.height(nexusDir), aAlpha.height(CHILD1), aBeta.height(CHILD2)])
  process.stdout.write(`\r  A: Nexus@${nxH} ${CHILD1}@${a1H} ${CHILD2}@${a2H}   `)
  return nxH >= TARGET && a1H >= TARGET && a2H >= TARGET ? true : null
}, `A heights ≥ ${TARGET}`, { timeoutMs: 240_000, intervalMs: 1000 })

console.log('\n[2] Freeze A\'s tip...')
await miner.stop()
await Promise.all([
  A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 }),
  aAlpha.awaitQuiesced(CHILD1, { timeoutMs: 30_000, idleMs: 6_000 }),
  aBeta.awaitQuiesced(CHILD2, { timeoutMs: 30_000, idleMs: 6_000 }),
])

const aNxH = await A.height(nexusDir)
const aA1H = await aAlpha.height(CHILD1)
const aA2H = await aBeta.height(CHILD2)
console.log(`  A frozen: ${nexusDir}@${aNxH}, ${CHILD1}@${aA1H}, ${CHILD2}@${aA2H}`)

console.log('\n[3] Boot B\'s nexus + 2 child processes (late joiner)...')
B.start([
  '--peer', A.peerArg(),
])
await B.waitForRPC()

// B's child processes use A's genesis hexes to share the same chains.
const bAlpha = net.add(new LatticeNode({
  name: `B-${CHILD1}`,
  dir: `${ROOT}/B-${CHILD1}`,
  port: alphaB.port,
  rpcPort: alphaB.rpcPort,
}))
bAlpha.start([
  '--genesis-hex', alphaDeploy.genesisHex,
  '--chain-directory', CHILD1,
  '--chain-path', `${nexusDir}/${CHILD1}`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', aAlpha.peerArg(),   // peer with A-Alpha process directly for history
])
await bAlpha.waitForRPC()

const bBeta = net.add(new LatticeNode({
  name: `B-${CHILD2}`,
  dir: `${ROOT}/B-${CHILD2}`,
  port: betaB.port,
  rpcPort: betaB.rpcPort,
}))
bBeta.start([
  '--genesis-hex', betaDeploy.genesisHex,
  '--chain-directory', CHILD2,
  '--chain-path', `${nexusDir}/${CHILD2}`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', aBeta.peerArg(),   // peer with A-Beta process directly for history
])
await bBeta.waitForRPC()
console.log(`  B nexus + B/${CHILD1} + B/${CHILD2} up`)

console.log('\n[4] Wait for B to sync all chains...')
const synced = await waitFor(async () => {
  const [aNxTip, bNxTip, aA1Tip, bA1Tip, aA2Tip, bA2Tip, bNxH, bA1H, bA2H] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir),
    aAlpha.tip(CHILD1), bAlpha.tip(CHILD1),
    aBeta.tip(CHILD2), bBeta.tip(CHILD2),
    B.height(nexusDir), bAlpha.height(CHILD1), bBeta.height(CHILD2),
  ])
  if (!bNxTip || bNxTip !== aNxTip) return null
  if (!bA1Tip || bA1Tip !== aA1Tip) return null
  if (!bA2Tip || bA2Tip !== aA2Tip) return null
  return { nexus: bNxH, alpha: bA1H, beta: bA2H }
}, 'B converged on all tips', { timeoutMs: 240_000, intervalMs: 2000 })

console.log(`  B synced: ${nexusDir}@${synced.nexus}, ${CHILD1}@${synced.alpha}, ${CHILD2}@${synced.beta}`)
console.log(`  ✓ B discovered and synced both child chains`)

console.log('\n✓ multichain-late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
