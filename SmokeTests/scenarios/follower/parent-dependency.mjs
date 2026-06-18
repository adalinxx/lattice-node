// Per-process parent-dependency smoke test.
//
// Each chain runs as a separate process. Each child process receives:
//   - genesis hex  (from deploy response — includes block + spec bytes)
//   - peer address (the chain's P2P address on the parent node, seeded from deploy)
//   - subscribe-p2p (parent's main P2P for block extraction via ParentChainBlockExtractor)
//
// Topology: Nexus → Mid → Stable (three separate processes per side).
// A side mines all three; B side follows each chain independently.

import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
import { spawn } from 'node:child_process'
import { mkdirSync, rmSync, readFileSync, createWriteStream } from 'node:fs'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'

requireBinary()
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
const ROOT = smokeRoot('parent-dependency')
const TARGET_HEIGHT = 5

rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusA, midA, stableA, nexusB, midB, stableB] = await allocPorts(6)

function startNode(name, { port, rpcPort }, extraArgs = []) {
  const dir = `${ROOT}/${name}`
  mkdirSync(dir, { recursive: true })
  const args = ['node', '--port', String(port), '--rpc-port', String(rpcPort),
    '--data-dir', dir, '--no-dns-seeds',
    ...devGenesisArgs(),
    '--min-peer-key-bits', '0',
    ...extraArgs]
  const proc = spawn(BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
  const log = createWriteStream(`${ROOT}/${name}.log`, { flags: 'a' })
  proc.stdout.pipe(log); proc.stderr.pipe(log)
  proc.on('exit', code => console.log(`[${name}] exited code=${code}`))
  return { proc, port, rpcPort, dir }
}

async function chainInfo(rpcPort) {
  try {
    const r = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)
    return r.ok ? await r.json() : null
  } catch { return null }
}

async function waitRPC(rpcPort, name, timeoutMs = 20_000) {
  return waitFor(() => chainInfo(rpcPort), `${name} RPC up`, { timeoutMs })
}

async function getHeight(rpcPort) {
  const info = await chainInfo(rpcPort)
  return info?.chains?.[0]?.height ?? 0
}

async function getTip(rpcPort) {
  const info = await chainInfo(rpcPort)
  return info?.chains?.[0]?.tip
}

async function waitStableTip(rpcPort, name, { timeoutMs = 30_000, idleMs = 2_000, intervalMs = 500 } = {}) {
  let lastTip = null
  let stableSince = 0
  return waitFor(async () => {
    const tip = await getTip(rpcPort)
    if (!tip) return null
    const now = Date.now()
    if (tip !== lastTip) {
      lastTip = tip
      stableSince = now
      return null
    }
    return now - stableSince >= idleMs ? tip : null
  }, `${name} stable tip`, { timeoutMs, intervalMs })
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

async function deploy(rpcPort, nodeDir, directory, parentDirectory) {
  const r = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/deploy`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...rpcAuthHeaders(nodeDir) },
    body: JSON.stringify({
      directory, parentDirectory,
      initialReward: 100, halvingInterval: 1000000, targetBlockTime: 100,
      maxStateGrowth: 1048576, maxBlockSize: 1048576,
      maxTransactionsPerBlock: 1000, retargetWindow: 100,
      premine: 0, wasmPolicies: [],
    }),
  })
  if (!r.ok) throw new Error(`deploy ${directory} failed: ${await r.text()}`)
  return r.json()
}

console.log('=== parent-dependency: per-process chains ===')

// ── A side ────────────────────────────────────────────────────────────────

console.log('\n[1] Start A/Nexus...')
const aNexus = startNode('A-Nexus', nexusA)
await waitRPC(nexusA.rpcPort, 'A-Nexus')
const aNexusInfo = await chainInfo(nexusA.rpcPort)
const nexusDir = aNexusInfo.nexus
const aNexusP2P = aNexusInfo.p2pAddress
console.log(`  ✓ A/Nexus  p2p=${aNexusP2P}`)

console.log('\n[2] Deploy Mid on A/Nexus, start A/Mid...')
const midDeploy = await deploy(nexusA.rpcPort, aNexus.dir, 'Mid', nexusDir)
if (!midDeploy.genesisHex) throw new Error('Mid deploy missing genesisHex')
// chainP2PAddress = Mid chain's P2P port on A/Nexus — seeded from deploy response
const midPeerOnNexus = midDeploy.chainP2PAddress
console.log(`  Mid deployed  chainP2P=${midPeerOnNexus}`)

const aMid = startNode('A-Mid', midA, [
  '--genesis-hex', midDeploy.genesisHex,  // genesis + spec, no DHT needed
  '--chain-directory', 'Mid',
  '--chain-path', `${nexusDir}/Mid`,
  '--subscribe-p2p', aNexusP2P,           // receive Mid blocks from Nexus gossip
  '--peer', midPeerOnNexus || aNexusP2P,  // sync Mid history from this chain's P2P on A
])
await waitRPC(midA.rpcPort, 'A-Mid')
const aMidP2P = (await chainInfo(midA.rpcPort))?.p2pAddress
console.log(`  ✓ A/Mid  p2p=${aMidP2P}`)

console.log('\n[3] Deploy Stable on A/Mid, start A/Stable...')
const stableDeploy = await deploy(midA.rpcPort, aMid.dir, 'Stable', 'Mid')
if (!stableDeploy.genesisHex) throw new Error('Stable deploy missing genesisHex')
const stablePeerOnMid = stableDeploy.chainP2PAddress
console.log(`  Stable deployed  chainP2P=${stablePeerOnMid}`)

const aStable = startNode('A-Stable', stableA, [
  '--genesis-hex', stableDeploy.genesisHex,
  '--chain-directory', 'Stable',
  '--chain-path', `${nexusDir}/Mid/Stable`,
  '--subscribe-p2p', aMidP2P,              // receive Stable blocks from Mid gossip
  '--peer', stablePeerOnMid || aMidP2P,    // sync Stable history from this chain's P2P on A/Mid
])
await waitRPC(stableA.rpcPort, 'A-Stable')
const aStableP2P = (await chainInfo(stableA.rpcPort))?.p2pAddress
console.log(`  ✓ A/Stable  p2p=${aStableP2P}`)

console.log('\n[4] Mine all three A chains to height ≥ ' + TARGET_HEIGHT + '...')
const minerProc = spawn(MINER_BIN, [
  '--node',       `http://127.0.0.1:${nexusA.rpcPort}/api`,
  '--rpc-cookie-file', `${aNexus.dir}/.cookie`,
  '--child-node', `http://127.0.0.1:${midA.rpcPort}/api`,
  '--child-rpc-cookie-file', `${aMid.dir}/.cookie`,
  '--child-node', `http://127.0.0.1:${stableA.rpcPort}/api`,
  '--child-rpc-cookie-file', `${aStable.dir}/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
const minerLog = createWriteStream(`${ROOT}/miner.log`)
minerProc.stdout.pipe(minerLog); minerProc.stderr.pipe(minerLog)

await waitFor(async () => {
  const [nh, mh, sh] = await Promise.all([
    getHeight(nexusA.rpcPort), getHeight(midA.rpcPort), getHeight(stableA.rpcPort)])
  process.stdout.write(`\r  A: Nexus@${nh} Mid@${mh} Stable@${sh}   `)
  return nh >= TARGET_HEIGHT && mh >= TARGET_HEIGHT && sh >= TARGET_HEIGHT ? true : null
}, `A height ≥ ${TARGET_HEIGHT}`, { timeoutMs: 120_000, intervalMs: 1000 })

await stopProcAndWait(minerProc, 'parent-dependency miner')
// Child chains can still be applying blocks extracted from a just-settled parent.
// Freeze expectations in parent-before-child order so Stable is captured after
// Mid has stopped moving, not while Mid's final block is still propagating.
await waitStableTip(nexusA.rpcPort, 'A/Nexus')
await waitStableTip(midA.rpcPort, 'A/Mid')
await waitStableTip(stableA.rpcPort, 'A/Stable')
const [aNH, aMH, aSH] = await Promise.all([
  getHeight(nexusA.rpcPort), getHeight(midA.rpcPort), getHeight(stableA.rpcPort)])
const [aNT, aMT, aST] = await Promise.all([
  getTip(nexusA.rpcPort), getTip(midA.rpcPort), getTip(stableA.rpcPort)])
console.log(`\n  A frozen: Nexus@${aNH} Mid@${aMH} Stable@${aSH}`)

// ── B side ────────────────────────────────────────────────────────────────

console.log('\n[5] Start B/Nexus and sync parent first...')
const bNexus = startNode('B-Nexus', nexusB, ['--peer', aNexusP2P])
await waitRPC(nexusB.rpcPort, 'B-Nexus')
const bNexusP2P = (await chainInfo(nexusB.rpcPort))?.p2pAddress
// Compare against A's LIVE tip, re-read each iteration — not the snapshot
// captured above. A's merged miner produces Nexus blocks continuously while the
// deeper child chains catch up to TARGET_HEIGHT, so a final in-flight Nexus
// block can land just after waitStableTip's short idle window, making the
// snapshot one block stale. A is stable once its miner is stopped, so B
// converges on A's live tip.
await waitFor(async () => {
  const [bNH, bNT, aLiveNT] = await Promise.all([
    getHeight(nexusB.rpcPort), getTip(nexusB.rpcPort), getTip(nexusA.rpcPort)])
  process.stdout.write(`\r  B/Nexus: ${bNH}   `)
  return bNT && bNT === aLiveNT ? true : null
}, 'B/Nexus synced parent tip', { timeoutMs: 90_000, intervalMs: 2000 })
console.log(`\n  ✓ B/Nexus synced  p2p=${bNexusP2P}`)

console.log('\n[6] Start B/Mid after parent sync...')
const bMid = startNode('B-Mid', midB, [
  '--genesis-hex', midDeploy.genesisHex,
  '--chain-directory', 'Mid',
  '--chain-path', `${nexusDir}/Mid`,
  '--subscribe-p2p', bNexusP2P || aNexusP2P,
  '--peer', aMidP2P || midPeerOnNexus || aNexusP2P,
])
await waitRPC(midB.rpcPort, 'B-Mid')
const bMidP2P = (await chainInfo(midB.rpcPort))?.p2pAddress
await waitFor(async () => {
  const [bMH, bMT, aLiveMT] = await Promise.all([
    getHeight(midB.rpcPort), getTip(midB.rpcPort), getTip(midA.rpcPort)])
  process.stdout.write(`\r  B/Mid: ${bMH}   `)
  return bMT && bMT === aLiveMT ? true : null
}, 'B/Mid synced child tip', { timeoutMs: 90_000, intervalMs: 2000 })
console.log(`\n  ✓ B/Mid synced  p2p=${bMidP2P}`)

console.log('\n[7] Start B/Stable after Mid sync...')
const bStable = startNode('B-Stable', stableB, [
  '--genesis-hex', stableDeploy.genesisHex,
  '--chain-directory', 'Stable',
  '--chain-path', `${nexusDir}/Mid/Stable`,
  '--subscribe-p2p', bMidP2P || aMidP2P,
  '--peer', aStableP2P || stablePeerOnMid || aMidP2P,
])
await waitRPC(stableB.rpcPort, 'B-Stable')
console.log('  ✓ B side up, parent-before-child')

console.log('\n[8] Wait for B to converge on A tips (up to 90s)...')
await waitFor(async () => {
  const [bNT, bMT, bST] = await Promise.all([
    getTip(nexusB.rpcPort), getTip(midB.rpcPort), getTip(stableB.rpcPort)])
  const [bNH, bMH, bSH] = await Promise.all([
    getHeight(nexusB.rpcPort), getHeight(midB.rpcPort), getHeight(stableB.rpcPort)])
  // Live A tips (A is stable post-miner-stop) — see note above.
  const [aLiveNT, aLiveMT, aLiveST] = await Promise.all([
    getTip(nexusA.rpcPort), getTip(midA.rpcPort), getTip(stableA.rpcPort)])
  process.stdout.write(`\r  B: Nexus@${bNH} Mid@${bMH} Stable@${bSH}   `)
  return bNT === aLiveNT && bMT === aLiveMT && bST === aLiveST ? true : null
}, 'B converged on all tips', { timeoutMs: 90_000, intervalMs: 2000 })

console.log(`\n  ✓ B converged: Nexus Mid Stable all match A`)
console.log('✓ parent-dependency per-process test passed.')
;[aNexus, aMid, aStable, bNexus, bMid, bStable].forEach(n => { try { n.proc?.kill?.('SIGTERM') } catch {} })
await sleep(500)
process.exit(0)
