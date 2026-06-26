// Gap 1a: Parent chain reorgs while per-process child process is live.
//
// When A (Nexus) adopts a longer fork from C, the per-process SwapTest
// node must not roll back its own proof-validated state. Parent canonicity
// is orthogonal to child-chain validity.
//
// We avoid restarting A (which has port-rebind issues on macOS due to
// SwapTest holding sub-chain ports) by instead restarting C with --peer A
// so that C connects to A and gossips its heavier chain to A.

import { rmSync, mkdirSync, readFileSync, createWriteStream } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
import { sleep, waitFor, waitForProgress } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'

requireBinary()
const ROOT = smokeRoot('per-process-parent-reorg')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [aPorts, cPorts, swapPorts] = await allocPorts(3)
const allProcs = []

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
  allProcs.push(proc)
  return { proc, port, rpcPort, dir }
}

// The node never mines in-process — spawn the external coordinator bound to
// it over RPC. Returns the proc;
// kill it to stop producing.
function startMiner({ rpcPort, dir }) {
  const proc = spawn(MINER_BIN, [
    '--node', `http://127.0.0.1:${rpcPort}/api`,
    '--identity-file', `${dir}/identity.json`,
    '--rpc-cookie-file', `${dir}/.cookie`,
    '--workers', '2', '--batch-size', '2000',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/miner.log`, { flags: 'a' })
  proc.stdout.pipe(log); proc.stderr.pipe(log)
  allProcs.push(proc)
  return proc
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
  allProcs.push(proc)
  return proc
}

async function rpc(port, method, path, body, dir = null) {
  try {
    const headers = {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(dir ? rpcAuthHeaders(dir) : {}),
    }
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method, headers,
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

function teardown() {
  allProcs.forEach(p => { try { p?.kill('SIGTERM') } catch {} })
}

console.log('=== per-process-parent-reorg smoke test ===')

// ── [1] Mine Nexus-A + SwapTest to height 5 ──────────────────────────────

console.log('\n[1] Start Nexus-A, deploy SwapTest, mine to height 5...')
const A = startNode('A', aPorts)
await waitRPC(aPorts.rpcPort, 'A')
const aIdent = JSON.parse(readFileSync(`${ROOT}/A/identity.json`, 'utf8'))
const aNexusP2P = `${aIdent.publicKey}@127.0.0.1:${aPorts.port}`
const aP2P = aNexusP2P
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

const swapNode = startNode('SwapTest', swapPorts, [
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
allProcs.push(miner1)
miner1.stdout.pipe(createWriteStream(`${ROOT}/miner1.log`))
miner1.stderr.pipe(createWriteStream(`${ROOT}/miner1.log`, { flags: 'a' }))

await waitFor(async () => {
  const [nh, sh] = await Promise.all([height(aPorts.rpcPort), height(swapPorts.rpcPort)])
  return nh >= 5 && sh >= 5 ? [nh, sh] : null
}, 'height 5 both chains', { timeoutMs: 90_000, intervalMs: 500 })
miner1.kill('SIGTERM')
await sleep(500)

const preSH = await height(swapPorts.rpcPort)
const preNH = await height(aPorts.rpcPort)
console.log(`  ✓ Before reorg: Nexus@${preNH} SwapTest@${preSH}`)

// ── [2] Boot C (shares A's genesis), partition, mine longer fork ──────────

console.log('\n[2] C syncs A\'s genesis, then mines longer fork independently...')
// C must share A's genesis block to be able to reorg A.
const C = startNode('C', cPorts, ['--peer', aNexusP2P])
await waitRPC(cPorts.rpcPort, 'C')
// Wait for C to sync A's full chain.
await waitFor(async () => {
  const ct = await getTip(cPorts.rpcPort)
  const at = await getTip(aPorts.rpcPort)
  return ct === at && ct !== '' ? ct : null
}, 'C synced from A', { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  C synced at height ${await height(cPorts.rpcPort)}`)

// Stop C and restart isolated (same data dir, no peers = mines independently).
const cProc0 = C.proc
C.proc.kill('SIGTERM')
await new Promise(r => { cProc0.once('exit', r) })
await sleep(1000)

const Ciso = startNode('C', cPorts)  // fresh restart, no --peer
await waitRPC(cPorts.rpcPort, 'Ciso', 20_000)

// Mine C to a much longer chain (> preNH + 5 blocks).
const cMiner = startMiner(Ciso)
await waitForProgress(
  async () => height(cPorts.rpcPort),
  (ch) => ch > preNH + 5,
  `C height > ${preNH + 5}`, { stallMs: 60_000, intervalMs: 500 })
cMiner.kill('SIGTERM')
const cTip = await getTip(cPorts.rpcPort)
const cH = await height(cPorts.rpcPort)
console.log(`  C fork: Nexus@${cH} tip=${cTip.slice(0, 12)}…`)

// ── [3] Heal: restart C with --peer A ────────────────────────────────────

console.log('\n[3] Heal: restart Ciso with --peer A so C gossips heavier chain to A...')
// Kill Ciso and restart with A as peer.
// Ciso runs on cPorts — nothing else is connected to cPorts, so restart is clean.
const cisoProc = Ciso.proc
Ciso.proc.kill('SIGTERM')
await new Promise(r => { cisoProc.once('exit', r) })
await sleep(1000)

const C2 = startNode('C', cPorts, ['--peer', aP2P])
await waitRPC(cPorts.rpcPort, 'C2', 20_000)

// Mine one new block on C2 so it gossips a fresh chainAnnounce to A.
// The first announce on connect may fail to resolve block data (Ivy not yet
// established), adding the tip to A's failedSyncTips. A new block gives A
// a fresh tip that bypasses the failed-tip cache and triggers a clean sync.
const c2Miner = startMiner(C2)
await waitForProgress(
  async () => height(cPorts.rpcPort),
  (ch) => ch > cH,
  'C2 mined new block', { stallMs: 20_000, intervalMs: 300 })
c2Miner.kill('SIGTERM')
console.log(`  C2 at height ${await height(cPorts.rpcPort)}, gossipping to A...`)

// A sees C2's heavier chain and syncs.
await waitFor(async () => {
  const aTip = await getTip(aPorts.rpcPort)
  return aTip === (await getTip(cPorts.rpcPort)) ? aTip : null
}, "A converged with C2", { timeoutMs: 90_000, intervalMs: 2000 })
const postNH = await height(aPorts.rpcPort)
console.log(`  ✓ A reorged to C's fork: Nexus@${postNH}`)

// Allow SwapTest extractor time to process the reorg.
await sleep(5000)

// ── [4] Verify SwapTest state after reorg ────────────────────────────────

const observedSH = await height(swapPorts.rpcPort)
console.log(`\n[4] SwapTest: before reorg=${preSH} observed after reorg=${observedSH}`)

if (observedSH < preSH) {
  console.error(`  ✗ FAILURE: SwapTest height rolled back after parent reorg!`)
  teardown(); process.exit(1)
}

console.log(`  ✓ SwapTest did not roll back across parent reorg`)

console.log('\n[5] Mine on the post-reorg parent and require SwapTest progress...')
const postReorgMiner = startMergedMiner(A, swapNode, 'miner-post-reorg')
const advancedSH = await waitForProgress(
  async () => height(swapPorts.rpcPort),
  (sh) => sh > preSH,
  `SwapTest height > ${preSH} after parent reorg`, { stallMs: 90_000, intervalMs: 500 })
postReorgMiner.kill('SIGTERM')
await sleep(500)

console.log(`  ✓ SwapTest advanced after parent reorg ${preSH} → ${advancedSH}`)

console.log('\n✓ per-process-parent-reorg passed.')
teardown()
await sleep(500)
process.exit(0)
