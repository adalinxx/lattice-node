// I3 NEGATIVE: a peer relaying a transaction that the receiver
// rejects for a NON-consensus reason must NOT be penalized or source-excluded.
//
// The validation-result taxonomy (I3) fires a peer penalty ONLY on
// `.rejected(consensusInvalid: true)`; policy / transient / missing-input
// rejections must never penalize the relaying peer. Before the fix
// ANY mempool rejection was mapped to a flood-ban / source-exclusion, so a peer
// relaying a merely-low-fee tx got excluded and its later VALID txs were dropped.
//
// Setup: A (miner, high node-local `--min-fee-rate`) <-> B (`--min-fee-rate 0`).
//   1. B accepts low-fee txs (above B's zero floor) and gossips them to A.
//   2. A rejects each "Fee below rate floor" -> classified .policy ->
//      consensusInvalid:false -> NO penalty, NO source-exclusion.
//   3. DIFFERENTIATOR: a subsequent HIGH-fee tx from B is still accepted and
//      mined by A. If the low-fee gossip had excluded/banned B (the regression),
//      this valid tx would be dropped and the recipient never funded.
//
// Consensus-neutral: min-fee-rate is a node-local RELAY policy, not a chain rule.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { computeAddress, genKeypair } from 'lattice-node-sdk/wallet'
import { submitTx } from 'lattice-node-sdk/tx'
import { peerCount } from 'lattice-node-sdk/probe'
import { chainInfo, getNonce, getBalance, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('relay-rejection-no-penalty')
const [a, b] = await allocPorts(2, { seed: 261 })

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('=== relay-rejection-no-penalty smoke test (I3 negative) ===')

// A enforces a high node-local relay floor; B enforces none.
A.start({ extraArgs: ['--min-fee-rate', '1000'] })
await A.waitForRPC()
const aIdent = await A.readIdentity()
const minerKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const minerAddr = computeAddress(aIdent.publicKey)

B.start({ peers: [A], extraArgs: ['--min-fee-rate', '0'] })
await B.waitForRPC()
const bIdent = await B.readIdentity()
const bPubPrefix = bIdent.publicKey.slice(0, 16)

const info = await chainInfo(A)
const nexus = info.nexus

console.log('\n[1] Connect peers, mine coinbase, and fund a user account via A...')
await waitFor(async () => (await peerCount(A)) >= 1 && (await peerCount(B)) >= 1,
  'A<->B connected', { timeoutMs: 20_000 })
await startMining(A, nexus)
// Mine enough coinbase (reward 1_048_576/block) that the user fund + fees are
// comfortably affordable.
await waitForHeight(A, nexus, 8, 90_000)

// Fund a fresh USER from coinbase. The user's nonce is deterministic (0, only
// advances with its own txs), so both A and B agree on it after B syncs — unlike
// minerAddr whose nonce advances with every coinbase block. The funding tx fee
// must clear A's own min-fee-rate floor (1000 * bodyBytes), so use 1_000_000.
const user = genKeypair()
const FUND = 6_000_000
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)
const mNonce = await getNonce(A, minerAddr, nexus)
const fundRes = await submitTx(A, {
  chainPath: [nexus], nonce: mNonce, signers: [minerAddr], fee: 1_000_000,
  accountActions: [{ owner: minerAddr, delta: -(FUND + 1_000_000) }, { owner: user.address, delta: FUND }],
}, nexus, minerKP)
if (!fundRes.ok) throw new Error(`fund user failed: ${JSON.stringify(fundRes.submit)}`)
await startMining(A, nexus)
await waitFor(async () => (await getBalance(A, user.address, nexus)) >= FUND, 'user funded on A', { timeoutMs: 45_000 })
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)
// B must sync the funding block so it sees the user's balance + nonce floor.
await waitFor(async () => (await getBalance(B, user.address, nexus)) >= FUND, 'user funding visible on B', { timeoutMs: 60_000 })
console.log(`  user funded (${FUND}); visible on both A and B`)
await startMining(A, nexus)

const recipient = genKeypair()
const DELTA = 1000

// The user's next nonce is 0 (funded TO it; no txs FROM it yet) on both nodes.
async function relayViaB(fee) {
  return await submitTx(B, {
    chainPath: [nexus], nonce: 0, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -(DELTA + fee) }, { owner: recipient.address, delta: DELTA }],
  }, nexus, user)
}

console.log('\n[2] B relays low-fee txs (RBF same nonce); A must reject (policy) without penalizing B...')
// All fees are far below A's floor (1000 * bodyBytes >> 1e3) but above B's zero
// floor, and form a valid ascending RBF chain on B.
for (const fee of [1, 100, 1000]) {
  const r = await relayViaB(fee)
  if (!r.ok) throw new Error(`B rejected its own low-fee relay (fee=${fee}): ${JSON.stringify(r.submit)}`)
  console.log(`  ✓ B accepted+gossiped low-fee tx (fee=${fee})`)
}
// Give gossip + A's admission/rejection time to run.
await sleep(3000)

console.log('\n[3] Assert A did NOT penalize/exclude B and the chain still advances...')
const aHeightMid = (await chainInfo(A)).chains.find((c) => c.directory === nexus)?.height ?? 0
await waitFor(async () => (await peerCount(A)) >= 1,
  'A still has B as a peer after low-fee relays', { timeoutMs: 15_000 })
const aPeers = await A.rpc('GET', `/api/peers?chainPath=${nexus}`)
const stillPeered = aPeers.ok && (aPeers.json?.peers ?? []).some((p) => (p.publicKey ?? '').startsWith(bPubPrefix))
console.log(`  A peers count=${aPeers.json?.count}; B present=${stillPeered}`)
// The low-fee txs must NOT have been mined by A (A rejected them at admission).
const recBalAfterLow = await getBalance(A, recipient.address, nexus)
if (recBalAfterLow !== 0) throw new Error(`expected recipient unfunded after low-fee relays, got ${recBalAfterLow}`)
console.log('  ✓ low-fee txs were rejected by A (recipient still unfunded)')

console.log('\n[4] DIFFERENTIATOR: B relays a HIGH-fee valid tx; A must still accept + mine it...')
const HIGH_FEE = 1_000_000
const hr = await relayViaB(HIGH_FEE)
if (!hr.ok) throw new Error(`B rejected the high-fee relay: ${JSON.stringify(hr.submit)}`)
console.log(`  ✓ B accepted+gossiped high-fee tx (fee=${HIGH_FEE})`)
await waitFor(async () => (await getBalance(A, recipient.address, nexus)) >= DELTA,
  'A mined the high-fee tx relayed by B (B was never source-excluded)', { timeoutMs: 60_000 })

// A advanced and B is still a usable data source — the policy rejections never
// banned it.
const aHeightEnd = (await chainInfo(A)).chains.find((c) => c.directory === nexus)?.height ?? 0
if (aHeightEnd <= aHeightMid) throw new Error(`A chain did not advance (${aHeightMid} -> ${aHeightEnd})`)

console.log('\n✓ relay-rejection-no-penalty smoke test passed.')
console.log('  A penalized B for NONE of the policy (fee-floor) rejections, and a')
console.log('  subsequent valid tx from B was accepted+mined — no source-exclusion.')

A.stop(); B.stop()
await sleep(500)
process.exit(0)
