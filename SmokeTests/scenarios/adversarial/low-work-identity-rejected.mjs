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
//   GET /api/peers (helper `peers`) lists the victim's connections as
//   { publicKey, host, port }. A peer that DIALS in is briefly held under a
//   temporary `inbound-<uuid>` id (endpoint host "unknown", port 0) for the
//   duration of the identify handshake — BEFORE the key-work gate runs. So the
//   raw peer COUNT can transiently be 1 even for a peer that is about to be
//   refused; that count is a measurement artifact, not an admission. Admission is
//   therefore measured by IDENTITY, not count: a connection is re-keyed off the
//   `inbound-*` placeholder to the peer's REAL public key only after identify
//   clears the gate (Ivy `didIdentifyPeer`), which a ~0-bit key never does. We
//   assert that no peer carrying a real (non-`inbound-*`) identity — in this
//   topology, only the attacker — ever appears, while the VICTIM stays alive and
//   serving RPC (so the test cannot pass by the victim simply dying).
//
//   Positive control (manually verified, see commit message): two NORMAL nodes
//   (gate = 0) booted the same way peer successfully and each lists the other's
//   real public key — so the attacker's identity NOT appearing here is genuinely
//   the gate refusing the low-work key, not a wiring failure that keeps ANY peer
//   out.
//
// ── KNOWN LIMITATION / GAP (pre-existing, NOT introduced here) ────────────────
//   When the gate refuses a handshake, the refused-handshake teardown currently
//   trips the pre-existing Swift task-allocator heap-corruption bug
//   (`freed pointer was not the last allocation` / `swift_task_dealloc`; see the
//   project memory "smoke-heap-corruption-preexisting"). In the attacker-dials-
//   victim topology used here, the ATTACKER (the initiator running the rejected
//   handshake) is the side that crashes — within ~1s, before it can retry. The
//   VICTIM is unaffected and keeps serving, which is the invariant asserted here.
//   Consequently this scenario does NOT assert attacker liveness. The victim-side
//   invariant (never admits a low-work identity, stays alive) is what is firmly
//   asserted. Fixing the crash in the rejection path is Sources/ work and out of
//   scope for SmokeTests.
//
// ── Loopback constraint ───────────────────────────────────────────────────────
//   netgroup / IPv6-prefix diversity attacks cannot be exercised on 127.0.0.1
//   and are covered by Ivy unit tests, NOT here. This scenario covers only the
//   node-observable key-work admission gate.

import { readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, peers } from 'lattice-node-sdk'

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

const attackerKeyPrefix = attackerIdent.publicKey.slice(0, 16)

console.log(`\n[3] Asserting the attacker's IDENTITY never joins the victim's peer set...`)
// Poll for a generous window: a real admission (if the gate failed) would form
// within a few seconds and persist. We tolerate a transient `inbound-*`
// placeholder (a peer mid-identify, before the gate runs) and fail only if a
// peer carrying a REAL identity appears — i.e. one re-keyed off the placeholder,
// which only happens after identify clears the key-work gate. We also require the
// victim to stay alive throughout so the test cannot pass by the victim dying.
const POLL_MS = 20_000
const start = Date.now()
let sawTransient = false
while (Date.now() - start < POLL_MS) {
  if (!victimAlive()) {
    console.error('\n  ✗ victim process died during the poll window')
    net.teardown()
    process.exit(1)
  }
  const vps = await peers(VICTIM)
  // A genuinely admitted peer is identified: its connection is keyed to a real
  // public key, NOT the `inbound-<uuid>` placeholder held during the handshake.
  const admitted = vps.find((p) => !p.publicKey.startsWith('inbound-'))
  if (admitted) {
    const matches = admitted.publicKey.startsWith(attackerKeyPrefix) ? ' (matches attacker)' : ''
    console.error(`\n  ✗ low-work identity admitted as a peer: ${admitted.publicKey} @ ${admitted.host}:${admitted.port}${matches}`)
    net.teardown()
    process.exit(1)
  }
  if (vps.length > 0) sawTransient = true
  const elapsed = Math.round((Date.now() - start) / 1000)
  process.stdout.write(`\r  victim peers=${vps.length} (admitted=0) victim-alive=${victimAlive()} (${elapsed}s)   `)
  await sleep(1000)
}

if (!victimAlive()) {
  console.error('\n  ✗ victim process died at end of poll window')
  net.teardown()
  process.exit(1)
}
console.log(`\n  ✓ victim alive; attacker identity never entered the peer set over ${POLL_MS / 1000}s (transient pre-identify dial observed: ${sawTransient})`)

console.log('\n✓ low-work peer-identity rejection smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
