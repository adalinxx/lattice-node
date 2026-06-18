// Adversarial: peer-admission key-work gate.
//
// The node admits a peer only if that peer's p2p identity key carries at least
// `--min-peer-key-bits` of proof-of-work (trailing-zero bits of the raw key under
// the Ivy identify gate). This raises the cost of Sybil / eclipse routing-table
// poisoning: an attacker cannot cheaply mint admissible identities, because each
// one costs a key grind.
//
// This scenario boots a VICTIM with a NONZERO min-peer-key-bits and an ATTACKER
// whose identity carries ~0 key-work bits (a random Ed25519/Curve25519 key almost
// never has trailing-zero bits), points the attacker at the victim via --peer,
// and asserts the attacker NEVER becomes a connected peer of the victim while the
// victim stays alive and serving RPC.
//
// ── What this asserts (the observable signal) ─────────────────────────────────
//   GET /api/peers (helper `peerCount`) returns the victim's CONNECTED peers
//   (Ivy `connectedPeerEndpoints`). A peer refused at the identify gate never
//   reaches that set, so the victim's connected-peer count must stay 0. We also
//   assert the VICTIM process stays alive throughout, so the test cannot pass by
//   the victim simply dying.
//
//   Positive control (manually verified, see commit message): two NORMAL nodes
//   (gate = 0) booted the same way peer successfully and both report peerCount==1
//   — so a count of 0 here is genuinely the gate refusing the low-work identity,
//   not a wiring failure that would keep ANY peer out.
//
// ── KNOWN LIMITATION / GAP (pre-existing, NOT introduced here) ────────────────
//   When the gate refuses a handshake, the refused-handshake teardown currently
//   trips the pre-existing Swift task-allocator heap-corruption bug
//   (`freed pointer was not the last allocation` / `swift_task_dealloc`; see the
//   project memory "smoke-heap-corruption-preexisting"). In the attacker-dials-
//   victim topology used here, the ATTACKER (the initiator running the rejected
//   handshake) is the side that crashes — within ~1s, before it can retry. The
//   VICTIM is unaffected and keeps serving. Consequently this scenario does NOT
//   assert attacker liveness, and the strength of the "stays 0" assertion is
//   bounded by the fact that the attacker crashes shortly after the first refused
//   dial. The victim-side invariant (never admits a low-work peer, stays alive)
//   is what is firmly asserted. Fixing the crash in the rejection path is
//   Sources/ work and out of scope for SmokeTests.
//
// ── Loopback constraint ───────────────────────────────────────────────────────
//   netgroup / IPv6-prefix diversity attacks cannot be exercised on 127.0.0.1
//   and are covered by Ivy unit tests, NOT here. This scenario covers only the
//   node-observable key-work admission gate.

import { readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, peerCount } from 'lattice-node-sdk'

const ROOT = smokeRoot('low-work-identity-rejected')
const [v, x] = await allocPorts(2, { seed: 96 })

// Small enough that the victim's one-time identity grind is sub-second, yet a
// random attacker key essentially never satisfies it (P(≥8 trailing-zero bits)
// of a random key ≈ 1/256).
const MIN_PEER_KEY_BITS = 8

console.log('=== low-work peer-identity rejection smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const VICTIM = net.add(new LatticeNode({ name: 'victim', dir: `${ROOT}/victim`, port: v.port, rpcPort: v.rpcPort }))
const ATTACKER = net.add(new LatticeNode({ name: 'attacker', dir: `${ROOT}/attacker`, port: x.port, rpcPort: x.rpcPort }))

console.log(`\n[1] Boot victim with --min-peer-key-bits ${MIN_PEER_KEY_BITS} (overrides harness default 0)...`)
// The victim's OWN identity must also satisfy the gate; the node detects the
// harness's ~0-bit seed identity and regrinds a compliant key on boot, writing a
// fresh identity.json. We re-read it below so victim.peerArg() is accurate.
VICTIM.start(['--min-peer-key-bits', String(MIN_PEER_KEY_BITS)])
await VICTIM.waitForRPC()
const victimIdent = JSON.parse(readFileSync(`${VICTIM.dir}/identity.json`, 'utf8'))
VICTIM._identity = victimIdent
console.log(`  victim pubkey: ${victimIdent.publicKey.slice(0, 32)}...`)

console.log(`\n[2] Boot attacker with a low-work (random ~0-bit) identity, pointed at victim...`)
// Attacker keeps the harness default --min-peer-key-bits 0, so it does NOT grind
// its own key — its identity carries ~0 trailing-zero bits and fails the victim's
// gate. It dials the victim via --peer.
ATTACKER.start(['--peer', VICTIM.peerArg()])
await ATTACKER.waitForRPC()
const attackerIdent = await ATTACKER.readIdentity()
console.log(`  attacker pubkey: ${attackerIdent.publicKey.slice(0, 32)}...`)

const victimAlive = () =>
  VICTIM.proc && VICTIM.proc.exitCode === null && VICTIM.proc.signalCode === null

console.log(`\n[3] Asserting the attacker NEVER becomes a connected peer of the victim...`)
// Poll for a generous window: a real connection (if the gate failed) would form
// within a few seconds; we keep checking that the victim's connected-peer count
// stays at the baseline 0 the whole time AND that the victim is still alive.
const POLL_MS = 20_000
const start = Date.now()
let maxObserved = 0
while (Date.now() - start < POLL_MS) {
  if (!victimAlive()) {
    console.error('  ✗ victim process died during the poll window')
    net.teardown()
    process.exit(1)
  }
  const vc = await peerCount(VICTIM)
  maxObserved = Math.max(maxObserved, vc)
  if (vc > 0) {
    console.error(`  ✗ victim has ${vc} connected peer(s); low-work attacker was admitted`)
    net.teardown()
    process.exit(1)
  }
  const elapsed = Math.round((Date.now() - start) / 1000)
  process.stdout.write(`\r  victim peers=${vc} victim-alive=${victimAlive()} (${elapsed}s)   `)
  await sleep(1000)
}

if (!victimAlive()) {
  console.error('\n  ✗ victim process died at end of poll window')
  net.teardown()
  process.exit(1)
}
console.log(`\n  ✓ victim alive and connected-peer count stayed at 0 for ${POLL_MS / 1000}s (max observed ${maxObserved})`)

console.log('\n✓ low-work peer-identity rejection smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
