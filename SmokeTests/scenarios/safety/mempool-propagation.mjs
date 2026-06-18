// Mempool propagation: prepare a tx on the miner (full state), submit the
// signed body via the follower's RPC, verify the miner includes it in a block.
// Tests p2p tx relay — the follower receives the tx and gossips it to the miner.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { Network } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, sign, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, tipInfo,
} from 'lattice-node-sdk/chain'
import { peerCount } from 'lattice-node-sdk/probe'

const ROOT = smokeRoot('mempool-propagation')
const [a, b] = await allocPorts(2, { seed: 29 })

console.log('=== mempool-propagation smoke test ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'miner', port: a.port, rpcPort: a.rpcPort },
    { name: 'relay', port: b.port, rpcPort: b.rpcPort },
  ],
})
const M = net.byName('miner')
const R = net.byName('relay')

M.start()
await M.waitForRPC()
await M.readIdentity()
const minerIdent = await M.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

R.start({ peers: [M] })
await R.waitForRPC()

const info = await chainInfo(M)
const nexusDir = info.nexus

console.log(`\n[1] Wait for peers to connect...`)
await waitFor(async () => (await peerCount(M)) >= 1 && (await peerCount(R)) >= 1,
  'peers connected', { timeoutMs: 15_000 })
console.log(`  peers connected`)

console.log(`\n[2] Mine short burst, wait for relay convergence...`)
await startMining(M, nexusDir)
await sleep(8000)
await stopMining(M, nexusDir)
await awaitMiningQuiesced(M, nexusDir, { timeoutMs: 30_000 })

let mTip = await tipInfo(M)
console.log(`  miner tip: ${nexusDir}@${mTip.height}`)
if (mTip.height < 2) {
  console.error(`  ✗ miner failed to produce blocks`); net.teardown(); process.exit(1)
}

await waitFor(async () => {
  mTip = await tipInfo(M)
  const rt = await tipInfo(R)
  return rt && mTip && rt.tip === mTip.tip ? rt : null
}, 'relay converged', { timeoutMs: 120_000 })
console.log(`  relay converged`)
const minerBal = await getBalance(M, minerAddr, nexusDir)
console.log(`  miner balance: ${minerBal}`)

console.log(`\n[3] Prepare tx on miner, submit via relay node...`)
const recipient = genKeypair()
const nonce = await getNonce(M, minerAddr, nexusDir)

const prep = await M.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -1001 },
    { owner: recipient.address, delta: 1000 },
  ],
})
if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
const { bodyCID, bodyData } = prep.json
const signature = sign(prep.json.signingPreimage ?? bodyCID, minerKP.privateKey)

const relaySubmit = await waitFor(async () => {
  const r = await R.rpc('POST', '/api/transaction', {
    signatures: { [minerKP.publicKey]: signature },
    bodyCID, bodyData, chainPath: [nexusDir],
  })
  if (r.ok) return r
  return JSON.stringify(r.json).includes('unavailable') ? null : r
}, 'relay mempool-ready submit', { timeoutMs: 60_000, intervalMs: 500 })
console.log(`  relay submit: ok=${relaySubmit.ok} ${JSON.stringify(relaySubmit.json).slice(0, 80)}`)
if (!relaySubmit.ok) {
  console.error(`  ✗ submit via relay rejected: ${JSON.stringify(relaySubmit.json)}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`\n[4] Mine on miner, verify tx was included...`)
await startMining(M, nexusDir)
const recvBal = await waitFor(
  async () => {
    const b = await getBalance(M, recipient.address, nexusDir)
    return b >= 1000 ? b : null
  },
  'recipient funded on miner', { timeoutMs: 60_000 },
)
console.log(`  ✓ recipient balance on miner: ${recvBal}`)
console.log(`  tx submitted to relay → relayed to miner → mined into block`)

console.log(`\n✓ mempool-propagation smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
