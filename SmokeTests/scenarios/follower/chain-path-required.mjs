// Gap 8b: Per-process children require full chain paths.
//
// Recursive mining and transaction validation both key child chains by full
// path. A per-process child started WITHOUT --chain-path advertises only
// [specDirectory], so the parent must not treat it as a Nexus child candidate.
// Restarting the same child WITH --chain-path Nexus/SwapTest should make it
// mine and accept full-path transactions.
//
// Test flow:
//   1. Start Nexus + SwapTest WITHOUT --chain-path. Mine Nexus.
//      → Expected: Nexus advances; SwapTest remains at height 0.
//   2. Restart SwapTest WITH --chain-path Nexus/SwapTest.
//      → Expected: SwapTest mines via recursive child candidates.
//   3. Submit a tx to SwapTest with full chainPath ["Nexus","SwapTest"].
//      → Expected: ACCEPTED and confirmed.

import { rmSync, mkdirSync, readFileSync, createWriteStream } from 'node:fs'
import { spawn } from 'node:child_process'
import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'
import { sign } from 'lattice-node-sdk/wallet'
import { genKeypair, computeAddress } from 'lattice-node-sdk'

requireBinary()
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
const ROOT = smokeRoot('chain-path-required')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, swapPorts] = await allocPorts(2)

function startNode(name, { port, rpcPort }, extraArgs = []) {
  const dir = `${ROOT}/${name}`
  mkdirSync(dir, { recursive: true })
  const proc = spawn(BIN, [
    'node', '--port', String(port), '--rpc-port', String(rpcPort),
    '--data-dir', dir, '--no-dns-seeds',
    ...devGenesisArgs(),
    '--min-peer-key-bits', '0',
    ...extraArgs,
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/${name}.log`, { flags: 'a' })
  proc.stdout.pipe(log)
  proc.stderr.pipe(log)
  proc.on('exit', (code) => console.log(`[${name}] exited code=${code}`))
  return { proc, port, rpcPort, dir }
}

async function rpcCall(port, method, path, body, dir = null) {
  try {
    const headers = {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(dir ? rpcAuthHeaders(dir) : {}),
    }
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    })
    return { ok: res.ok, status: res.status, json: await res.json().catch(() => null) }
  } catch { return { ok: false, status: 0, json: null } }
}

async function waitRPC(rpcPort, name, timeoutMs = 30_000) {
  return waitFor(async () => {
    const r = await rpcCall(rpcPort, 'GET', '/api/chain/info')
    return r.ok ? r.json : null
  }, `${name} RPC up`, { timeoutMs, intervalMs: 300 })
}

async function height(rpcPort) {
  const r = await rpcCall(rpcPort, 'GET', '/api/chain/info')
  return r.json?.chains?.[0]?.height ?? 0
}

function pathParam(chainPath) {
  return encodeURIComponent(chainPath.join('/'))
}

async function nonceFor(rpcPort, address, chainPath) {
  const r = await rpcCall(rpcPort, 'GET', `/api/nonce/${address}?chainPath=${pathParam(chainPath)}`)
  return r.json?.nonce ?? 0
}

async function balanceFor(rpcPort, address, chainPath) {
  const r = await rpcCall(rpcPort, 'GET', `/api/balance/${address}?chainPath=${pathParam(chainPath)}`)
  return r.json?.balance ?? 0
}

async function submitTxWithFullPath(swapRpcPort, chainPath, nonce, senderKP, recipientAddr) {
  const prepR = await rpcCall(swapRpcPort, 'POST', '/api/transaction/prepare', {
    chainPath,
    nonce, signers: [computeAddress(senderKP.publicKey)], fee: 500,
    accountActions: [
      { owner: computeAddress(senderKP.publicKey), delta: -510 },
      { owner: recipientAddr, delta: 10 },
    ],
  })
  if (!prepR.ok) return { ok: false, error: prepR.json?.error ?? 'prepare failed' }
  const sig = sign(prepR.json.signingPreimage ?? prepR.json.bodyCID, senderKP.privateKey)
  return rpcCall(swapRpcPort, 'POST', '/api/transaction', {
    bodyCID: prepR.json.bodyCID,
    bodyData: prepR.json.bodyData,
    signatures: { [senderKP.publicKey]: sig },
    chainPath,
  })
}

function startMiner(label) {
  const miner = spawn(MINER_BIN, [
    '--node', `http://127.0.0.1:${nexusPorts.rpcPort}/api`,
    '--rpc-cookie-file', `${ROOT}/Nexus/.cookie`,
    '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
    '--child-rpc-cookie-file', `${ROOT}/SwapTest/.cookie`,
    '--workers', '2', '--batch-size', '2000',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  miner.stdout.pipe(createWriteStream(`${ROOT}/miner.log`, { flags: 'a' }))
  miner.stderr.pipe(createWriteStream(`${ROOT}/miner.log`, { flags: 'a' }))
  miner.on('exit', (code) => console.log(`[miner:${label}] exited code=${code}`))
  return miner
}

async function stopProcess(proc, signal = 'SIGTERM') {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return
  try { proc.kill(signal) } catch { return }
  await Promise.race([
    new Promise(resolve => proc.once('exit', resolve)),
    new Promise(resolve => setTimeout(resolve, 3_000)),
  ])
}

console.log('=== chain-path-required smoke test ===')

// ── [1] Start Nexus, deploy SwapTest WITHOUT --chain-path ─────────────────

console.log('\n[1] Start Nexus, deploy SwapTest (no --chain-path)...')
const nexus = startNode('Nexus', nexusPorts)
await waitRPC(nexusPorts.rpcPort, 'Nexus')
const nexusIdent = JSON.parse(readFileSync(`${ROOT}/Nexus/identity.json`, 'utf8'))
const nexusP2P = `${nexusIdent.publicKey}@127.0.0.1:${nexusPorts.port}`
const infoR = await rpcCall(nexusPorts.rpcPort, 'GET', '/api/chain/info')
const nexusDir = infoR.json.nexus

const deployRes = await rpcCall(nexusPorts.rpcPort, 'POST', '/api/chain/deploy', {
  directory: 'SwapTest',
  parentDirectory: nexusDir,
  initialReward: 1024,
  halvingInterval: 210000,
  targetBlockTime: 200,
  maxStateGrowth: 100000,
  maxBlockSize: 1000000,
  maxTransactionsPerBlock: 100,
  retargetWindow: 120,
  premine: 1000,
  premineRecipient: computeAddress(nexusIdent.publicKey),
  wasmPolicies: [],
}, `${ROOT}/Nexus`)
if (!deployRes.ok) throw new Error(`deploy failed: ${JSON.stringify(deployRes.json)}`)
const { genesisHex, chainP2PAddress: swapPeerOnNexus } = deployRes.json
const fullPath = deployRes.json.chainPath ?? [nexusDir, 'SwapTest']

// Start SwapTest WITHOUT --chain-path (the misconfiguration).
let swapNode = startNode('SwapTest', swapPorts, [
  '--genesis-hex', genesisHex,
  '--chain-directory', 'SwapTest',
  '--subscribe-p2p', nexusP2P,
  '--peer', swapPeerOnNexus || nexusP2P,
  // NOTE: no --chain-path here
])
const noPathInfo = await waitRPC(swapPorts.rpcPort, 'SwapTest')
const noPath = noPathInfo.chains?.[0]?.chainPath ?? []
if (noPath.join('/') === fullPath.join('/')) {
  throw new Error(`SwapTest unexpectedly advertised full path without --chain-path: ${noPath.join('/')}`)
}
console.log(`  SwapTest up without --chain-path; advertised path=${noPath.join('/')}`)

console.log('\n[2] Mine Nexus; no-path SwapTest must not be treated as a child...')
let miner = startMiner('no-path')
await waitFor(async () => {
  const nh = await height(nexusPorts.rpcPort)
  return nh >= 4 ? nh : null
}, 'Nexus height >= 4 while no-path child is ignored', { timeoutMs: 180_000, intervalMs: 500 })
await sleep(1_000)
const noPathHeight = await height(swapPorts.rpcPort)
await stopProcess(miner)
await sleep(500)
if (noPathHeight !== 0) {
  throw new Error(`SwapTest mined without full chain path; height=${noPathHeight}`)
}
console.log('  ✓ Nexus advanced, but no-path SwapTest stayed at height 0')

// ── [3] Restart SwapTest WITH --chain-path ────────────────────────────────

console.log('\n[3] Restart SwapTest WITH --chain-path...')
await stopProcess(swapNode.proc)
await sleep(1000)
swapNode = startNode('SwapTest', swapPorts, [
  '--genesis-hex', genesisHex,
  '--chain-directory', 'SwapTest',
  '--chain-path', fullPath.join('/'),
  '--subscribe-p2p', nexusP2P,
  '--peer', swapPeerOnNexus || nexusP2P,
])
const withPathInfo = await waitRPC(swapPorts.rpcPort, 'SwapTest', 30_000)
const withPath = withPathInfo.chains?.[0]?.chainPath ?? []
if (withPath.join('/') !== fullPath.join('/')) {
  throw new Error(`SwapTest advertised wrong path with --chain-path: ${withPath.join('/')}`)
}
console.log(`  SwapTest restarted with --chain-path ${fullPath.join('/')}`)

console.log('\n[4] Mine full-path SwapTest through recursive child candidates...')
miner = startMiner('with-path')
await waitFor(async () => {
  const sh = await height(swapPorts.rpcPort)
  return sh >= 3 ? sh : null
}, 'SwapTest height >= 3 with --chain-path', { timeoutMs: 180_000, intervalMs: 500 })
console.log(`  ✓ SwapTest height: ${await height(swapPorts.rpcPort)}`)

// ── [5] Submit tx with FULL chainPath — should be accepted ────────────────

console.log('\n[5] Submit tx with full chainPath (expect acceptance with --chain-path)...')
const recipient = genKeypair()
const senderKP = { privateKey: nexusIdent.privateKey, publicKey: nexusIdent.publicKey }
const sender = computeAddress(nexusIdent.publicKey)
const nonce = await nonceFor(swapPorts.rpcPort, sender, fullPath)

const accResult = await submitTxWithFullPath(
  swapPorts.rpcPort,
  fullPath,
  nonce, senderKP, recipient.address
)

if (!accResult.ok) {
  console.error('  ✗ FAIL: tx rejected even with --chain-path')
  console.error(`    Response: ${JSON.stringify(accResult.json)}`)
  await stopProcess(miner); await stopProcess(nexus.proc); await stopProcess(swapNode.proc)
  process.exit(1)
}

await waitFor(async () => {
  const bal = await balanceFor(swapPorts.rpcPort, recipient.address, fullPath)
  return bal >= 10 ? bal : null
}, 'full-path tx confirmed on SwapTest', { timeoutMs: 180_000, intervalMs: 500 })
await stopProcess(miner)
console.log('  ✓ tx accepted and confirmed with --chain-path')
console.log('\n✓ chain-path-required passed.')
await stopProcess(nexus.proc)
await stopProcess(swapNode.proc)
await sleep(500)
process.exit(0)
