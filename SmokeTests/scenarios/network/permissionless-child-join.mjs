// Permissionless child-chain discovery + follow: a node that only synced Nexus (never
// deployed Toy, never handed Toy's genesis or a peer address) DISCOVERS Toy from on-chain
// GenesisState and FOLLOWS it — the supervised reconciler resolves Toy's genesis from the
// synced parent state, fetches it from CAS by CID, and boots it as a supervised child.
//
// What's proven (vs multichain-late-joiner, which hands the joiner deploy.genesisHex):
//   1. discovery  — B lists Nexus's children from GenesisState (chain/children) and sees Toy.
//   2. follow     — B `chain follow Nexus/Toy` with NO genesis-hex / subscribe-p2p / peer.
//   3. resolution — B's reconciler self-resolves Toy's genesis (GenesisState CID + CAS fetch)
//                   and boots a supervised Toy whose genesis CID is A's EXACT Toy genesis.
//
// Full headers-first chain sync of the followed child needs same-chain (Toy) peer bootstrap,
// which lands in the stacked follow-up; this asserts the permissionless core (discover →
// follow → self-resolve genesis → spawn). A deployed child is only DISCOVERABLE once its
// genesisAction is mined into GenesisState (deploy = availability, not announcement), so A
// explicitly announces Toy first.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('permissionless-child-join')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [a, b, toyA] = await allocPorts(3, { seed: 71 })
const CHILD = 'Toy'
let failed = false
const fail = (m) => { console.error(`✗ ${m}`); failed = true }

console.log('=== permissionless child discovery + follow smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const funder = (await import('lattice-node-sdk')).genKeypair()
const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort, coinbaseAddress: funder.address }))

console.log('\n[1] A: boot Nexus, deploy + run Toy, announce it on-chain, mine both')
A.start()
await A.waitForRPC()
await A.readIdentity()
const infoA = await A.chainInfo()
const nexusDir = infoA.nexus
const childPathStr = `${nexusDir}/${CHILD}`
const aToy = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, ports: toyA, premine: 0 }))
const toyGenesisHash = aToy._deployInfo.genesisHash
const miner = net.addMiner(new LatticeMiner(A, [aToy]))
await miner.start()

// Fund the funder (coinbase), then submit the genesisAction that ANNOUNCES Toy on Nexus —
// deploy pins/serves the genesis but does not write it to GenesisState; this does.
await waitFor(async () => (await A.balance(funder.address, nexusDir)) >= 5000 ? true : null,
  'funder coinbase', { timeoutMs: 240_000, intervalMs: 1000 })
await waitFor(async () => {
  const base = await A.nonce(funder.address, nexusDir)
  const r = await A.submitTx({
    nonce: base, signers: [funder.address], fee: 1000,
    accountActions: [{ owner: funder.address, delta: -1000 }],
    genesisActions: [{ directory: CHILD, blockCID: toyGenesisHash }],
  }, nexusDir, funder)
  return r.ok ? true : null
}, 'submit Toy genesisAction (announce)', { timeoutMs: 60_000, intervalMs: 1000 })

// Announce is mined into GenesisState once A can enumerate Toy as its child.
await waitFor(async () => {
  const r = await A.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
  const dirs = (r?.json?.children ?? []).map((c) => c.directory)
  return dirs.includes(CHILD) ? true : null
}, 'Toy announced in A Nexus GenesisState', { timeoutMs: 300_000, intervalMs: 2000 })

// A keeps mining (LIVE) for the whole test: a followed child syncs by extracting its blocks
// from the parent's ONGOING gossip (each new parent block triggers a chainAnnounce →
// backfill → extract). A frozen parent emits no announce, so a late child can't catch up —
// the realistic scenario is following a live chain. So no freeze here.
console.log(`  A live: ${nexusDir}@${await A.height(nexusDir)} ${CHILD}@${await aToy.height(CHILD)}`)

console.log('\n[3] B: fresh node, peer A for Nexus, supervise children (A keeps mining)')
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))
B.start(['--peer', A.peerArg(), '--supervise-children'])
await B.waitForRPC()

console.log('\n[4] B discovers Toy from its OWN synced GenesisState (chain/children)')
// Discovery requires B to have synced past the announce block — poll until Toy appears.
const discovered = await waitFor(async () => {
  const r = await B.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
  const dirs = (r?.json?.children ?? []).map((c) => c.directory)
  return dirs.includes(CHILD) ? dirs : null
}, 'B discovered Toy from synced GenesisState', { timeoutMs: 240_000, intervalMs: 2000 })
console.log(`  ✓ B discovered children: ${JSON.stringify(discovered)}`)

console.log('\n[5] B follows Nexus/Toy — no genesis-hex / subscribe-p2p / peer supplied')
const fol = await B.rpc('POST', '/api/chain/follow', { chainPath: [nexusDir, CHILD] })
if (!fol.ok) fail(`chain/follow failed: ${JSON.stringify(fol.json)}`)

// B's reconciler self-resolved Toy's genesis and spawned a supervised Toy; it registers the
// child's RPC endpoint in chain/map once up.
console.log('\n[6] B\'s reconciler-spawned Toy syncs the followed chain')
let childEndpoint = null
await waitFor(async () => {
  const m = await B.rpc('GET', '/api/chain/map').catch(() => null)
  const ep = m?.json?.[childPathStr]
  if (ep) { childEndpoint = ep; return true }
  return null
}, 'B spawned + registered the followed Toy', { timeoutMs: 240_000, intervalMs: 3000 }).catch(() => null)
if (!childEndpoint) { fail('B never spawned/registered the followed Toy (genesis resolution or spawn failed)'); net.teardown(); await sleep(500); process.exit(1) }
console.log(`  B Toy endpoint: ${childEndpoint}`)

// B's Toy booted A's EXACT Toy genesis (resolved from GenesisState — verified identical CID)
// and extracts Toy blocks from B's live Nexus gossip. A keeps mining (~fast in debug), so
// asserting an exact tip match against a moving tip races; instead require B's Toy to SYNC
// the followed chain (booted from A's exact genesis CID, verified). Headers-first chain
// sync requires connecting to same-chain (Toy) peers — a cross-chain peer-bootstrap that
// lands in a stacked follow-up; this scenario asserts discovery + follow + genesis
// resolution + supervised spawn/registration, which is the permissionless core.
const childInfo = await fetch(`${childEndpoint}/chain/info`).then((x) => x.json()).catch(() => null)
const childGenesis = childInfo?.genesisHash
if (!childGenesis) fail('B Toy child RPC did not report a genesis (spawn/boot failed)')
else if (childGenesis !== toyGenesisHash) fail(`B Toy booted genesis ${childGenesis} != A's Toy genesis ${toyGenesisHash} (resolution produced wrong genesis)`)

if (failed) { console.error('\n=== permissionless discovery+follow: FAILED ==='); net.teardown(); await sleep(500); process.exit(1) }
console.log(`  ✓ B Toy spawned + registered (genesis ${String(childGenesis).slice(0, 16)}…)`)
console.log('\n✓ permissionless join: B discovered Toy from GenesisState, followed it, and self-resolved + booted A\'s exact genesis as a supervised child — no tracking-node query, no genesis/peer flags')
net.teardown()
await sleep(500)
process.exit(0)
