// Stateless-follower: realistic per-process child chain subscription.
//
// Real-world flow:
//   1. Entity A deploys a child chain — this creates a genesis block whose hash
//      is committed to a Nexus block via a genesis transaction.
//   2. A mines Nexus until the genesis transaction confirms on-chain.
//   3. B syncs Nexus from A. B now has the genesis transaction in its chain.
//   4. B fetches the genesis hex from A (the deploying node) — this is how any
//      new participant learns the genesis: by querying a node that already has
//      the on-chain deployment, NOT by receiving it out-of-band.
//   5. B starts its own per-process child node using that genesis hex.
//   6. B-stateless follows both Nexus and Payments to full height.
//
// Asserts:
//   - B converges on both tips
//   - B stays under the disk budget (stateless mode leaks nothing)

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, dirSizeBytes } from 'lattice-node-sdk'

const ROOT = smokeRoot('stateless-follower')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [a, b, childA, childB] = await allocPorts(4)
const CHILD = 'Payments'
const TARGET_HEIGHT = 24
const DISK_BUDGET_MB = 10

console.log('=== stateless-follower smoke (deep parent history; B follows with no disk) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

// ── [1] A deploys Payments ───────────────────────────────────────────────────

console.log('\n[1] Boot A, deploy Payments child chain...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
await A.readIdentity()

// Deploy creates the genesis block and submits it to Nexus.
// spawnChild starts the per-process child node for A.
const aPayments = net.add(await A.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childA,
  premine: 0,
}))
await aPayments.waitForRPC()
console.log('  A/Payments process up')

// ── [2] Mine to confirm genesis on-chain, then continue to TARGET_HEIGHT ─────

console.log(`\n[2] Mine to confirm genesis on-chain, then to height ≥ ${TARGET_HEIGHT}...`)
const miner = net.addMiner(new LatticeMiner(A, [aPayments], { workers: 2 }))
await miner.start()

// Wait for the genesis to be confirmed: Payments must have at least 1 block,
// meaning the genesis transaction is now committed to a Nexus block.
await waitFor(async () => {
  const chH = await aPayments.height(CHILD)
  return chH >= 1 ? chH : null
}, 'Payments genesis confirmed on-chain', { timeoutMs: 60_000, intervalMs: 500 })
console.log('  ✓ genesis confirmed in Nexus block — child chain exists on-chain')

// Now mine to full target height.
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
const aNexusP2P = (await A.chainInfo()).p2pAddress
console.log(`\n  A frozen: ${nexusDir}@${aNxH} ${CHILD}@${aChH}`)

// ── [3] B syncs Nexus from A ─────────────────────────────────────────────────

console.log('\n[3] Boot B stateless, sync Nexus from A...')
B.start(['--peer', A.peerArg(), '--stateless'])
await B.waitForRPC()

// B syncs Nexus. Once B has the genesis transaction block, B knows Payments
// exists and can derive the genesis hash.
const bNexus = await waitFor(async () => {
  const [aTip, bTip, bHeight] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir), B.height(nexusDir),
  ])
  return bTip && bTip === aTip ? { height: bHeight, tip: bTip } : null
}, 'B synced Nexus to A tip', { timeoutMs: 120_000, intervalMs: 1000 })
console.log(`  ✓ B Nexus converged at height ${bNexus.height} — B now has the Payments genesis on-chain`)

// ── [4] B fetches genesis hex from A (discovered via on-chain data) ───────────

console.log('\n[4] B fetches Payments genesis hex from A (on-chain discovery)...')
// B calls A's genesis endpoint — this is the realistic path: any participant
// can query a node that already has the deployment to get the genesis hex.
// A serves this because the genesis block is part of A's on-chain state.
const genesisR = await A.rpc('GET', `/api/chain/genesis?chainPath=${encodeURIComponent(`${nexusDir}/${CHILD}`)}`)
if (!genesisR.ok || !genesisR.json?.genesisHex) {
  throw new Error(`Failed to fetch genesis hex from A: ${JSON.stringify(genesisR.json)}`)
}
const genesisHex = genesisR.json.genesisHex
// chainP2PAddress is the deploying node's chain port — the initial bootstrap peer.
// This is included in the genesis response so subscribers have a peer at startup,
// without needing runtime DHT discovery or out-of-band address passing.
const chainP2PAddress = genesisR.json.chainP2PAddress
console.log(`  ✓ genesis hex obtained (${genesisHex.length / 2} bytes), bootstrap peer: ${chainP2PAddress ?? 'none'}`)

// ── [5] B starts its own Payments child process ──────────────────────────────

console.log('\n[5] B starts per-process Payments node (stateless)...')
const bPayments = net.add(new LatticeNode({
  name: `B-${CHILD}`,
  dir: `${ROOT}/B-${CHILD}`,
  port: childB.port,
  rpcPort: childB.rpcPort,
}))
// Bootstrap peer comes from the genesis response (the deploying node's chain port).
// This is the realistic flow: fetch genesis → get genesis hex AND the initial peer,
// then start the child process with both. No runtime discovery needed.
bPayments.start([
  '--genesis-hex', genesisHex,
  '--chain-directory', CHILD,
  '--chain-path', `${nexusDir}/${CHILD}`,
  '--subscribe-p2p', aNexusP2P,
  ...(chainP2PAddress ? ['--peer', chainP2PAddress] : []),
  '--stateless',
])
await bPayments.waitForRPC()
console.log(`  ✓ B/${CHILD} process up (stateless)`)

// ── [6] B converges on both chains ───────────────────────────────────────────

console.log(`\n[6] Waiting for B to converge on both chains...`)
const bConverged = await waitFor(async () => {
  const [aNxTip, bNxTip, aChTip, bChTip, bNxH, bChH] = await Promise.all([
    A.tip(nexusDir), B.tip(nexusDir),
    aPayments.tip(CHILD), bPayments.tip(CHILD),
    B.height(nexusDir), bPayments.height(CHILD),
  ])
  if (!bNxTip || bNxTip !== aNxTip) return null
  if (!bChTip || bChTip !== aChTip) return null
  return { nexus: bNxH, child: bChH }
}, 'B converged on both tips', { timeoutMs: 180_000, intervalMs: 1000 })

// ── [7] Check disk budget ─────────────────────────────────────────────────────

await B.stop()
await bPayments.stop()
await sleep(1500)

const bNexusSize = dirSizeBytes(B.dir)
const bChildSize = dirSizeBytes(bPayments.dir)
const bTotalSize = bNexusSize + bChildSize
const bSizeMB = (bTotalSize / (1024 * 1024)).toFixed(2)
console.log(`\n[7] B data-dir total size: ${bSizeMB} MB (budget ${DISK_BUDGET_MB} MB)`)
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
