// Multi-chain late joiner: A mines Nexus + 2 child chains beyond the headers-first
// catch-up threshold, then freezes. B joins LATE as an untrusted node — peered to A
// for Nexus only — DISCOVERS both children from its own synced GenesisState, follows
// each (no genesis-hex / peer / subscribe hand-off), self-resolves their genesis,
// finds A's child processes via getChildPeers, and must backfill + converge on all 3
// chains. Proves permissionless multi-child discovery + deep backfill.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('multichain-late-joiner')
const [a, b, alphaA, betaA] = await allocPorts(4, { seed: 93 })
const CHILD1 = 'Alpha'
const CHILD2 = 'Beta'
const TARGET = 6

console.log('=== multichain-late-joiner smoke test (permissionless multi-child join) ===')
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

// Deploy both child chains as separate processes (operator deploy).
const aAlpha = net.add(await A.spawnChild({ directory: CHILD1, parentDirectory: nexusDir, ports: alphaA, premine: 0 }))
const aBeta = net.add(await A.spawnChild({ directory: CHILD2, parentDirectory: nexusDir, ports: betaA, premine: 0 }))
const alphaGenesis = aAlpha._deployInfo.genesisHash
const betaGenesis = aBeta._deployInfo.genesisHash
console.log(`  A/${CHILD1} up  A/${CHILD2} up`)

const miner = net.addMiner(new LatticeMiner(A, [aAlpha, aBeta], { workers: 2 }))
await miner.start()

console.log('\n[2] A: announce BOTH children on-chain so untrusted peers can discover them...')
await A.announceChild({ nexusDir, child: CHILD1, genesisHash: alphaGenesis })
await A.announceChild({ nexusDir, child: CHILD2, genesisHash: betaGenesis })

await waitFor(async () => {
  const [nxH, a1H, a2H] = await Promise.all([
    A.height(nexusDir), aAlpha.height(CHILD1), aBeta.height(CHILD2)])
  process.stdout.write(`\r  A: Nexus@${nxH} ${CHILD1}@${a1H} ${CHILD2}@${a2H}   `)
  return nxH >= TARGET && a1H >= TARGET && a2H >= TARGET ? true : null
}, `A heights ≥ ${TARGET}`, { timeoutMs: 240_000, intervalMs: 1000 })

console.log('\n[3] Freeze A\'s tip...')
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

console.log('\n[4] Boot B (late joiner): peer A for Nexus ONLY + supervise children...')
B.start(['--peer', A.peerArg(), '--supervise-children'])
await B.waitForRPC()

console.log('\n[5] B: DISCOVER + FOLLOW both children (no genesis-hex / peer / subscribe)...')
const bAlpha = await B.followChild({ nexusDir, child: CHILD1, expectGenesis: alphaGenesis })
const bBeta = await B.followChild({ nexusDir, child: CHILD2, expectGenesis: betaGenesis })
console.log(`  B joined ${CHILD1} + ${CHILD2} permissionlessly`)

console.log('\n[6] Wait for B to backfill + converge on all 3 chains...')
const synced = await waitFor(async () => {
  const [aNxTip, bNxTip, aA1Tip, bA1Tip, aA2Tip, bA2Tip, bNxH, bA1H, bA2H] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir),
    aAlpha.tip(CHILD1), bAlpha.tip(),
    aBeta.tip(CHILD2), bBeta.tip(),
    B.height(nexusDir), bAlpha.height(), bBeta.height(),
  ])
  if (!bNxTip || bNxTip !== aNxTip) return null
  if (!bA1Tip || bA1Tip !== aA1Tip) return null
  if (!bA2Tip || bA2Tip !== aA2Tip) return null
  return { nexus: bNxH, alpha: bA1H, beta: bA2H }
}, 'B converged on all tips', { timeoutMs: 240_000, intervalMs: 2000 })

console.log(`  B synced: ${nexusDir}@${synced.nexus}, ${CHILD1}@${synced.alpha}, ${CHILD2}@${synced.beta}`)
console.log(`  ✓ B permissionlessly discovered + backfilled both child chains`)

console.log('\n✓ multichain-late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
