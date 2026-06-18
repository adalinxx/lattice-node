// Gap 2d: Per-process child state after deep parent nexus reorg.
//
// When a deep reorg on the parent (Nexus) replaces blocks that anchored
// SwapTest blocks, the per-process SwapTest child must preserve its own
// proof-validated state. Parent canonicity is orthogonal to child validity.
//
// This test exercises the gap-in-parentView path by:
//   1. Mining Nexus + SwapTest to height 5 (parentView populated).
//   2. Restarting SwapTest (clears in-memory parentView).
//   3. Mining 2 more blocks so SwapTest has height 7, parentView partial.
//   4. Nexus-C has a MUCH longer independent fork (height > 12).
//   5. A connects to C and adopts C's chain (deep reorg).
//   6. SwapTest receives parent blocks from C's chain.
//      Since child validity is proof-based, SwapTest must not roll back merely
//      because the parent canonical branch changed.

import { rmSync, mkdirSync, readFileSync, createWriteStream } from 'node:fs'
import { spawn } from 'node:child_process'
import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'

requireBinary()
const ROOT = smokeRoot('per-process-deep-reorg')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, cPorts, swapPorts] = await allocPorts(3)

function startNode(name, { port, rpcPort }, extraArgs = []) {
  const dir = `${ROOT}/${name}`
  mkdirSync(dir, { recursive: true })
  const proc = spawn(BIN, [
    'node', '--port', String(port), '--rpc-port', String(rpcPort),
    '--data-dir', dir, '--no-dns-seeds',
    ...devGenesisArgs(),
    '--min-peer-key-bits', '0',
    '--finality-confirmations', '999999',
    ...extraArgs,
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/${name}.log`, { flags: 'a' })
  proc.stdout.pipe(log); proc.stderr.pipe(log)
  proc.on('exit', (code) => console.log(`[${name}] exited code=${code}`))
  return { proc, port, rpcPort, dir }
}

async function rpc(port, method, path, body, dir = null) {
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
    return { ok: res.ok, json: await res.json().catch(() => null) }
  } catch { return { ok: false, json: null } }
}

async function waitRPC(rpcPort, name, timeoutMs = 30_000) {
  return waitFor(async () => {
    const r = await rpc(rpcPort, 'GET', '/api/chain/info')
    return r.ok ? r.json : null
  }, `${name} RPC`, { timeoutMs, intervalMs: 300 })
}

async function height(rpcPort) {
  const r = await rpc(rpcPort, 'GET', '/api/chain/info')
  return r.json?.chains?.[0]?.height ?? 0
}

async function getTip(rpcPort) {
  const r = await rpc(rpcPort, 'GET', '/api/chain/info')
  return r.json?.chains?.[0]?.tip ?? ''
}

function startMergedMiner(parent, child, logName) {
  const proc = spawn(MINER_BIN, [
    '--node', `http://127.0.0.1:${parent.rpcPort}/api`,
    '--rpc-cookie-file', `${parent.dir}/.cookie`,
    '--child-node', `http://127.0.0.1:${child.rpcPort}/api`,
    '--child-rpc-cookie-file', `${child.dir}/.cookie`,
    '--workers', '2', '--batch-size', '2000',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/${logName}.log`, { flags: 'a' })
  proc.stdout.pipe(log); proc.stderr.pipe(log)
  return proc
}

async function stopProc(proc, signal = 'SIGTERM') {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return
  proc.kill(signal)
  await Promise.race([
    new Promise(resolve => proc.once('exit', resolve)),
    sleep(5000),
  ])
}

console.log('=== per-process-deep-reorg smoke test ===')

// ── [1] Mine Nexus + SwapTest to height 5 ────────────────────────────────

console.log('\n[1] Start Nexus-A, deploy SwapTest, mine to height 5...')
const A = startNode('A', aPorts)
await waitRPC(aPorts.rpcPort, 'A')
const aIdent = JSON.parse(readFileSync(`${ROOT}/A/identity.json`, 'utf8'))
const aNexusP2P = `${aIdent.publicKey}@127.0.0.1:${aPorts.port}`
const infoA = await rpc(aPorts.rpcPort, 'GET', '/api/chain/info')
const nexusDir = infoA.json.nexus

const deployRes = await rpc(aPorts.rpcPort, 'POST', '/api/chain/deploy', {
  directory: 'SwapTest', parentDirectory: nexusDir,
  initialReward: 1024, halvingInterval: 210000, targetBlockTime: 200,
  maxStateGrowth: 100000, maxBlockSize: 1000000,
  maxTransactionsPerBlock: 100, retargetWindow: 120,
  premine: 0, wasmPolicies: [],
}, `${ROOT}/A`)
if (!deployRes.ok) throw new Error(`deploy failed`)
const { genesisHex, chainP2PAddress: swapPeerOnA } = deployRes.json

let swapNode = startNode('SwapTest', swapPorts, [
  '--genesis-hex', genesisHex,
  '--chain-directory', 'SwapTest',
  '--chain-path', `${nexusDir}/SwapTest`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', swapPeerOnA || aNexusP2P,
])
await waitRPC(swapPorts.rpcPort, 'SwapTest')

const miner1 = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${aPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${ROOT}/A/.cookie`,
  '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
  '--child-rpc-cookie-file', `${ROOT}/SwapTest/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
miner1.stdout.pipe(createWriteStream(`${ROOT}/miner1.log`))
miner1.stderr.pipe(createWriteStream(`${ROOT}/miner1.log`, { flags: 'a' }))

await waitFor(async () => {
  const [nh, sh] = await Promise.all([height(aPorts.rpcPort), height(swapPorts.rpcPort)])
  return nh >= 5 && sh >= 5 ? [nh, sh] : null
}, 'height 5 both chains', { timeoutMs: 90_000, intervalMs: 500 })
await stopProc(miner1)
await sleep(500)
console.log(`  ✓ Nexus@${await height(aPorts.rpcPort)} SwapTest@${await height(swapPorts.rpcPort)}`)

// ── [2] Restart SwapTest — wipes in-memory parentView ────────────────────

console.log('\n[2] Restart SwapTest (clears parentView)...')
const swapProc0 = swapNode.proc
swapNode.proc.kill('SIGTERM')
await new Promise(r => { swapProc0.once('exit', r) })
await sleep(2000)
swapNode = startNode('SwapTest', swapPorts, [
  '--genesis-hex', genesisHex,
  '--chain-directory', 'SwapTest',
  '--chain-path', `${nexusDir}/SwapTest`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', swapPeerOnA || aNexusP2P,
])
await waitRPC(swapPorts.rpcPort, 'SwapTest', 30_000)

// Mine 2 more blocks with LatticeMiner so SwapTest receives some new parent blocks.
// parentView now has ONLY these 2 new parent blocks — the pre-restart blocks are gone.
const miner2 = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${aPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${ROOT}/A/.cookie`,
  '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
  '--child-rpc-cookie-file', `${ROOT}/SwapTest/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
miner2.stdout.pipe(createWriteStream(`${ROOT}/miner2.log`))
miner2.stderr.pipe(createWriteStream(`${ROOT}/miner2.log`, { flags: 'a' }))

const preSH = await height(swapPorts.rpcPort)
const targetNH = (await height(aPorts.rpcPort)) + 2
await waitFor(async () => {
  const nh = await height(aPorts.rpcPort)
  return nh >= targetNH ? nh : null
}, `Nexus height ${targetNH}`, { timeoutMs: 60_000, intervalMs: 500 })
await stopProc(miner2)
await sleep(500)
const forkAHeight = await height(aPorts.rpcPort)
const swapAfterRestart = await height(swapPorts.rpcPort)
console.log(`  ✓ After restart+mine: Nexus@${forkAHeight} SwapTest@${swapAfterRestart}`)

// ── [3] Boot C, mine much longer independent fork ─────────────────────────

console.log('\n[3] Boot C, mine much longer fork (no SwapTest)...')
const C = startNode('C', cPorts)
await waitRPC(cPorts.rpcPort, 'C')
const cMiner = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${cPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${ROOT}/C/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
cMiner.stdout.pipe(createWriteStream(`${ROOT}/minerC.log`))
cMiner.stderr.pipe(createWriteStream(`${ROOT}/minerC.log`, { flags: 'a' }))
await waitFor(async () => {
  const ch = await height(cPorts.rpcPort)
  return ch > forkAHeight + 5 ? ch : null
}, `C height > ${forkAHeight + 5}`, { timeoutMs: 60_000, intervalMs: 500 })
await stopProc(cMiner)
await sleep(500)
const cTip = await getTip(cPorts.rpcPort)
const cH = await height(cPorts.rpcPort)
console.log(`  C fork: Nexus@${cH} tip=${cTip.slice(0, 12)}…`)

// ── [4] Heal: A reorgs to C ────────────────────────────────────────────────

console.log('\n[4] Heal: A connects to C (C wins)...')
const cIdent = JSON.parse(readFileSync(`${ROOT}/C/identity.json`, 'utf8'))
const cP2P = `${cIdent.publicKey}@127.0.0.1:${cPorts.port}`
const aProc0 = A.proc
A.proc.kill('SIGTERM')
await new Promise(r => { aProc0.once('exit', r) })
await sleep(2000)
const A2 = startNode('A', aPorts, ['--peer', cP2P])
await waitRPC(aPorts.rpcPort, 'A', 30_000)
await waitFor(async () => {
  const aTip = await getTip(aPorts.rpcPort)
  return aTip === cTip ? aTip : null
}, "A adopted C's tip", { timeoutMs: 60_000, intervalMs: 2000 })
console.log(`  ✓ A reorged to C: Nexus@${await height(aPorts.rpcPort)}`)

await waitRPC(swapPorts.rpcPort, 'SwapTest still running', 10_000)

// Allow SwapTest extractor time to observe the parent branch change. Parent
// canonicity is orthogonal to child state, so this must not roll SwapTest back.
await sleep(5000)

// ── [5] Verify SwapTest state after deep reorg ────────────────────────────

const observedSH = await height(swapPorts.rpcPort)
console.log(`\n[5] SwapTest height: before-reorg=${swapAfterRestart}, observed after-reorg=${observedSH}`)

if (observedSH < swapAfterRestart) {
  console.error(`  ✗ FAILURE: SwapTest height rolled back after deep parent reorg!`)
  ;[A2.proc, C.proc, swapNode.proc].forEach(p => { try { p?.kill('SIGTERM') } catch {} })
  process.exit(1)
}

console.log(`  ✓ SwapTest did not roll back across deep parent reorg`)

console.log('\n[6] Mine on the post-reorg parent and require SwapTest progress...')
const postReorgMiner = startMergedMiner(A2, swapNode, 'miner-post-reorg')
const advancedSH = await waitFor(async () => {
  const sh = await height(swapPorts.rpcPort)
  return sh > swapAfterRestart ? sh : null
}, `SwapTest height > ${swapAfterRestart} after deep parent reorg`, { timeoutMs: 90_000, intervalMs: 500 })
await stopProc(postReorgMiner)
await sleep(500)

console.log(`  ✓ SwapTest advanced after deep parent reorg ${swapAfterRestart} → ${advancedSH}`)

console.log('\n✓ per-process-deep-reorg passed.')
;[A2.proc, C.proc, swapNode.proc].forEach(p => { try { p?.kill('SIGTERM') } catch {} })
await sleep(500)
process.exit(0)
