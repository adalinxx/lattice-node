// Mining private-key boundary smoke:
// A template request may contain legacy/private-key-looking fields, but the node
// must ignore them and sign/credit rewards with node-owned material only.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor, waitForProgress, genKeypair, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('mining-key-boundary')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [ports] = await allocPorts(1)
const net = new LatticeNetwork()
net.installSignalHandlers()

console.log('=== mining-key-boundary smoke test ===')

const node = net.add(new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: ports.port,
  rpcPort: ports.rpcPort,
}))
node.start()
await node.waitForRPC()

const info = await node.chainInfo()
const nexus = info.nexus
const ident = await node.readIdentity()
const nodeRewardAddress = computeAddress(ident.publicKey)
const attacker = genKeypair()

const specResp = await node.rpc('GET', `/api/chain/spec?chainPath=${nexus}`)
if (!specResp.ok) throw new Error(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const expectedReward = specResp.json.initialReward

console.log('\n[1] Request template with hostile private-key fields...')
const template = await node.rpc('POST', '/api/chain/template', {
  chainPath: [nexus],
  minerPrivateKey: attacker.privateKey,
  minerPublicKey: attacker.publicKey,
  rewardPrivateKeyHex: attacker.privateKey,
  privateKeyHex: attacker.privateKey,
  rewardPublicKeyHex: attacker.publicKey,
})
if (!template.ok || !template.json?.workId) {
  throw new Error(`template failed: ${template.status} ${JSON.stringify(template.json)}`)
}
console.log(`  ✓ template built with workId=${template.json.workId.slice(0, 20)}...`)

console.log('\n[2] Submit the node-built work...')
const submit = await node.rpc('POST', '/api/chain/submit-work', {
  chainPath: [nexus],
  workId: template.json.workId,
  nonce: 0,
})
if (!submit.ok || submit.json?.accepted !== true) {
  throw new Error(`submit-work failed: ${submit.status} ${JSON.stringify(submit.json)}`)
}
await waitForProgress(async () => node.height(nexus), (h) => h >= 1,
  'submitted work accepted', { stallMs: 30_000, intervalMs: 300 })
console.log('  ✓ node accepted its own sealed work')

console.log('\n[3] Verify rewards went to node-owned identity, not request key...')
const nodeBalance = await node.balance(nodeRewardAddress, nexus)
const attackerBalance = await node.balance(attacker.address, nexus)
if (nodeBalance < expectedReward) {
  throw new Error(`node reward balance ${nodeBalance} < expected reward ${expectedReward}`)
}
if (attackerBalance !== 0) {
  throw new Error(`attacker-controlled request key received balance ${attackerBalance}`)
}
console.log(`  ✓ node reward=${nodeBalance}; attacker reward=${attackerBalance}`)

console.log('\n✓ mining-key-boundary smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
