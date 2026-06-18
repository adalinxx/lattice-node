// Invalid RPC transaction resilience. This is not a fake Byzantine P2P peer:
// it submits malformed transactions over public RPC and checks the node keeps
// mining while a real follower remains healthy.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, sign } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight, mineBurst,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'

const ROOT = smokeRoot('invalid-rpc-transaction-resilience')
const [a, c] = await allocPorts(2, { seed: 209 })

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'C', port: c.port, rpcPort: c.rpcPort },
  ],
})
const A = net.byName('A')
const C = net.byName('C')

console.log('=== invalid-rpc-transaction-resilience smoke test ===')

A.start()
await A.waitForRPC()
await A.readIdentity()
C.start({ peers: [A] })
await C.waitForRPC()

const info = await chainInfo(A)
const nexus = info.nexus
const minerIdent = await A.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const { computeAddress } = await import('../../lib/wallet.mjs')
const minerAddr = computeAddress(minerIdent.publicKey)

console.log('\n[1] Submit transaction with invalid signature (bad actor)...')
await startMining(A, nexus)
await waitForHeight(A, nexus, 3, 30_000)

// Fund a user so we can attempt bad txs — stop mining first to avoid nonce races
const user = genKeypair()
await stopMining(A, nexus)
await awaitMiningQuiesced(A, nexus)
const nonce0 = await getNonce(A, minerAddr, nexus)
await submitTx(A, {
  chainPath: [nexus], nonce: nonce0, signers: [minerAddr], fee: 1,
  accountActions: [{ owner: minerAddr, delta: -1001 }, { owner: user.address, delta: 1000 }],
}, nexus, minerKP)
await startMining(A, nexus)
await waitFor(async () => (await getBalance(A, user.address, nexus)) >= 1000, 'user funded', { timeoutMs: 30_000 })

// Submit a tx with a WRONG signature (bad actor trying to steal funds)
const badKey = genKeypair()  // wrong key, not user's key
const userNonce = await getNonce(A, user.address, nexus)
const prep = await A.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexus], nonce: userNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }, { owner: badKey.address, delta: 500 }],
})
if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)

// Sign with the WRONG key
const badSig = sign(prep.json.signingPreimage ?? prep.json.bodyCID, badKey.privateKey)
const badSubmit = await A.rpc('POST', '/api/transaction', {
  signatures: { [badKey.publicKey]: badSig },
  bodyCID: prep.json.bodyCID,
  bodyData: prep.json.bodyData,
  chainPath: [nexus],
})
if (badSubmit.json.accepted !== false) {
  console.error('  ✗ Bad signature tx was accepted!')
  net.teardown(); process.exit(1)
}
console.log(`  ✓ Bad-signature tx correctly rejected: ${badSubmit.json.error}`)

console.log('\n[2] Submit tx with mismatched signer (wrong pubkey in signers array)...')
const prep2 = await A.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexus], nonce: userNonce, signers: [badKey.address],  // wrong signer
  fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }, { owner: badKey.address, delta: 500 }],
})
if (prep2.ok) {
  const realSig = sign(prep2.json.signingPreimage ?? prep2.json.bodyCID, user.privateKey)
  const mismatchSubmit = await A.rpc('POST', '/api/transaction', {
    signatures: { [user.publicKey]: realSig },
    bodyCID: prep2.json.bodyCID,
    bodyData: prep2.json.bodyData,
    chainPath: [nexus],
  })
  if (mismatchSubmit.json.accepted !== false) {
    console.error('  ✗ Signer-mismatch tx was accepted!')
    net.teardown(); process.exit(1)
  }
  console.log(`  ✓ Signer-mismatch tx correctly rejected: ${mismatchSubmit.json.error}`)
}

console.log('\n[3] Verify chain continued advancing despite bad txs...')
const aTip = await mineBurst(A, nexus, { targetHeight: 10 })
console.log(`  A tip height=${aTip.height}`)
if (aTip.height < 8) {
  console.error('  ✗ Chain stalled after bad txs')
  net.teardown(); process.exit(1)
}

console.log('\n[4] Verify C converged with A despite bad gossip...')
await waitFor(async () => {
  const ct = await A.rpc('GET', '/api/chain/info')
  const bt = await C.rpc('GET', '/api/chain/info')
  const aH = ct.json?.chains?.[0]?.tip
  const cH = bt.json?.chains?.[0]?.tip
  return aH && aH === cH ? true : null
}, 'C converged with A', { timeoutMs: 60_000, intervalMs: 2000 })

console.log('  ✓ C converged with A correctly')
console.log('\n✓ invalid-rpc-transaction-resilience smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
