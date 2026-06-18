// Chain-path replay isolation: a transaction signed for one sibling child chain
// must not be replayable on another sibling with the same account funded.
//
// This covers the spec rule that a chain's identity is its full path, not just
// its local directory, and that the signed TransactionBody chainPath is part of
// replay protection.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair, computeAddress, sign,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('chain-path-replay-isolation')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, alphaPorts, betaPorts] = await allocPorts(3)
const ALPHA = 'Alpha'
const BETA = 'Beta'
const FEE = 1

console.log('=== chain-path replay isolation smoke test ===')

const nexusNode = new LatticeNode({ name: 'nexus', dir: `${ROOT}/nexus`, port: nexusPorts.port, rpcPort: nexusPorts.rpcPort })
const net = new LatticeNetwork()
net.add(nexusNode)
net.installSignalHandlers()

nexusNode.start()
await nexusNode.waitForRPC()
const minerIdent = await nexusNode.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()
const recipient = genKeypair()

const info = await nexusNode.chainInfo()
const nexusDir = info.nexus
const alphaPath = [nexusDir, ALPHA]
const betaPath = [nexusDir, BETA]

console.log(`deploying ${ALPHA} and ${BETA} under ${nexusDir}...`)
const alphaNode = await nexusNode.spawnChild({
  directory: ALPHA,
  parentDirectory: nexusDir,
  ports: alphaPorts,
  initialReward: 512,
  premine: 10_000,
  premineRecipient: minerAddr,
})
const betaNode = await nexusNode.spawnChild({
  directory: BETA,
  parentDirectory: nexusDir,
  ports: betaPorts,
  initialReward: 512,
  premine: 10_000,
  premineRecipient: minerAddr,
})
net.add(alphaNode)
net.add(betaNode)

const miner = new LatticeMiner(nexusNode, [alphaNode, betaNode])
net.addMiner(miner)

async function fundChild(node, directory, chainPath, amount) {
  const nonce = await node.nonce(minerAddr, directory)
  const r = await node.submitTx({
    chainPath,
    nonce,
    signers: [minerAddr],
    fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(amount + FEE) },
      { owner: user.address, delta: amount },
    ],
  }, directory, minerKP)
  if (!r.ok) throw new Error(`fund ${directory} failed: ${JSON.stringify(r)}`)
}

await miner.mineUntil(
  async () => {
    const [alphaHeight, betaHeight] = await Promise.all([
      alphaNode.height(ALPHA),
      betaNode.height(BETA),
    ])
    return alphaHeight >= 3 && betaHeight >= 3
  },
  {
    desc: 'both child chains mining',
    timeoutMs: 90_000,
    progress: async () => `${await alphaNode.height(ALPHA)}:${await betaNode.height(BETA)}`,
  }
)

console.log('\n[1] Fund the same user on both sibling chains...')
await miner.stop()
await alphaNode.awaitQuiesced(ALPHA)
await betaNode.awaitQuiesced(BETA)
await fundChild(alphaNode, ALPHA, alphaPath, 2_000)
await fundChild(betaNode, BETA, betaPath, 2_000)

await miner.mineUntil(
  async () => {
    const [alphaBalance, betaBalance] = await Promise.all([
      alphaNode.balance(user.address, ALPHA),
      betaNode.balance(user.address, BETA),
    ])
    return alphaBalance >= 2_000 && betaBalance >= 2_000
  },
  {
    desc: 'user funded on both siblings',
    timeoutMs: 120_000,
    progress: async () => `${await alphaNode.height(ALPHA)}:${await betaNode.height(BETA)}`,
  }
)
await miner.stop()
await alphaNode.awaitQuiesced(ALPHA)
await betaNode.awaitQuiesced(BETA)

const betaBalanceBefore = await betaNode.balance(user.address, BETA)
console.log(`  user beta balance before replay attempt: ${betaBalanceBefore}`)

console.log('\n[2] Prepare and sign a spend for Alpha...')
const spendAmount = 75
const alphaNonce = await alphaNode.nonce(user.address, ALPHA)
const prep = await alphaNode.rpc('POST', '/api/transaction/prepare', {
  chainPath: alphaPath,
  nonce: alphaNonce,
  signers: [user.address],
  fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(spendAmount + FEE) },
    { owner: recipient.address, delta: spendAmount },
  ],
})
if (!prep.ok) throw new Error(`prepare Alpha spend failed: ${JSON.stringify(prep.json)}`)
const signature = sign(prep.json.signingPreimage ?? prep.json.bodyCID, user.privateKey)
const alphaEnvelope = {
  signatures: { [user.publicKey]: signature },
  bodyCID: prep.json.bodyCID,
  bodyData: prep.json.bodyData,
}

console.log('\n[3] Replay the exact Alpha envelope through Beta (expect rejection)...')
const replay = await betaNode.rpc('POST', '/api/transaction', {
  ...alphaEnvelope,
  chainPath: betaPath,
})
if (replay.ok || replay.json?.accepted) {
  console.error('  ✗ replay was accepted on Beta')
  console.error(`    ${JSON.stringify(replay.json)}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}
console.log(`  ✓ replay rejected: ${JSON.stringify(replay.json)?.slice(0, 120)}`)

console.log('\n[4] Submit the original envelope to Alpha as a positive control...')
const accepted = await alphaNode.rpc('POST', '/api/transaction', {
  ...alphaEnvelope,
  chainPath: alphaPath,
})
if (!accepted.ok || accepted.json?.accepted === false) {
  console.error('  ✗ original Alpha transaction was rejected')
  console.error(`    ${JSON.stringify(accepted.json)}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}

await miner.mineUntil(
  async () => {
    const recipientBalance = await alphaNode.balance(recipient.address, ALPHA)
    return recipientBalance >= spendAmount ? recipientBalance : null
  },
  {
    desc: 'Alpha spend confirmed',
    timeoutMs: 120_000,
    progress: async () => String(await alphaNode.height(ALPHA)),
  }
)
await miner.stop()
await alphaNode.awaitQuiesced(ALPHA)
await betaNode.awaitQuiesced(BETA)

const betaBalanceAfter = await betaNode.balance(user.address, BETA)
if (betaBalanceAfter !== betaBalanceBefore) {
  console.error(`  ✗ Beta balance changed after replay attempt: before=${betaBalanceBefore} after=${betaBalanceAfter}`)
  net.teardown()
  await sleep(500)
  process.exit(1)
}
console.log('  ✓ Alpha spend confirmed and Beta state unchanged')

console.log('\n✓ chain-path replay isolation smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
