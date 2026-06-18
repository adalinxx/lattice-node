// Gap 1c: Child process reconnects after parent node restarts.
//
// The startParentChainSubscription loop reconnects when directPeerCount == 0,
// polling every 30 seconds. This test verifies that after a parent crash and
// restart, the child process resumes extracting blocks — it does NOT silently
// stop advancing.
//
// Topology: Nexus (process A) → SwapTest (separate process, --subscribe-p2p A)
// Scenario:
//   1. Mine Nexus + SwapTest to height 5 via LatticeMiner.
//   2. Kill and restart Nexus (simulates crash/upgrade).
//   3. Resume mining. Wait up to 90s for SwapTest to advance beyond height 5.
//   4. PASS if SwapTest advances; FAIL if it stays frozen.

import { rmSync, mkdirSync, readFileSync, createWriteStream } from 'node:fs'
import { spawn } from 'node:child_process'
import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'

requireBinary()
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
const ROOT = smokeRoot('parent-restart-reconnect')

rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, swapPorts] = await allocPorts(2)

function startProc(name, { port, rpcPort }, bin, args) {
  const dir = `${ROOT}/${name}`
  mkdirSync(dir, { recursive: true })
  const proc = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/${name}.log`, { flags: 'a' })
  proc.stdout.pipe(log)
  proc.stderr.pipe(log)
  proc.on('exit', (code) => console.log(`[${name}] exited code=${code}`))
  return { proc, port, rpcPort, dir }
}

function logCount(path, needle) {
  try {
    return (readFileSync(path, 'utf8').match(new RegExp(needle, 'g')) ?? []).length
  } catch {
    return 0
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function stopProcAndWait(proc, name, { timeoutMs = 5_000, killTimeoutMs = 2_000 } = {}) {
  if (!proc) return
  const waitForExit = async (ms) => {
    if (proc.exitCode !== null || proc.signalCode !== null) return true
    return Promise.race([
      new Promise(resolve => proc.once('exit', () => resolve(true))),
      sleep(ms).then(() => false),
    ])
  }
  try { proc.kill('SIGTERM') } catch {}
  if (!(await waitForExit(timeoutMs))) {
    try { proc.kill('SIGKILL') } catch {}
    if (!(await waitForExit(killTimeoutMs))) {
      throw new Error(`${name} did not exit after SIGKILL`)
    }
  }
}

function startNexus(extraArgs = []) {
  return startProc('Nexus', nexusPorts, BIN, [
    'node', '--port', String(nexusPorts.port), '--rpc-port', String(nexusPorts.rpcPort),
    '--data-dir', `${ROOT}/Nexus`, '--no-dns-seeds',
    ...devGenesisArgs(),
    '--min-peer-key-bits', '0',
    ...extraArgs,
  ])
}

async function rpc(rpcPort, method, path, body, dir = null) {
  try {
    const headers = {
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(dir ? rpcAuthHeaders(dir) : {}),
    }
    const res = await fetch(`http://127.0.0.1:${rpcPort}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    })
    return { ok: res.ok, json: res.ok ? await res.json().catch(() => null) : null }
  } catch { return { ok: false, json: null } }
}

async function waitRPC(rpcPort, name, timeoutMs = 30_000) {
  return waitFor(async () => {
    const r = await rpc(rpcPort, 'GET', '/api/chain/info')
    return r.ok ? r.json : null
  }, `${name} RPC up`, { timeoutMs, intervalMs: 300 })
}

async function height(rpcPort) {
  const r = await rpc(rpcPort, 'GET', '/api/chain/info')
  return r.json?.chains?.[0]?.height ?? 0
}

async function tip(rpcPort) {
  const r = await rpc(rpcPort, 'GET', '/api/chain/info')
  return r.json?.chains?.[0]?.tip ?? null
}

async function waitStableTip(rpcPort, label, { samples = 3, intervalMs = 500, timeoutMs = 30_000 } = {}) {
  let last = null
  let stable = 0
  return waitFor(async () => {
    const current = await tip(rpcPort)
    if (!current) return null
    if (current === last) {
      stable += 1
    } else {
      last = current
      stable = 1
    }
    return stable >= samples ? current : null
  }, `${label} stable tip`, { timeoutMs, intervalMs })
}

console.log('=== parent-restart-reconnect smoke test ===')

// ── [1] Start Nexus, deploy SwapTest, start SwapTest process ─────────────

console.log('\n[1] Start Nexus, deploy SwapTest...')
let nexus = startNexus()
await waitRPC(nexusPorts.rpcPort, 'Nexus')
const nexusIdent = JSON.parse(readFileSync(`${ROOT}/Nexus/identity.json`, 'utf8'))
const nexusP2P = `${nexusIdent.publicKey}@127.0.0.1:${nexusPorts.port}`
const infoFirst = await rpc(nexusPorts.rpcPort, 'GET', '/api/chain/info')
const nexusDir = infoFirst.json.nexus
console.log(`  Nexus up  nexusDir=${nexusDir}  p2p=${nexusP2P}`)

const deployRes = await rpc(nexusPorts.rpcPort, 'POST', '/api/chain/deploy', {
  directory: 'SwapTest',
  parentDirectory: nexusDir,
  initialReward: 1024,
  halvingInterval: 210000,
  targetBlockTime: 200,
  maxStateGrowth: 100000,
  maxBlockSize: 1000000,
  maxTransactionsPerBlock: 100,
  retargetWindow: 120,
  premine: 0,
  wasmPolicies: [],
}, `${ROOT}/Nexus`)
if (!deployRes.ok) throw new Error(`deploy failed: ${JSON.stringify(deployRes.json)}`)
const { genesisHex, chainP2PAddress: swapPeerOnNexus } = deployRes.json
const swapPath = `${nexusDir}/SwapTest`
console.log(`  SwapTest deployed  genesisHex=${genesisHex?.slice(0, 20)}…  chainP2P=${swapPeerOnNexus}`)

const swap = startProc('SwapTest', swapPorts, BIN, [
  'node', '--port', String(swapPorts.port), '--rpc-port', String(swapPorts.rpcPort),
  '--data-dir', `${ROOT}/SwapTest`, '--no-dns-seeds',
  '--genesis-hex', genesisHex,
  '--chain-directory', 'SwapTest',
  '--chain-path', swapPath,
  '--subscribe-p2p', nexusP2P,
  '--peer', swapPeerOnNexus || nexusP2P,
  // Nexus already passes 0; the SwapTest child omitted it and would grind a
  // 24-bit identity key for ~1min before RPC binds, blowing the 30s wait.
  '--min-peer-key-bits', '0',
])
await waitRPC(swapPorts.rpcPort, 'SwapTest')
await waitFor(() => logCount(`${ROOT}/SwapTest.log`, 'connected to parent peer') >= 1 ? true : null,
  'SwapTest parent subscription connected', { timeoutMs: 30_000, intervalMs: 300 })
const swapEndpoint = `http://127.0.0.1:${swapPorts.rpcPort}`
const swapAuthToken = readFileSync(`${ROOT}/SwapTest/.cookie`, 'utf8').trim()
const registerSwap = await rpc(nexusPorts.rpcPort, 'POST', '/api/chain/register-rpc', {
  chainPath: [nexusDir, 'SwapTest'],
  endpoint: swapEndpoint,
  authToken: swapAuthToken,
}, `${ROOT}/Nexus`)
if (!registerSwap.ok) throw new Error(`register SwapTest RPC failed: ${JSON.stringify(registerSwap.json)}`)
await waitFor(async () => {
  const r = await rpc(nexusPorts.rpcPort, 'GET', '/api/chain/map')
  return r.ok && r.json?.[swapPath] === swapEndpoint ? r.json : null
}, 'Nexus chain/map registered SwapTest route', { timeoutMs: 30_000, intervalMs: 500 })
await sleep(3000)
console.log('  SwapTest up')

// ── [2] Mine to height 5 on both chains ─────────────────────────────────

console.log('\n[2] Mining to height 5 on Nexus + SwapTest...')
const miner = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${nexusPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${ROOT}/Nexus/.cookie`,
  '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
  '--child-rpc-cookie-file', `${ROOT}/SwapTest/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
miner.stdout.pipe(createWriteStream(`${ROOT}/miner.log`))
miner.stderr.pipe(createWriteStream(`${ROOT}/miner.log`, { flags: 'a' }))

await waitFor(async () => {
  const [nh, sh] = await Promise.all([height(nexusPorts.rpcPort), height(swapPorts.rpcPort)])
  return nh >= 5 && sh >= 5 ? { nexus: nh, swap: sh } : null
}, 'height 5 on both chains', { timeoutMs: 180_000, intervalMs: 500 })

await stopProcAndWait(miner, 'parent-restart-reconnect miner')
await waitStableTip(nexusPorts.rpcPort, 'Nexus before restart')
await waitStableTip(swapPorts.rpcPort, 'SwapTest before restart')
const [preNH, preSH] = await Promise.all([height(nexusPorts.rpcPort), height(swapPorts.rpcPort)])
console.log(`  ✓ Before restart: Nexus@${preNH} SwapTest@${preSH}`)

// ── [3] Kill Nexus, wait 2s, restart it ─────────────────────────────────

console.log('\n[3] Killing and restarting Nexus while SwapTest stays live...')
const swapPid = swap.proc.pid
const connectedBeforeRestart = logCount(`${ROOT}/SwapTest.log`, 'connected to parent peer')
const nexusProc0 = nexus.proc
await stopProcAndWait(nexusProc0, 'Nexus')
await sleep(2000)
await waitRPC(swapPorts.rpcPort, 'SwapTest during parent outage', 30_000)
if (!pidAlive(swapPid)) {
  throw new Error(`SwapTest process exited during parent outage (pid=${swapPid})`)
}
console.log(`  SwapTest stayed live during parent outage (pid=${swapPid})`)

// Restart Nexus.
nexus = startNexus()
await waitRPC(nexusPorts.rpcPort, 'Nexus', 30_000)
console.log('  Nexus restarted')

await waitFor(async () => {
  const r = await rpc(nexusPorts.rpcPort, 'GET', '/api/chain/map')
  return r.ok && r.json?.[swapPath] === swapEndpoint ? r.json : null
}, 'Nexus chain/map restored SwapTest route after restart', { timeoutMs: 30_000, intervalMs: 500 })
console.log(`  Nexus chain/map restored ${swapPath} -> ${swapEndpoint}`)

await waitFor(async () => {
  const r = await rpc(nexusPorts.rpcPort, 'POST', '/api/chain/template', {
    chainPath: [nexusDir, 'SwapTest'],
  }, `${ROOT}/Nexus`)
  return r.ok && r.json?.blockHex ? r.json : null
}, 'Nexus proxies restored SwapTest template route with persisted auth', { timeoutMs: 30_000, intervalMs: 500 })
console.log('  Nexus proxied SwapTest template through restored auth token')

await waitFor(() => {
  if (!pidAlive(swapPid)) throw new Error(`SwapTest process exited instead of reconnecting (pid=${swapPid})`)
  return logCount(`${ROOT}/SwapTest.log`, 'connected to parent peer') > connectedBeforeRestart ? true : null
},
  'SwapTest parent subscription reconnected', { timeoutMs: 45_000, intervalMs: 300 })
await sleep(3000)
console.log(`  SwapTest reconnected to restarted Nexus without process restart (pid=${swapPid})`)
await waitStableTip(nexusPorts.rpcPort, 'Nexus after reconnect')
await waitStableTip(swapPorts.rpcPort, 'SwapTest after reconnect')
const restartBaseSH = await height(swapPorts.rpcPort)

// The reconnect loop in startParentChainSubscription polls every 30s.
// Allow up to 45s for the reconnect to fire.

// ── [4] Resume mining and verify SwapTest advances ──────────────────────

console.log('\n[4] Resuming mining, waiting for SwapTest to advance past pre-restart height...')
const miner2 = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${nexusPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${ROOT}/Nexus/.cookie`,
  '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
  '--child-rpc-cookie-file', `${ROOT}/SwapTest/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
miner2.stdout.pipe(createWriteStream(`${ROOT}/miner2.log`))
miner2.stderr.pipe(createWriteStream(`${ROOT}/miner2.log`, { flags: 'a' }))

// The child must advance beyond its pre-restart height. Allow 90s:
// 30s for the reconnect loop + time to mine several blocks.
const result = await waitFor(async () => {
  const sh = await height(swapPorts.rpcPort)
  return sh > restartBaseSH ? sh : null
}, `SwapTest advances past restart baseline ${restartBaseSH}`, { timeoutMs: 90_000, intervalMs: 2000 })

await stopProcAndWait(miner2, 'parent-restart-reconnect miner2')
const [postNH, postSH] = await Promise.all([height(nexusPorts.rpcPort), height(swapPorts.rpcPort)])
console.log(`  ✓ After restart: Nexus@${postNH} SwapTest@${postSH}`)
console.log(`  ✓ SwapTest advanced ${restartBaseSH} → ${result} — child reconnected after parent restart`)

console.log('\n✓ parent-restart-reconnect passed.')
nexus.proc.kill('SIGTERM')
swap.proc.kill('SIGTERM')
await sleep(500)
process.exit(0)
