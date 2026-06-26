// Deep self-similar permissionless join: Nexus → Mid → Stable (depth 3).
//
// A deploys + ANNOUNCES a 3-deep chain and merge-mines all three. B boots a SINGLE
// node with --supervise-children and NOTHING ELSE — no genesis hex, no peer beyond
// A's Nexus, no per-level wiring. The whole subtree then SELF-ASSEMBLES:
//   B (own chain Nexus) auto-follows Mid → spawns a supervised Mid →
//   that Mid (own chain Mid) auto-follows Stable → spawns a supervised Stable.
// No chain is special: every node runs the identical discover→follow→sync→discover
// loop for its own children. B must converge on all three tips.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('parent-dependency')
const [a, mid, stable, b] = await allocPorts(4)
const TARGET = 5

console.log('=== parent-dependency: deep self-assembling permissionless join (Nexus→Mid→Stable) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))

console.log('\n[1] A: boot Nexus, deep-deploy Mid (on Nexus) + Stable (on Mid)...')
A.start()
await A.waitForRPC()
await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus

const aMid = net.add(await A.spawnChild({ directory: 'Mid', parentDirectory: nexusDir, ports: mid, premine: 0 }))
await aMid.waitForRPC()
await aMid.readIdentity()
const aStable = net.add(await aMid.spawnChild({ directory: 'Stable', parentDirectory: 'Mid', ports: stable, premine: 0 }))
await aStable.waitForRPC()
const midGenesis = aMid._deployInfo.genesisHash
const stableGenesis = aStable._deployInfo.genesisHash
console.log(`  A/Mid + A/Stable up`)

const miner = net.addMiner(new LatticeMiner(A, [aMid, aStable], { workers: 2 }))
await miner.start()

console.log('\n[2] A: announce each level in its PARENT\'s GenesisState (Mid on Nexus, Stable on Mid)...')
await A.announceChild({ nexusDir, child: 'Mid', genesisHash: midGenesis })
await aMid.announceChild({ nexusDir: 'Mid', child: 'Stable', genesisHash: stableGenesis })

await waitFor(async () => {
  const [nh, mh, sh] = await Promise.all([A.height(nexusDir), aMid.height('Mid'), aStable.height('Stable')])
  process.stdout.write(`\r  A: Nexus@${nh} Mid@${mh} Stable@${sh}   `)
  return nh >= TARGET && mh >= TARGET && sh >= TARGET ? true : null
}, `A all three ≥ ${TARGET}`, { timeoutMs: 360_000, intervalMs: 1000 })
await miner.stop()
await Promise.all([
  A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 }),
  aMid.awaitQuiesced('Mid', { timeoutMs: 30_000, idleMs: 6_000 }),
  aStable.awaitQuiesced('Stable', { timeoutMs: 30_000, idleMs: 6_000 }),
])
console.log(`\n  A frozen: Nexus@${await A.height(nexusDir)} Mid@${await aMid.height('Mid')} Stable@${await aStable.height('Stable')}`)

console.log('\n[3] B: boot ONE node — peer A for Nexus + supervise children. Nothing else.')
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))
// Fast reconcile sweep so the 3-level cascade (each level follows its children one
// sweep after syncing) converges quickly; inherited by every spawned descendant.
B.start(['--peer', A.peerArg(), '--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC()

// Walk B's self-assembled tree level by level: each node registers its DIRECT children
// in its OWN chain/map (B has Nexus/Mid; that Mid has Nexus/Mid/Stable). Self-similar.
async function resolveLeaf(rootBase, fullPath) {
  let base = `${rootBase}/api`
  for (let depth = 2; depth <= fullPath.length; depth++) {
    const key = fullPath.slice(0, depth).join('/')
    const ep = await waitFor(async () => {
      const m = await fetch(`${base}/chain/map`).then((x) => x.json()).catch(() => null)
      return m?.[key] ?? null
    }, `endpoint registered for ${key}`, { timeoutMs: 180_000, intervalMs: 3000 })
    base = ep  // descend into the just-registered child to find the next level
  }
  return base
}

console.log('\n[4] Wait for B to self-assemble Nexus→Mid→Stable + converge on all tips...')
const stablePath = [nexusDir, 'Mid', 'Stable']
const midPath = [nexusDir, 'Mid']
const bMidEp = await resolveLeaf(B.base, midPath)
console.log(`  ✓ B auto-followed Mid → ${bMidEp}`)
const bStableEp = await resolveLeaf(B.base, stablePath)
console.log(`  ✓ B's Mid auto-followed Stable → ${bStableEp}`)

const heightTipAt = async (endpoint, directory) => {
  const i = await fetch(`${endpoint}/chain/info`).then((x) => x.json()).catch(() => null)
  const c = i?.chains?.find((x) => x.directory === directory)
  return { height: c?.height ?? 0, tip: c?.tip ?? '' }
}

await waitFor(async () => {
  const [aN, aM, aS] = await Promise.all([A.tip(nexusDir), aMid.tip('Mid'), aStable.tip('Stable')])
  const [bN, bM, bS] = await Promise.all([
    B.tip(nexusDir),
    heightTipAt(bMidEp, 'Mid').then((x) => x.tip),
    heightTipAt(bStableEp, 'Stable').then((x) => x.tip),
  ])
  return bN === aN && bM && bM === aM && bS && bS === aS ? true : null
}, 'B converged on all 3 tips', { timeoutMs: 360_000, intervalMs: 2000 })

const bSH = (await heightTipAt(bStableEp, 'Stable')).height
console.log(`\n  ✓ B self-assembled + converged: Nexus + Mid + Stable all match A (Stable@${bSH})`)
console.log('✓ parent-dependency deep self-assembly test passed.')
net.teardown()
await sleep(500)
process.exit(0)
