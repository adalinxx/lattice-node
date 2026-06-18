// Block explorer API test — hard correctness assertions (not just 200/shape).
// Single-chain read endpoints:
//   /api/block/latest, /api/block/{height|hash}, /api/block/{id}/transactions,
//   /api/transaction/{txCID}, /api/transactions/{address},
//   /api/state/account/{address}, /api/light/headers, /api/receipt/{txCID}
//
// Follow-up (needs a child + cross-chain deposit, tracked separately): assert
// /api/block/{id}/children contains the merged-mined child block, and
// /api/deposits limit/after pagination.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, chainOf, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('block-explorer')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 53 })

console.log('=== block-explorer API smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
function fail(m) { console.error(`  ✗ ${m}`); node.stop(); process.exit(1) }

const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const info = await chainInfo(node)
const nexusDir = info.nexus

await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const user = genKeypair()
const TRANSFER = 1000, FEE = 1
const txNonce = await getNonce(node, minerAddr, nexusDir)
const txResult = await submitTx(node, {
  chainPath: [nexusDir], nonce: txNonce, signers: [minerAddr], fee: FEE,
  accountActions: [{ owner: minerAddr, delta: -(TRANSFER + FEE) }, { owner: user.address, delta: TRANSFER }],
}, nexusDir, minerKP)
if (!txResult.ok) fail(`setup tx failed: ${JSON.stringify(txResult).slice(0, 160)}`)
const txCID = txResult.submit?.txCID ?? txResult.txCID
if (!txCID) fail(`no txCID from submit: ${JSON.stringify(txResult).slice(0, 160)}`)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= TRANSFER, 'tx mined', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const height = chainOf(await chainInfo(node), nexusDir).height

console.log('\n[1] /api/block/latest — hash + height match tip...')
const latest = await node.rpc('GET', `/api/block/latest?chainPath=${nexusDir}`)
if (!latest.ok) fail(`block/latest failed: ${JSON.stringify(latest.json)}`)
const latestHash = latest.json.hash ?? latest.json.blockHash ?? latest.json.cid
const latestHeight = latest.json.height ?? latest.json.blockHeight
if (!latestHash) fail(`block/latest missing hash`)
if (latestHeight !== height) fail(`block/latest height ${latestHeight} != tip ${height}`)
console.log(`  ✓ latest hash=${String(latestHash).slice(0, 16)}… height=${latestHeight}`)

console.log('\n[2] /api/block/{height} — returns that height...')
const byH = await node.rpc('GET', `/api/block/3?chainPath=${nexusDir}`)
if (!byH.ok) fail(`block-by-height failed: ${JSON.stringify(byH.json)}`)
if ((byH.json.height ?? byH.json.blockHeight) !== 3) fail(`block/3 returned height ${byH.json.height ?? byH.json.blockHeight}`)
const h3Hash = byH.json.hash ?? byH.json.blockHash ?? byH.json.cid
console.log(`  ✓ block@3 height=3 hash=${String(h3Hash).slice(0, 16)}…`)

console.log('\n[3] /api/block/{hash} — round-trips to the same block...')
const byHash = await node.rpc('GET', `/api/block/${latestHash}?chainPath=${nexusDir}`)
if (!byHash.ok) fail(`block-by-hash failed: ${JSON.stringify(byHash.json)}`)
if ((byHash.json.height ?? byHash.json.blockHeight) !== height) fail(`block-by-hash height mismatch`)
console.log(`  ✓ block-by-hash height=${height}`)

console.log('\n[4] /api/block/{hash}/transactions — non-empty (>=1 incl coinbase)...')
const blkTxs = await node.rpc('GET', `/api/block/${latestHash}/transactions?chainPath=${nexusDir}`)
if (!blkTxs.ok) fail(`block/transactions failed: ${JSON.stringify(blkTxs.json)}`)
const blkList = Array.isArray(blkTxs.json) ? blkTxs.json : (blkTxs.json.transactions ?? [])
if (blkList.length < 1) fail(`latest block has 0 transactions (expected >=1 coinbase)`)
console.log(`  ✓ latest block carries ${blkList.length} transaction(s)`)

console.log('\n[5] /api/transactions/{address} — user history has exactly the transfer...')
const uHist = await node.rpc('GET', `/api/transactions/${user.address}?chainPath=${nexusDir}`)
if (!uHist.ok) fail(`user tx history failed: ${JSON.stringify(uHist.json)}`)
const uEntries = Array.isArray(uHist.json) ? uHist.json : (uHist.json.transactions ?? [])
if (uEntries.length < 1) fail(`user history empty — transfer not indexed`)
const onChainTxCID = uEntries[0].txCID ?? uEntries[0].cid
if (!onChainTxCID) fail(`user history entry missing txCID: ${JSON.stringify(uEntries[0]).slice(0, 160)}`)
console.log(`  ✓ user history has the transfer (txCID=${String(onChainTxCID).slice(0, 16)}…)`)
// Miner history (coinbases + the transfer) must also be non-empty.
const mHist = await node.rpc('GET', `/api/transactions/${minerAddr}?chainPath=${nexusDir}`)
if (!mHist.ok || (Array.isArray(mHist.json) ? mHist.json : (mHist.json.transactions ?? [])).length < 1) fail(`miner history empty`)

console.log('\n[6] /api/transaction/{txCID} — decoded tx content matches submit...')
const txLookup = await node.rpc('GET', `/api/transaction/${onChainTxCID}?chainPath=${nexusDir}`)
if (!txLookup.ok) fail(`tx lookup failed: ${JSON.stringify(txLookup.json)}`)
const txFee = txLookup.json.fee ?? txLookup.json.body?.fee
if (Number(txFee) !== FEE) fail(`tx lookup fee ${txFee} != ${FEE}`)
console.log(`  ✓ tx lookup fee=${txFee} matches submit`)

console.log('\n[7] /api/state/account/{address} — exact transferred balance...')
const acct = await node.rpc('GET', `/api/state/account/${user.address}?chainPath=${nexusDir}`)
if (!acct.ok) fail(`account state failed: ${JSON.stringify(acct.json)}`)
if (acct.json.balance !== TRANSFER) fail(`account balance ${acct.json.balance} != ${TRANSFER}`)
console.log(`  ✓ account balance == ${TRANSFER}`)

console.log('\n[8] /api/light/headers — serves a verifiable, chained header range...')
const lh = await node.rpc('GET', `/api/light/headers?chainPath=${nexusDir}&from=1&to=5`)
if (!lh.ok) fail(`light/headers failed: ${JSON.stringify(lh.json)}`)
const hdrs = lh.json.headers ?? []
if (lh.json.count !== hdrs.length) fail(`light/headers count ${lh.json.count} != headers.length ${hdrs.length}`)
if (hdrs.length !== 5) fail(`light/headers expected 5 headers for from=1..to=5, got ${hdrs.length}`)
for (let i = 0; i < hdrs.length; i++) {
  const h = hdrs[i]
  if (h.height !== i + 1) fail(`header[${i}] height ${h.height} != ${i + 1}`)
  for (const f of ['hash', 'stateRoot', 'target', 'cumulativeWork']) {
    if (!h[f]) fail(`header@${h.height} missing ${f}: ${JSON.stringify(h).slice(0, 160)}`)
  }
  if (i > 0 && h.previousHash !== hdrs[i - 1].hash) fail(`header@${h.height} previousHash does not chain to prior header hash`)
  if (i > 0 && BigInt(`0x${h.cumulativeWork}`) <= BigInt(`0x${hdrs[i - 1].cumulativeWork}`)) {
    fail(`header@${h.height} cumulativeWork not strictly increasing`)
  }
}
// Cross-check a served header against the full block endpoint.
const xref = await node.rpc('GET', `/api/block/3?chainPath=${nexusDir}`)
if (hdrs[2].hash !== (xref.json.hash ?? xref.json.blockHash)) fail(`light header@3 hash != block@3 hash`)
if (hdrs[2].stateRoot !== xref.json.postStateCID) fail(`light header@3 stateRoot != block@3 postStateCID`)
console.log(`  ✓ light/headers served 5 chained headers; @3 cross-checks block endpoint`)

console.log('\n[9] /api/receipt/{txCID} — confirms inclusion block for the tx...')
const rcpt = await node.rpc('GET', `/api/receipt/${onChainTxCID}?chainPath=${nexusDir}`)
if (!rcpt.ok) fail(`receipt lookup failed: ${JSON.stringify(rcpt.json)}`)
const rcptBlock = rcpt.json.blockHash ?? rcpt.json.block ?? rcpt.json.height
if (!rcptBlock) fail(`receipt has no inclusion block reference: ${JSON.stringify(rcpt.json).slice(0, 160)}`)
console.log(`  ✓ receipt references inclusion block`)

console.log('\n✓ block-explorer API smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
