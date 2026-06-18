// Balance proof and light client headers. Tests:
//   1. /api/proof/{address} returns a self-contained witness for a funded account
//   2. /api/proof/{address} returns a zero-balance absence witness for an unfunded account
//   3. /api/light/headers returns a contiguous canonical header range
//   4. the returned witness verifies offline in a separate light-client process
//   5. /api/light/proof/{address} agrees with headers, block state, and balance RPC

import { existsSync, readFileSync } from 'fs'
import { spawnSync } from 'child_process'
import { allocPorts, smokeRoot, BIN } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('balance-proof')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 57 })
const PROOF_VERIFIER_BIN = process.env.LATTICE_PROOF_VERIFIER_BIN
  || BIN.replace('LatticeNode', 'LatticeProofVerifier')

async function fail(message) {
  console.error(`  ✗ ${message}`)
  node.stop(); await sleep(500); process.exit(1)
}

function assertProofShape(label, proof, address) {
  if (!proof || typeof proof !== 'object') throw new Error(`${label}: missing proof object`)
  if (proof.address !== address) throw new Error(`${label}: address mismatch ${proof.address} !== ${address}`)
  for (const field of ['blockHash', 'blockHeight', 'header', 'stateRoot', 'accountRoot', 'balance', 'nonce', 'witness', 'timestamp']) {
    if (!(field in proof)) throw new Error(`${label}: missing ${field}`)
  }
  if (typeof proof.blockHash !== 'string' || !proof.blockHash.startsWith('bafy')) throw new Error(`${label}: invalid blockHash`)
  if (!Number.isInteger(proof.blockHeight) || proof.blockHeight < 1) throw new Error(`${label}: invalid blockHeight`)
  if (!proof.header || typeof proof.header !== 'object') throw new Error(`${label}: missing header object`)
  if (proof.header.hash !== proof.blockHash) throw new Error(`${label}: header hash mismatch`)
  if (proof.header.height !== proof.blockHeight) throw new Error(`${label}: header height mismatch`)
  if (proof.header.stateRoot !== proof.stateRoot) throw new Error(`${label}: header stateRoot mismatch`)
  if (proof.header.timestamp !== proof.timestamp) throw new Error(`${label}: header timestamp mismatch`)
  if (typeof proof.stateRoot !== 'string' || !proof.stateRoot.startsWith('bafy')) throw new Error(`${label}: invalid stateRoot`)
  if (typeof proof.accountRoot !== 'string' || !proof.accountRoot.startsWith('bafy')) throw new Error(`${label}: invalid accountRoot`)
  if (!Number.isInteger(proof.balance) || proof.balance < 0) throw new Error(`${label}: invalid balance`)
  if (!Number.isInteger(proof.nonce) || proof.nonce < 0) throw new Error(`${label}: invalid nonce`)
  if (!Array.isArray(proof.witness) || proof.witness.length === 0) throw new Error(`${label}: empty witness`)
  for (const [i, node] of proof.witness.entries()) {
    if (typeof node.cid !== 'string' || !node.cid.startsWith('bafy')) throw new Error(`${label}: witness[${i}] invalid cid`)
    if (typeof node.data !== 'string' || node.data.length === 0) throw new Error(`${label}: witness[${i}] missing data`)
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function tamperBalance(proof) {
  const tampered = clone(proof)
  tampered.balance += 1
  return tampered
}

function tamperWitnessData(proof) {
  const tampered = clone(proof)
  const node = tampered.witness[0]
  const replacement = node.data.endsWith('A') ? 'B' : 'A'
  node.data = `${node.data.slice(0, -1)}${replacement}`
  return tampered
}

function tamperBlockHash(proof) {
  const tampered = clone(proof)
  tampered.blockHash = `${tampered.blockHash}-lie`
  return tampered
}

function tamperTimestamp(proof) {
  const tampered = clone(proof)
  tampered.timestamp += 1
  return tampered
}

function verifyProofOffline(label, proof, expectedValid) {
  const result = spawnSync(PROOF_VERIFIER_BIN, [], {
    input: JSON.stringify(proof),
    encoding: 'utf8',
    maxBuffer: 1_000_000,
  })
  const valid = result.status === 0
  if (valid !== expectedValid) {
    const stdout = (result.stdout || '').trim()
    const stderr = (result.stderr || '').trim()
    throw new Error(`${label}: offline verifier ${expectedValid ? 'rejected' : 'accepted'} proof (status=${result.status}, stdout=${stdout}, stderr=${stderr})`)
  }
}

console.log('=== balance-proof smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
if (!existsSync(PROOF_VERIFIER_BIN)) {
  await fail(`proof verifier binary not found at ${PROOF_VERIFIER_BIN}; run swift build --product LatticeProofVerifier`)
}
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const coinbaseAuthority = JSON.parse(readFileSync(`${node.dir}/coinbase-authority.json`, 'utf8'))
const coinbaseAuthorityAddr = computeAddress(coinbaseAuthority.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const minedInfo = await chainInfo(node)
const tipEntry = minedInfo.chains.find(c => c.directory === nexusDir)
const currentHeight = tipEntry.height
const currentBalance = await getBalance(node, minerAddr, nexusDir)
const payoutNonce = await getNonce(node, minerAddr, nexusDir)
const coinbaseAuthorityNonce = await getNonce(node, coinbaseAuthorityAddr, nexusDir)

console.log(`\n[1] Balance proof for payout account...`)
const proofResp = await node.rpc('GET', `/api/proof/${minerAddr}?chainPath=${nexusDir}`)
if (!proofResp.ok) await fail(`proof endpoint failed for funded account: ${JSON.stringify(proofResp.json)}`)
try { assertProofShape('funded proof', proofResp.json, minerAddr) } catch (e) { await fail(e.message) }
if (proofResp.json.blockHeight !== currentHeight) await fail(`proof height ${proofResp.json.blockHeight} != current height ${currentHeight}`)
if (proofResp.json.blockHash !== tipEntry.tip) await fail(`proof blockHash ${proofResp.json.blockHash} != current tip ${tipEntry.tip}`)
if (proofResp.json.balance !== currentBalance) await fail(`proof balance ${proofResp.json.balance} != balance RPC ${currentBalance}`)
if (proofResp.json.nonce !== payoutNonce) await fail(`proof stored nonce ${proofResp.json.nonce} != payout nonce RPC ${payoutNonce}`)
if (payoutNonce !== 0) await fail(`payout nonce ${payoutNonce} should not be consumed by coinbase rewards`)
console.log(`  ✓ funded proof is tip-bound and carries ${proofResp.json.witness.length} witness nodes`)

const authorityProof = await node.rpc('GET', `/api/proof/${coinbaseAuthorityAddr}?chainPath=${nexusDir}`)
if (!authorityProof.ok) await fail(`proof endpoint failed for coinbase authority: ${JSON.stringify(authorityProof.json)}`)
try { assertProofShape('coinbase authority proof', authorityProof.json, coinbaseAuthorityAddr) } catch (e) { await fail(e.message) }
if (authorityProof.json.blockHash !== proofResp.json.blockHash) await fail(`authority proof served a different tip`)
if (authorityProof.json.stateRoot !== proofResp.json.stateRoot) await fail(`authority proof served a different state root`)
if (coinbaseAuthorityNonce !== authorityProof.json.nonce + 1) {
  await fail(`authority next nonce ${coinbaseAuthorityNonce} != stored proof nonce ${authorityProof.json.nonce} + 1`)
}
if (authorityProof.json.nonce !== currentHeight - 1) await fail(`authority stored nonce ${authorityProof.json.nonce} != expected coinbase nonce ${currentHeight - 1}`)
console.log(`  ✓ coinbase authority proof carries mined nonce ${authorityProof.json.nonce}`)

console.log(`\n[2] Balance proof for nonexistent account...`)
const ghost = genKeypair()
const ghostProof = await node.rpc('GET', `/api/proof/${ghost.address}?chainPath=${nexusDir}`)
if (!ghostProof.ok) await fail(`proof endpoint failed for unfunded account: ${JSON.stringify(ghostProof.json)}`)
try { assertProofShape('ghost proof', ghostProof.json, ghost.address) } catch (e) { await fail(e.message) }
if (ghostProof.json.blockHash !== proofResp.json.blockHash) await fail(`ghost proof served a different tip`)
if (ghostProof.json.stateRoot !== proofResp.json.stateRoot) await fail(`ghost proof served a different state root`)
if (ghostProof.json.balance !== 0) await fail(`ghost proof balance ${ghostProof.json.balance} != 0`)
if (ghostProof.json.nonce !== 0) await fail(`ghost proof nonce ${ghostProof.json.nonce} != 0`)
console.log(`  ✓ unfunded account proof is an explicit zero-balance witness`)

console.log(`\n[3] Offline light-client proof verification...`)
try {
  verifyProofOffline('funded proof', proofResp.json, true)
  verifyProofOffline('coinbase authority proof', authorityProof.json, true)
  verifyProofOffline('ghost proof', ghostProof.json, true)
  verifyProofOffline('balance-tampered proof', tamperBalance(proofResp.json), false)
  verifyProofOffline('witness-tampered proof', tamperWitnessData(proofResp.json), false)
  verifyProofOffline('blockHash-tampered proof', tamperBlockHash(proofResp.json), false)
  verifyProofOffline('timestamp-tampered proof', tamperTimestamp(proofResp.json), false)
} catch (e) {
  await fail(e.message)
}
console.log(`  ✓ real proofs verify offline and tampered proofs are rejected`)

console.log(`\n[4] Light client headers...`)
const headersResp = await node.rpc('GET', `/api/light/headers?chainPath=${nexusDir}&from=1&to=${currentHeight}`)
if (!headersResp.ok) await fail(`light headers failed: ${JSON.stringify(headersResp.json)}`)
const headers = headersResp.json.headers
if (!Array.isArray(headers)) await fail(`light headers response missing headers[]`)
if (headersResp.json.count !== headers.length) await fail(`light headers count mismatch`)
if (headers.length !== currentHeight) await fail(`expected ${currentHeight} headers, got ${headers.length}`)
for (let i = 0; i < headers.length; i++) {
  const h = headers[i]
  const expectedHeight = i + 1
  if (h.height !== expectedHeight) await fail(`header[${i}] height ${h.height} != ${expectedHeight}`)
  if (i > 0 && h.previousHash !== headers[i - 1].hash) await fail(`header ${h.height} does not link to previous header`)
  for (const field of ['hash', 'stateRoot', 'target', 'cumulativeWork']) {
    if (typeof h[field] !== 'string' || h[field].length === 0) await fail(`header ${h.height} missing ${field}`)
  }
}
const tipHeader = headers[headers.length - 1]
if (tipHeader.hash !== proofResp.json.blockHash) await fail(`tip header hash ${tipHeader.hash} != proof block ${proofResp.json.blockHash}`)
if (tipHeader.stateRoot !== proofResp.json.stateRoot) await fail(`tip header stateRoot ${tipHeader.stateRoot} != proof stateRoot ${proofResp.json.stateRoot}`)
if (tipHeader.timestamp !== proofResp.json.timestamp) await fail(`tip header timestamp ${tipHeader.timestamp} != proof timestamp ${proofResp.json.timestamp}`)
console.log(`  ✓ ${headers.length} contiguous light headers link to the proof tip`)

console.log(`\n[5] Light client proof...`)
const lightProof = await node.rpc('GET', `/api/light/proof/${minerAddr}?chainPath=${nexusDir}`)
if (!lightProof.ok) await fail(`light proof failed: ${JSON.stringify(lightProof.json)}`)
try { assertProofShape('light proof', lightProof.json, minerAddr) } catch (e) { await fail(e.message) }
for (const field of ['blockHash', 'blockHeight', 'stateRoot', 'accountRoot', 'balance', 'nonce']) {
  if (lightProof.json[field] !== proofResp.json[field]) await fail(`light proof ${field} disagrees with /api/proof`)
}
console.log(`  ✓ light proof matches /api/proof output`)

console.log(`\n[6] Block-at-height state query...`)
const blockState = await node.rpc('GET', `/api/block/${currentHeight}/state?chainPath=${nexusDir}`)
if (!blockState.ok) await fail(`block state failed: ${JSON.stringify(blockState.json)}`)
if (blockState.json.blockHash !== proofResp.json.blockHash) await fail(`block state hash does not match proof`)
if (blockState.json.postStateCID !== proofResp.json.stateRoot) await fail(`block postStateCID does not match proof stateRoot`)
const acctAtBlock = await node.rpc('GET', `/api/block/${currentHeight}/state/account/${minerAddr}?chainPath=${nexusDir}`)
if (!acctAtBlock.ok) await fail(`account state at proof block failed: ${JSON.stringify(acctAtBlock.json)}`)
if (acctAtBlock.json.balance !== proofResp.json.balance) await fail(`account@proof balance ${acctAtBlock.json.balance} != proof ${proofResp.json.balance}`)
console.log(`  ✓ proof state root resolves through block state and account state routes`)

console.log(`\n✓ balance-proof smoke test passed.`)
await node.stop()

await sleep(500)
process.exit(0)
