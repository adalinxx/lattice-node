// Adversarial / Module 6: replay persisted router candidates on startup.
//
// A node that has learned useful peers must replay them on startup so an attacker
// cannot exploit a restart to wipe the peer view and re-seed a poisoned one before
// honest peers are rediscovered. Module 6 persists the validated connected set to
// peers.json (with a provenance `source` tag) and, on startup, replays those
// candidates through Ivy's normal admission + liveness path.
//
// This scenario verifies the REPLAY path end-to-end:
//   1. boots peer A (stays up the whole test — never disconnected),
//   2. seeds node B's peers.json with A's endpoint (exactly what a prior run's
//      runtime/shutdown persist would have written, including the `source` tag),
//   3. boots B with NO --peer argument (no configured bootstrap),
//   4. asserts B connects to A PURELY from the replayed candidate set.
//
// Why seed the file instead of doing a live stop/restart round-trip:
//   A graceful stop tears down the live connection, which trips the PRE-EXISTING
//   Swift task-allocator heap-corruption bug (project memory
//   "smoke-heap-corruption-preexisting") on BOTH the stopping node AND its peer —
//   so a real restart both fails to write peers.json and kills A before B can
//   reconnect. That teardown crash is out-of-scope Sources/ work. The PERSIST +
//   `source` half is covered deterministically by the PeerStoreSourceTests unit
//   test; this smoke covers the REPLAY half without provoking the teardown crash.
//
// Loopback note: netgroup/IPv6 diversity is not exercisable on 127.0.0.1 (covered
// by Ivy unit tests); this scenario is the node-observable replay behavior only.

import { mkdirSync, writeFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, waitFor, sleep, peerCount } from 'lattice-node-sdk'

const ROOT = smokeRoot('restart-persistence')
const [aPorts, bPorts] = await allocPorts(2, { seed: 60 })

console.log('=== router-candidate replay on startup ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'peerA', dir: `${ROOT}/peerA`, port: aPorts.port, rpcPort: aPorts.rpcPort }))
const B = net.add(new LatticeNode({ name: 'nodeB', dir: `${ROOT}/nodeB`, port: bPorts.port, rpcPort: bPorts.rpcPort }))

console.log('\n[1] Boot peer A (stays up for the whole test)...')
A.start()
await A.waitForRPC()
const aIdent = await A.readIdentity()
console.log(`  A pubkey: ${aIdent.publicKey.slice(0, 32)}... p2p port ${aPorts.port}`)

console.log("\n[2] Seed B's peers.json with A's endpoint (as a prior run would persist)...")
mkdirSync(B.dir, { recursive: true })
const persisted = [{ publicKey: aIdent.publicKey, host: '127.0.0.1', port: aPorts.port, source: 'discovered' }]
writeFileSync(`${B.dir}/peers.json`, JSON.stringify(persisted), 'utf8')

console.log('\n[3] Boot B with NO --peer (must rely on replay)...')
B.start()
await B.waitForRPC()

console.log('\n[4] Assert B connects to A purely from the replayed candidate set...')
await waitFor(async () => (await peerCount(B)) >= 1 ? true : null,
  'B connected to A via replay', { timeoutMs: 45_000, intervalMs: 1_000 })

const aAlive = A.proc && A.proc.exitCode === null && A.proc.signalCode === null
if (!aAlive) {
  console.error('  ✗ peer A died during the test')
  net.teardown()
  process.exit(1)
}

console.log('\n✓ B replayed the persisted candidate and connected to A with no configured bootstrap.')
net.teardown()
await sleep(500)
process.exit(0)
