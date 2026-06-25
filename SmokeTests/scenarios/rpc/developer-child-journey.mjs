// Developer child-chain journey (per-process child, the documented model):
//   1. Deploy + spawn a child chain as its own node (spawnChild does deploy +
//      child process + register-rpc to the CHILD's endpoint).
//   2. Discover the child through the PARENT's documented RPC (chain/map, spec,
//      genesis) — these proxy to the child via the registered endpoint.
//   3. Spend the genesis premine on the child using the documented
//      prepare -> sign -> submit transaction RPCs, merge-mine to confirm.
//   4. Query the on-chain receipt + address history for the developer's tx.
//
// NOTE: a child chain is hosted by its OWN node process; the parent only deploys
// genesis and routes to it. Deploying via /api/chain/deploy alone does NOT make
// the child resolvable on the parent — you must run the child node (spawnChild).

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress,
} from 'lattice-node-sdk'
import { sign } from 'lattice-node-sdk/wallet'

const ROOT = smokeRoot('developer-child-journey')
const [nexusPorts, childPorts] = await allocPorts(2, { seed: 132 })
const CHILD = 'DevChild'
const PREMINE = 2_000
const FEE = 5
const TRANSFER = 500

console.log('=== developer child-chain journey smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()
const node = net.add(new LatticeNode({ name: 'nexus', dir: `${ROOT}/nexus`, port: nexusPorts.port, rpcPort: nexusPorts.rpcPort }))

function fail(message, detail) {
  console.error(`  ✗ ${message}`)
  if (detail) console.error(`    ${detail}`)
  net.teardown()
  process.exit(1)
}
const historyEntries = (json) => Array.isArray(json) ? json : json?.transactions ?? []
const onChainCID = (entries) => {
  const e = entries.find((t) => t.txCID || t.cid)
  return e?.txCID ?? e?.cid
}

// Documented prepare -> sign -> submit, against whichever node hosts `chainPath`.
async function prepareSignSubmit(host, body, keypair) {
  const prep = await host.rpc('POST', '/api/transaction/prepare', body)
  if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
  if (!prep.json.bodyCID || !prep.json.bodyData) throw new Error(`prepare missing bodyCID/bodyData: ${JSON.stringify(prep.json)}`)
  const signature = sign(prep.json.signingPreimage ?? prep.json.bodyCID, keypair.privateKey)
  const submit = await host.rpc('POST', '/api/transaction', {
    signatures: { [keypair.publicKey]: signature },
    bodyCID: prep.json.bodyCID,
    bodyData: prep.json.bodyData,
    chainPath: body.chainPath,
  })
  return { prepared: prep.json, submit: submit.json, ok: submit.ok, status: submit.status }
}

node.start()
await node.waitForRPC()
await node.readIdentity()
const user = genKeypair()
const info = await node.chainInfo()
const nexusDir = info.nexus
const childPath = [nexusDir, CHILD]
const childPathText = childPath.join('/')
console.log(`  nexus=${nexusDir}  user=${user.address.slice(0, 16)}…`)

console.log(`\n[1] Deploy + spawn ${CHILD} as its own node (premine to the developer)...`)
const child = net.add(await node.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: childPorts,
  initialReward: 128, premine: PREMINE, premineRecipient: user.address,
}))
console.log(`  ✓ ${CHILD} node up at ${child.base}`)

console.log(`\n[2] Discover the child through the parent's documented RPC...`)
const chainMap = await waitFor(async () => {
  const r = await node.rpc('GET', '/api/chain/map')
  return r.ok && r.json?.[childPathText] ? r.json : null
}, `${CHILD} in chain/map`, { timeoutMs: 30_000, intervalMs: 500 })
// Registered endpoints are stored in API-base form (a trailing "/api" is appended at
// register time); normalize both sides so the check holds regardless of that suffix.
const normEndpoint = (u) => u.replace(/\/api\/?$/, '')
if (normEndpoint(chainMap[childPathText]) !== normEndpoint(child.base)) fail('chain/map endpoint mismatch', `${chainMap[childPathText]} != ${child.base}`)
console.log(`  ✓ chain/map: ${childPathText} -> ${chainMap[childPathText]}`)

const specR = await node.rpc('GET', `/api/chain/spec?chainPath=${encodeURIComponent(childPathText)}`)
if (!specR.ok) fail('child spec lookup failed (proxied via parent)', JSON.stringify(specR.json))
if (specR.json.directory !== CHILD || specR.json.initialReward !== 128) fail('child spec did not match deployment', JSON.stringify(specR.json))
console.log(`  ✓ spec (proxied): directory=${specR.json.directory} reward=${specR.json.initialReward}`)

const genesisR = await node.rpc('GET', `/api/chain/genesis?chainPath=${encodeURIComponent(childPathText)}`)
if (!genesisR.ok || !genesisR.json?.genesisHex || genesisR.json.directory !== CHILD) fail('genesis discovery failed', JSON.stringify(genesisR.json))
console.log(`  ✓ genesis ${genesisR.json.genesisHash?.slice(0, 20)}… discovered via parent`)

console.log(`\n[3] Verify the genesis premine is spendable on the child...`)
const premineBal = await child.balance(user.address, CHILD)
// premine is denominated in units of initialReward; the spec reports the exact
// minted amount via premineAmount. The developer's genesis balance must match it.
const expectedPremine = specR.json.premineAmount ?? (PREMINE * 128)
if (premineBal !== expectedPremine) fail('child premine balance != spec premineAmount', `${premineBal} != ${expectedPremine}`)
console.log(`  ✓ ${CHILD} premine balance=${premineBal} (matches spec premineAmount)`)

console.log(`\n[4] Spend the premine via documented prepare/sign/submit, merge-mine to confirm...`)
// One merged miner advances both chains from genesis (the node builds templates with
// full state access — no separate Nexus-only warm-up needed).
const miner = new LatticeMiner(node, [child])
await miner.start()
net.addMiner(miner)
await node.waitForHeight(3, nexusDir, { timeoutMs: 2 * 60_000 })
await child.waitForHeight(2, CHILD, { timeoutMs: 120_000 })

const recipient = genKeypair()
const userNonce = await child.nonce(user.address, CHILD)
const transfer = await prepareSignSubmit(child, {
  chainPath: childPath, nonce: userNonce, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(TRANSFER + FEE) },
    { owner: recipient.address, delta: TRANSFER },
  ],
}, user)
if (!transfer.ok) fail('child transfer submit failed', JSON.stringify(transfer.submit))
console.log(`  ✓ transfer accepted (submit txCID=${(transfer.submit.txCID ?? '').slice(0, 20)}…)`)

await waitFor(async () => (await child.balance(recipient.address, CHILD)) >= TRANSFER,
  'child transfer confirmed', { timeoutMs: 120_000, intervalMs: 1_000 })
await miner.stop()
await child.awaitQuiesced(CHILD)
const userAfter = await child.balance(user.address, CHILD)
const expectedAfter = premineBal - TRANSFER - FEE
if (userAfter !== expectedAfter) fail('developer balance after transfer wrong', `${userAfter} != ${expectedAfter}`)
console.log(`  ✓ recipient funded; developer balance ${userAfter} == ${premineBal} - ${TRANSFER} - ${FEE}`)

console.log(`\n[5] Query on-chain receipt + address history for the developer's tx...`)
const qp = child._queryPath(CHILD)
const histR = await child.rpc('GET', `/api/transactions/${user.address}?chainPath=${encodeURIComponent(qp)}`)
if (!histR.ok) fail('developer history failed', JSON.stringify(histR.json))
const entries = historyEntries(histR.json)
if (entries.length < 1) fail('developer history empty — transfer not indexed', JSON.stringify(histR.json).slice(0, 400))
const txCID = onChainCID(entries)
if (!txCID) fail('history entry missing txCID', JSON.stringify(entries[0]).slice(0, 200))
console.log(`  ✓ history has the transfer (on-chain txCID=${txCID.slice(0, 20)}…)`)

const rcpt = await child.rpc('GET', `/api/receipt/${txCID}?chainPath=${encodeURIComponent(qp)}`)
if (!rcpt.ok) fail('receipt lookup failed for confirmed tx', JSON.stringify(rcpt.json))
const inclusion = rcpt.json.blockHash ?? rcpt.json.block ?? rcpt.json.height
if (!inclusion) fail('receipt has no inclusion block', JSON.stringify(rcpt.json).slice(0, 200))
console.log(`  ✓ receipt references inclusion block`)

const txLookup = await child.rpc('GET', `/api/transaction/${txCID}?chainPath=${encodeURIComponent(qp)}`)
if (!txLookup.ok) fail('transaction lookup failed', JSON.stringify(txLookup.json))
const lookedUpFee = txLookup.json.fee ?? txLookup.json.body?.fee
if (Number(lookedUpFee) !== FEE) fail('transaction lookup fee mismatch', `${lookedUpFee} != ${FEE}`)
console.log(`  ✓ transaction lookup fee=${lookedUpFee} matches submit`)

console.log(`\n✓ developer child-chain journey smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
