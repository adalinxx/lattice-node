// Duplicate edge-label isolation:
// `Payments` under Nexus/Alpha and `Payments` under Nexus/Beta are distinct
// chains. Storage, mempools, balances, and RPC chain paths must key by the full
// route, not the leaf directory.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, genKeypair, sign } from 'lattice-node-sdk'

const ROOT = smokeRoot('duplicate-edge-label-isolation')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, alphaPorts, betaPorts, alphaPayPorts, betaPayPorts] = await allocPorts(5)
const ALPHA = 'Alpha'
const BETA = 'Beta'
const LEAF = 'Payments'
const PREMINE = 10_000
const FEE = 1

console.log('=== duplicate-edge-label-isolation smoke test ===')

const net = new LatticeNetwork()
net.installSignalHandlers()

const nexus = net.add(new LatticeNode({
  name: 'nexus',
  dir: `${ROOT}/nexus`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
}))
nexus.start()
await nexus.waitForRPC()

const rootInfo = await nexus.chainInfo()
const nexusDir = rootInfo.nexus
const funder = genKeypair()
const alphaRecipient = genKeypair()
const betaRecipient = genKeypair()

console.log('\n[1] Deploy sibling parents and duplicate `Payments` leaves...')
const alpha = net.add(await nexus.spawnChild({
  directory: ALPHA,
  parentDirectory: nexusDir,
  ports: alphaPorts,
  initialReward: 100,
  premine: 0,
}))
const beta = net.add(await nexus.spawnChild({
  directory: BETA,
  parentDirectory: nexusDir,
  ports: betaPorts,
  initialReward: 100,
  premine: 0,
}))
const alphaPayments = net.add(await alpha.spawnChild({
  directory: LEAF,
  name: 'AlphaPayments',
  ports: alphaPayPorts,
  initialReward: 100,
  premine: PREMINE,
  premineRecipient: funder.address,
}))
const betaPayments = net.add(await beta.spawnChild({
  directory: LEAF,
  name: 'BetaPayments',
  ports: betaPayPorts,
  initialReward: 100,
  premine: PREMINE,
  premineRecipient: funder.address,
}))

const alphaPath = [nexusDir, ALPHA, LEAF]
const betaPath = [nexusDir, BETA, LEAF]
const miner = net.addMiner(new LatticeMiner(nexus, [alpha, beta, alphaPayments, betaPayments], { workers: 2 }))

console.log('\n[2] Mine all chains through the recursive per-process coordinator...')
await miner.mineUntil(async () => {
  const [ah, bh, aph, bph] = await Promise.all([
    alpha.height(ALPHA),
    beta.height(BETA),
    alphaPayments.height(LEAF),
    betaPayments.height(LEAF),
  ])
  return ah >= 2 && bh >= 2 && aph >= 2 && bph >= 2 ? { ah, bh, aph, bph } : null
}, {
  desc: 'duplicate leaf chains advance independently',
  timeoutMs: 180_000,
  progress: async () => [
    await alpha.height(ALPHA),
    await beta.height(BETA),
    await alphaPayments.height(LEAF),
    await betaPayments.height(LEAF),
  ].join(':'),
})
await miner.stop()
await alphaPayments.awaitQuiesced(LEAF)
await betaPayments.awaitQuiesced(LEAF)

console.log('\n[3] Spend on each duplicate leaf with the same signer nonce...')
const alphaNonce = await alphaPayments.nonce(funder.address, LEAF)
const betaNonce = await betaPayments.nonce(funder.address, LEAF)
if (alphaNonce !== betaNonce) {
  throw new Error(`expected duplicate leaves to expose independent matching nonces, got alpha=${alphaNonce} beta=${betaNonce}`)
}
const alphaFunderBefore = await alphaPayments.balance(funder.address, LEAF)
const betaFunderBefore = await betaPayments.balance(funder.address, LEAF)
if (alphaFunderBefore <= 0 || betaFunderBefore <= 0) {
  throw new Error(`expected duplicate leaves to premine funder independently, got alpha=${alphaFunderBefore} beta=${betaFunderBefore}`)
}

const alphaSpend = 111
const betaSpend = 222
const txA = await alphaPayments.submitTx({
  chainPath: alphaPath,
  nonce: alphaNonce,
  signers: [funder.address],
  fee: FEE,
  accountActions: [
    { owner: funder.address, delta: -(alphaSpend + FEE) },
    { owner: alphaRecipient.address, delta: alphaSpend },
  ],
}, LEAF, funder)
if (!txA.ok) throw new Error(`alpha Payments tx failed: ${JSON.stringify(txA)}`)

const txB = await betaPayments.submitTx({
  chainPath: betaPath,
  nonce: betaNonce,
  signers: [funder.address],
  fee: FEE,
  accountActions: [
    { owner: funder.address, delta: -(betaSpend + FEE) },
    { owner: betaRecipient.address, delta: betaSpend },
  ],
}, LEAF, funder)
if (!txB.ok) throw new Error(`beta Payments tx failed: ${JSON.stringify(txB)}`)

await miner.mineUntil(async () => {
  const [ab, bb] = await Promise.all([
    alphaPayments.balance(alphaRecipient.address, LEAF),
    betaPayments.balance(betaRecipient.address, LEAF),
  ])
  return ab >= alphaSpend && bb >= betaSpend ? { ab, bb } : null
}, {
  desc: 'duplicate leaf transactions confirm',
  timeoutMs: 180_000,
  progress: async () => `${await alphaPayments.height(LEAF)}:${await betaPayments.height(LEAF)}`,
})
await miner.stop()
await alphaPayments.awaitQuiesced(LEAF)
await betaPayments.awaitQuiesced(LEAF)

console.log('\n[4] Verify balances did not bleed across duplicate leaves...')
const alphaRecipientOnAlpha = await alphaPayments.balance(alphaRecipient.address, LEAF)
const alphaRecipientOnBeta = await betaPayments.balance(alphaRecipient.address, LEAF)
const betaRecipientOnAlpha = await alphaPayments.balance(betaRecipient.address, LEAF)
const betaRecipientOnBeta = await betaPayments.balance(betaRecipient.address, LEAF)

if (alphaRecipientOnAlpha !== alphaSpend || betaRecipientOnBeta !== betaSpend) {
  throw new Error(`expected recipient balances ${alphaSpend}/${betaSpend}, got ${alphaRecipientOnAlpha}/${betaRecipientOnBeta}`)
}
if (alphaRecipientOnBeta !== 0 || betaRecipientOnAlpha !== 0) {
  throw new Error(`duplicate leaf state leaked: alphaRecipientOnBeta=${alphaRecipientOnBeta} betaRecipientOnAlpha=${betaRecipientOnAlpha}`)
}

const alphaFunder = await alphaPayments.balance(funder.address, LEAF)
const betaFunder = await betaPayments.balance(funder.address, LEAF)
if (alphaFunder !== alphaFunderBefore - alphaSpend - FEE || betaFunder !== betaFunderBefore - betaSpend - FEE) {
  throw new Error(`funder balances not independently tracked: alpha=${alphaFunder} beta=${betaFunder}`)
}
console.log('  ✓ duplicate leaf balances are isolated by full chain path')

console.log('\n[5] Replay an Alpha/Payments envelope through Beta/Payments (expect rejection)...')
const replayRecipient = genKeypair()
const replaySpend = 77
const alphaReplayNonce = await alphaPayments.nonce(funder.address, LEAF)
const alphaReplayRecipientBefore = await alphaPayments.balance(replayRecipient.address, LEAF)
const alphaFunderBeforeReplay = await alphaPayments.balance(funder.address, LEAF)
const betaReplayRecipientBefore = await betaPayments.balance(replayRecipient.address, LEAF)
const betaRecipientBeforeReplay = await betaPayments.balance(betaRecipient.address, LEAF)
if (alphaReplayRecipientBefore !== 0 || betaReplayRecipientBefore !== 0 || betaRecipientBeforeReplay !== betaSpend) {
  throw new Error(`unexpected baseline before replay: alphaReplayRecipient=${alphaReplayRecipientBefore} betaReplayRecipient=${betaReplayRecipientBefore} betaRecipient=${betaRecipientBeforeReplay}`)
}
const prep = await alphaPayments.rpc('POST', '/api/transaction/prepare', {
  chainPath: alphaPath,
  nonce: alphaReplayNonce,
  signers: [funder.address],
  fee: FEE,
  accountActions: [
    { owner: funder.address, delta: -(replaySpend + FEE) },
    { owner: replayRecipient.address, delta: replaySpend },
  ],
})
if (!prep.ok) throw new Error(`prepare Alpha/Payments replay tx failed: ${JSON.stringify(prep.json)}`)
const signature = sign(prep.json.signingPreimage ?? prep.json.bodyCID, funder.privateKey)
const alphaEnvelope = {
  signatures: { [funder.publicKey]: signature },
  bodyCID: prep.json.bodyCID,
  bodyData: prep.json.bodyData,
}
const replay = await betaPayments.rpc('POST', '/api/transaction', {
  ...alphaEnvelope,
  chainPath: betaPath,
})
const replayError = String(replay.json?.error ?? replay.json?.message ?? '')
if (replay.ok || replay.status !== 400 || replay.json?.accepted !== false || !replayError.includes('chainPath')) {
  throw new Error(`Alpha/Payments replay rejected for wrong reason: status=${replay.status} body=${JSON.stringify(replay.json)}`)
}
const accepted = await alphaPayments.rpc('POST', '/api/transaction', {
  ...alphaEnvelope,
  chainPath: alphaPath,
})
if (!accepted.ok || accepted.json?.accepted === false) {
  throw new Error(`original Alpha/Payments envelope was rejected: ${JSON.stringify(accepted.json)}`)
}
await miner.mineUntil(async () => {
  const [alphaReplayBalance, alphaFunderBalance, betaReplayBalance, betaLegitBalance] = await Promise.all([
    alphaPayments.balance(replayRecipient.address, LEAF),
    alphaPayments.balance(funder.address, LEAF),
    betaPayments.balance(replayRecipient.address, LEAF),
    betaPayments.balance(betaRecipient.address, LEAF),
  ])
  return alphaReplayBalance === alphaReplayRecipientBefore + replaySpend &&
    alphaFunderBalance === alphaFunderBeforeReplay - replaySpend - FEE &&
    betaReplayBalance === betaReplayRecipientBefore &&
    betaLegitBalance === betaSpend
    ? { alphaReplayBalance, alphaFunderBalance, betaReplayBalance, betaLegitBalance }
    : null
}, {
  desc: 'Alpha/Payments replay positive control confirms without Beta leakage',
  timeoutMs: 120_000,
  progress: async () => {
    const [ah, bh, br] = await Promise.all([
      alphaPayments.height(LEAF),
      betaPayments.balance(betaRecipient.address, LEAF),
      betaPayments.balance(replayRecipient.address, LEAF),
    ])
    return `${ah}:betaRecipient=${bh}:betaReplay=${br}`
  },
})
await miner.stop()
await alphaPayments.awaitQuiesced(LEAF)
await betaPayments.awaitQuiesced(LEAF)
const alphaReplayRecipientAfter = await alphaPayments.balance(replayRecipient.address, LEAF)
const alphaFunderAfterReplay = await alphaPayments.balance(funder.address, LEAF)
const betaReplayRecipientAfter = await betaPayments.balance(replayRecipient.address, LEAF)
const betaRecipientAfterReplay = await betaPayments.balance(betaRecipient.address, LEAF)
if (alphaReplayRecipientAfter !== alphaReplayRecipientBefore + replaySpend ||
    alphaFunderAfterReplay !== alphaFunderBeforeReplay - replaySpend - FEE) {
  throw new Error(`Alpha/Payments replay positive control applied incorrectly: recipient ${alphaReplayRecipientBefore}->${alphaReplayRecipientAfter}, funder ${alphaFunderBeforeReplay}->${alphaFunderAfterReplay}`)
}
if (betaReplayRecipientAfter !== betaReplayRecipientBefore || betaRecipientAfterReplay !== betaSpend) {
  throw new Error(`Beta/Payments changed after replay rejection: replayRecipient ${betaReplayRecipientBefore}->${betaReplayRecipientAfter}, betaRecipient=${betaRecipientAfterReplay}`)
}
console.log('  ✓ duplicate-leaf replay rejected; original Alpha/Payments tx confirmed')

console.log('\n[6] Verify each parent advertises its own Payments endpoint...')
for (const [label, node, expectedPath] of [
  ['AlphaPayments', alphaPayments, alphaPath],
  ['BetaPayments', betaPayments, betaPath],
]) {
  const info = await node.chainInfo()
  if (!Array.isArray(info.chains) || info.chains.length !== 1) {
    throw new Error(`${label} chain/info should contain exactly one chain: ${JSON.stringify(info.chains)}`)
  }
  const entry = info.chains[0]
  if (entry.directory !== LEAF || entry.chainPath?.join('/') !== expectedPath.join('/')) {
    throw new Error(`${label} owns wrong chain path: ${JSON.stringify(entry)}`)
  }
}
const alphaMap = await alpha.rpc('GET', '/api/chain/map')
const betaMap = await beta.rpc('GET', '/api/chain/map')
if (alphaMap.json?.[alphaPath.join('/')] !== alphaPayments.base) {
  throw new Error(`Alpha map missing ${alphaPath.join('/')}: ${JSON.stringify(alphaMap.json)}`)
}
if (betaMap.json?.[betaPath.join('/')] !== betaPayments.base) {
  throw new Error(`Beta map missing ${betaPath.join('/')}: ${JSON.stringify(betaMap.json)}`)
}
if (alphaMap.json?.[betaPath.join('/')] || betaMap.json?.[alphaPath.join('/')]) {
  throw new Error(`duplicate leaf maps bled across parents: alpha=${JSON.stringify(alphaMap.json)} beta=${JSON.stringify(betaMap.json)}`)
}
console.log('  ✓ duplicate leaf RPC maps remain parent-relative')

console.log('\n✓ duplicate-edge-label-isolation smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
