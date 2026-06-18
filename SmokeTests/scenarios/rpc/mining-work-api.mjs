// Mining work API contract + anti-double-mint.
//
// The node-owned work path is template -> submit-work. This pins the contract a
// real coordinator depends on:
//   - template returns workId + blockHex + effectiveTarget + staleToken, and
//     staleToken tracks the current tip.
//   - submit-work for an UNKNOWN workId is rejected (not accepted, non-2xx).
//   - submit-work for a valid workId at the genesis-easy target is accepted and
//     advances the tip by exactly one block.
//   - re-submitting the SAME (now consumed) workId is rejected and does NOT mint
//     a second reward (no double-mint), and the tip does not advance again.
//   - after a win, a freshly fetched template's staleToken points at the new tip.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('mining-work-api')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [ports] = await allocPorts(1, { seed: 241 })
const net = new LatticeNetwork()
net.installSignalHandlers()

console.log('=== mining-work-api smoke test ===')
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: ports.port, rpcPort: ports.rpcPort }))
node.start()
await node.waitForRPC()
function fail(m, d) { console.error(`  ✗ ${m}`); if (d) console.error(`    ${d}`); net.teardown(); process.exit(1) }

const info = await node.chainInfo()
const nexus = info.nexus
const ident = await node.readIdentity()
const rewardAddr = computeAddress(ident.publicKey)
const spec = (await node.rpc('GET', `/api/chain/spec?chainPath=${nexus}`)).json
const tipHash = async () => (await node.rpc('GET', `/api/block/latest?chainPath=${nexus}`)).json.hash
const getTemplate = async () => node.rpc('POST', '/api/chain/template', { chainPath: [nexus] })

console.log('\n[1] template returns the documented work fields; staleToken tracks the tip...')
const t0 = await getTemplate()
if (!t0.ok) fail('template request failed', JSON.stringify(t0.json))
for (const f of ['workId', 'blockHex', 'effectiveTarget', 'staleToken']) {
  if (!t0.json?.[f]) fail(`template missing ${f}`, JSON.stringify(t0.json).slice(0, 200))
}
const tip0 = await tipHash()
if (t0.json.staleToken !== tip0) fail('template staleToken != current tip', `${t0.json.staleToken} != ${tip0}`)
console.log(`  ✓ workId=${t0.json.workId.slice(0, 18)}… target=${t0.json.effectiveTarget.slice(0, 12)}… staleToken==tip`)

console.log('\n[2] submit-work for an UNKNOWN workId is rejected...')
const bogus = await node.rpc('POST', '/api/chain/submit-work', { chainPath: [nexus], workId: 'bafyreialieni4f4kingunknownworkidxxxxxxxxxxxxxxxxxxxxxxxxxx', nonce: 0 })
if (bogus.ok || bogus.json?.accepted === true) fail('unknown workId was accepted', JSON.stringify(bogus.json))
console.log(`  ✓ unknown workId rejected (status=${bogus.status} result=${bogus.json?.status})`)

const startBal = await node.balance(rewardAddr, nexus)
const startHeight = await node.height(nexus)

console.log('\n[3] submit-work for the valid workId is accepted and advances the tip by one...')
const win = await node.rpc('POST', '/api/chain/submit-work', { chainPath: [nexus], workId: t0.json.workId, nonce: 0 })
if (!win.ok || win.json?.accepted !== true) fail('valid work was not accepted', `status=${win.status} ${JSON.stringify(win.json)}`)
await waitFor(async () => (await node.height(nexus)) >= startHeight + 1 ? true : null, 'tip advanced', { timeoutMs: 30_000, intervalMs: 250 })
const afterHeight = await node.height(nexus)
if (afterHeight !== startHeight + 1) fail('tip advanced by more than one on a single win', `${startHeight} -> ${afterHeight}`)
const afterBal = await node.balance(rewardAddr, nexus)
const reward = afterBal - startBal
if (reward !== spec.initialReward) fail('single win did not mint exactly one reward', `delta=${reward} != ${spec.initialReward}`)
console.log(`  ✓ accepted; height ${startHeight}->${afterHeight}; minted exactly one reward=${reward}`)

console.log('\n[4] re-submitting the consumed workId is rejected and does NOT double-mint...')
const replay = await node.rpc('POST', '/api/chain/submit-work', { chainPath: [nexus], workId: t0.json.workId, nonce: 0 })
if (replay.ok && replay.json?.accepted === true) fail('consumed workId was accepted again (double-mint risk)', JSON.stringify(replay.json))
await sleep(1500) // allow any erroneous extra block to surface
const replayHeight = await node.height(nexus)
const replayBal = await node.balance(rewardAddr, nexus)
if (replayHeight !== afterHeight) fail('tip advanced on a replayed workId', `${afterHeight} -> ${replayHeight}`)
if (replayBal !== afterBal) fail('balance changed on a replayed workId (double-mint)', `${afterBal} -> ${replayBal}`)
console.log(`  ✓ replay rejected (status=${replay.status} result=${replay.json?.status}); no extra block, no extra reward`)

console.log('\n[5] a fresh template after the win points staleToken at the new tip...')
const t1 = await getTemplate()
if (!t1.ok) fail('second template request failed', JSON.stringify(t1.json))
const tip1 = await tipHash()
if (t1.json.staleToken !== tip1) fail('fresh template staleToken != new tip', `${t1.json.staleToken} != ${tip1}`)
if (t1.json.staleToken === t0.json.staleToken) fail('staleToken did not change after the tip advanced')
console.log(`  ✓ fresh template staleToken tracks the advanced tip`)

console.log('\n✓ mining-work-api smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
