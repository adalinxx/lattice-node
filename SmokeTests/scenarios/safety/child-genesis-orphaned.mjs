// Child-genesis orphaned by a parent reorg: a child chain announced on-chain via a
// GenesisAction must DISAPPEAR from the canonical parent's child-discovery set when the
// parent block carrying that announcement is orphaned. The parent's GenesisState
// (directory -> genesisCID, exposed by /api/chain/children) is parent-canonical state; it
// must REVERT on reorg, not leak a phantom child that new followers could still "discover"
// after its deploy was undone.
//
// Distinct from cross-chain-reorg (which asserts the child's own STATE survives a parent
// reorg): a child's state is independently verified and survives, but the parent's
// DISCOVERY announcement is canonical parent state and must revert with the reorg.
//
// Also exercises node robustness: reorging a Nexus that currently hosts a deployed child
// must not crash the node.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork } from 'lattice-node-sdk'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { computeAddress } from 'lattice-node-sdk/wallet'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, tipInfo } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('child-genesis-orphaned')
const [a, c] = await allocPorts(2, { seed: 261 })
const CHILD = 'OrphanToy'

console.log('=== child-genesis-orphaned smoke test ===')
const A = new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort })
const C = new LatticeNode({ name: 'C', dir: `${ROOT}/C`, port: c.port, rpcPort: c.rpcPort })
const net = new LatticeNetwork(); net.add(A); net.add(C); net.installSignalHandlers()
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }
async function stopAndAwaitShutdown(node, { timeoutMs = 30_000 } = {}) {
  await node.stop()
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try { await fetch(`${node.base}/api/chain/info`, { signal: AbortSignal.timeout(500) }) } catch { return }
    await sleep(500)
  }
  throw new Error(`${node.name} failed to shut down`)
}
// Returns the child-directory list on a SUCCESSFUL read, or null if the RPC failed.
// null (couldn't read) is distinct from [] (read, no children) — so the "vanished" check
// never passes on a transient fail-closed window during the reorg (that would be a false pass).
async function childrenOf(node, dir) {
  const r = await node.rpc('GET', `/api/chain/children?chainPath=${dir}`).catch(() => null)
  if (!r || !r.ok) return null
  return (r.json?.children ?? []).map((c) => c.directory)
}

A.start(['--finality-confirmations', '999999'])
await A.waitForRPC()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)
const nexusDir = (await chainInfo(A)).nexus

// [1] A mines Nexus, deploys child, and ANNOUNCES it (genesisAction → GenesisState).
// deploy = availability only; the genesisAction tx is what makes the child discoverable.
console.log('\n[1] A mines Nexus + deploys + announces child; confirm discoverable...')
const child = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, premine: 5, premineRecipient: aAddr, targetBlockTime: 1 }))
const genesisHash = child._deployInfo.genesisHash
await startMining(A, nexusDir)
await waitFor(async () => (await A.balance(aAddr, nexusDir)) >= 5000 ? true : null, 'A coinbase for announce', { timeoutMs: 90_000, intervalMs: 500 })
await waitFor(async () => {
  const base = await A.nonce(aAddr, nexusDir)
  const r = await A.submitTx({
    nonce: base, signers: [aAddr], fee: 1000,
    accountActions: [{ owner: aAddr, delta: -1000 }],
    genesisActions: [{ directory: CHILD, blockCID: genesisHash }],
  }, nexusDir, aKP)
  return r.ok ? true : null
}, 'submit child genesisAction (announce)', { timeoutMs: 60_000, intervalMs: 1000 })
await waitFor(async () => { const d = await childrenOf(A, nexusDir); return d && d.includes(CHILD) ? true : null }, 'child announced in Nexus GenesisState', { timeoutMs: 120_000, intervalMs: 1000 })
await stopMining(A, nexusDir); await awaitMiningQuiesced(A, nexusDir)
const aTip = await tipInfo(A)
console.log(`  ✓ ${CHILD} discoverable via /api/chain/children; A Nexus @${aTip.height}`)

// [2] C (independent, from genesis) mines a strictly heavier Nexus fork WITHOUT the deploy.
console.log('\n[2] C mines a heavier Nexus fork without the deploy...')
C.start(['--finality-confirmations', '999999'])
await C.waitForRPC()
await startMining(C, nexusDir)
await waitFor(async () => ((await tipInfo(C))?.height ?? 0) > aTip.height + 3 ? true : null, 'C heavier than A', { timeoutMs: 90_000, intervalMs: 500 })
await stopMining(C, nexusDir); await awaitMiningQuiesced(C, nexusDir)
const cTip = await tipInfo(C)
if (cTip.tip === aTip.tip) fail('forks not distinct')
console.log(`  C Nexus @${cTip.height} (heavier)`)

// [3] Heal; A reorgs Nexus to C's fork, orphaning the deploy block.
console.log('\n[3] Heal; A reorgs Nexus to C, orphaning the deploy...')
await stopAndAwaitShutdown(C); await sleep(500)
C.start(['--finality-confirmations', '999999', '--peer', A.peerArg()])
await C.waitForRPC()
await waitFor(async () => (await tipInfo(A))?.tip === cTip.tip ? true : null, 'A reorged onto C', { timeoutMs: 300_000, intervalMs: 3000 })
console.log('  ✓ A reorged Nexus onto C')

// [4] THE TEST: the orphaned child must no longer be discoverable on the canonical Nexus.
console.log('\n[4] Require the orphaned child to vanish from chainChildren...')
// Require a SUCCESSFUL read (node healthy) that does NOT include the child — a null read
// (RPC down) keeps waiting rather than passing, so a fail-closed window can't false-pass.
await waitFor(async () => { const d = await childrenOf(A, nexusDir); return d && !d.includes(CHILD) ? true : null }, `${CHILD} reverted from GenesisState`, { timeoutMs: 60_000, intervalMs: 1000 })
console.log(`  ✓ ${CHILD} no longer announced on the canonical Nexus (GenesisState reverted, node healthy)`)

// [5] Node stays healthy + Nexus advances after orphaning a hosted child's deploy.
console.log('\n[5] Verify the node stays healthy + Nexus advances...')
await startMining(A, nexusDir)
await waitFor(async () => ((await tipInfo(A))?.height ?? 0) > cTip.height ? true : null, 'Nexus advances post-orphan', { timeoutMs: 60_000, intervalMs: 500 })
await stopMining(A, nexusDir)
console.log('  ✓ Nexus advances after the deploy was orphaned')
// The orphaned child's separate PROCESS must also survive (its deploy was undone, but the
// process must not crash/wedge) — probe its own RPC directly.
const childAlive = await child.rpc('GET', '/api/chain/info').catch(() => null)
if (!childAlive || !childAlive.ok) fail('child process did not survive its deploy being orphaned')
console.log('  ✓ orphaned child process still alive (RPC responds)')

console.log('\n✓ child-genesis-orphaned smoke test passed.')
net.teardown(); await sleep(500); process.exit(0)
