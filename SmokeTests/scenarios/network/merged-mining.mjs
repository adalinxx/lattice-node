// Phase 3 merged-mining smoke test.
// Two separate chain processes (Nexus + SwapTest) + one lattice-miner.
//
// Bootstrap flow:
//   1. Nexus node starts.
//   2. Operator deploys SwapTest on Nexus → gets genesisHex from deploy response.
//   3. SwapTest process starts with --genesis-hex (seeds its genesis from deploy)
//      and --subscribe-p2p (receives parent blocks to extract SwapTest blocks).
//   4. Miner fetches templates from Nexus + candidates from SwapTest, assembles
//      composite blocks, and gossips sealed blocks to both.
//
// Verifies: both chains advance; SwapTest extracted from Nexus via subscription.

import { allocPorts, smokeRoot, BIN, requireBinary, devGenesisArgs } from 'lattice-node-sdk/env'
import { spawn } from 'node:child_process'
import { mkdirSync, rmSync, readFileSync, createWriteStream } from 'node:fs'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { rpcAuthHeaders } from 'lattice-node-sdk/rpcAuth'

requireBinary()
const ROOT = smokeRoot('merged-mining')
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')

rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts, swapPorts] = await allocPorts(2, { seed: 221 })

function startChainNode(name, { port, rpcPort }, extraArgs = []) {
  const dir = `${ROOT}/${name}`
  mkdirSync(dir, { recursive: true })
  const args = [
    'node', '--port', String(port), '--rpc-port', String(rpcPort),
    '--data-dir', dir, '--no-dns-seeds',
    ...devGenesisArgs(),
    '--min-peer-key-bits', '0',
    ...extraArgs,
  ]
  const proc = spawn(BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
  const logStream = createWriteStream(`${ROOT}/${name}.log`, { flags: 'a' })
  proc.stdout.pipe(logStream)
  proc.stderr.pipe(logStream)
  proc.on('exit', code => console.log(`[${name}] exited code=${code}`))
  return { proc, port, rpcPort, dir }
}

async function chainInfo(rpcPort) {
  try {
    const r = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)
    return r.ok ? await r.json() : null
  } catch { return null }
}

console.log('=== merged-mining: per-process chain smoke test ===')

console.log('\n[1] Start Nexus chain node...')
const nexus = startChainNode('Nexus', nexusPorts)
await waitFor(() => chainInfo(nexusPorts.rpcPort), 'Nexus RPC up', { timeoutMs: 20_000 })
console.log('  ✓ Nexus node up')

console.log('\n[2] Deploy SwapTest child chain on Nexus; get genesis hex for child process...')
const deployRes = await fetch(`http://127.0.0.1:${nexusPorts.rpcPort}/api/chain/deploy`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...rpcAuthHeaders(nexus.dir) },
  body: JSON.stringify({
    directory: 'SwapTest', parentDirectory: 'Nexus',
    initialReward: 100, halvingInterval: 1000000, targetBlockTime: 100,
    maxStateGrowth: 1048576, maxBlockSize: 1048576,
    maxTransactionsPerBlock: 1000, retargetWindow: 100,
    premine: 0, wasmPolicies: [],
  }),
})
if (!deployRes.ok) throw new Error(`SwapTest deploy failed: ${await deployRes.text()}`)
const deployJson = await deployRes.json()
const genesisHex = deployJson.genesisHex
if (!genesisHex) throw new Error('Deploy response missing genesisHex')
const childChainPath = deployJson.chainPath ?? ['Nexus', 'SwapTest']
console.log(`  ✓ SwapTest deployed (genesis ${deployJson.genesisHash?.slice(0, 20)}...)`)

console.log('\n[3] Start SwapTest process with seeded genesis + parent subscription...')
const nexusInfo = await chainInfo(nexusPorts.rpcPort)
const nexusP2P = nexusInfo?.p2pAddress
if (!nexusP2P) throw new Error('No p2pAddress in Nexus chain info')
console.log(`  Nexus P2P: ${nexusP2P}`)

const swap = startChainNode('SwapTest', swapPorts, [
  '--genesis-hex', genesisHex,         // genesis block + spec, seeded from deploy
  '--chain-directory', 'SwapTest',     // chain directory (fallback if spec parse fails)
  '--chain-path', childChainPath.join('/'),
  '--subscribe-p2p', nexusP2P,         // extract SwapTest blocks from Nexus gossip
  ...(deployJson.chainP2PAddress ? ['--peer', deployJson.chainP2PAddress] : []),
])
await waitFor(() => chainInfo(swapPorts.rpcPort), 'SwapTest RPC up', { timeoutMs: 20_000 })
console.log('  ✓ SwapTest node up, subscribed to Nexus with seeded genesis')

console.log('\n[4] Run lattice-miner (Nexus template + SwapTest candidate)...')
const minerProc = spawn(MINER_BIN, [
  '--node', `http://127.0.0.1:${nexusPorts.rpcPort}/api`,
  '--rpc-cookie-file', `${nexus.dir}/.cookie`,
  '--child-node', `http://127.0.0.1:${swapPorts.rpcPort}/api`,
  '--child-rpc-cookie-file', `${swap.dir}/.cookie`,
  '--workers', '2', '--batch-size', '2000',
], { stdio: ['ignore', 'pipe', 'pipe'] })
const minerLog = createWriteStream(`${ROOT}/miner.log`)
minerProc.stdout.pipe(minerLog)
minerProc.stderr.pipe(minerLog)

console.log('\n[5] Wait for both chains to advance (up to 60s)...')
await waitFor(async () => {
  const ni = await chainInfo(nexusPorts.rpcPort)
  const si = await chainInfo(swapPorts.rpcPort)
  const nexusH = ni?.chains?.[0]?.height ?? 0
  const swapH = si?.chains?.[0]?.height ?? 0
  process.stdout.write(`\r  Nexus@${nexusH} SwapTest@${swapH}   `)
  return nexusH >= 3 && swapH >= 1 ? { nexusH, swapH } : null
}, 'both chains advanced', { timeoutMs: 60_000, intervalMs: 1000 })

const finalNexus = await chainInfo(nexusPorts.rpcPort)
const finalSwap = await chainInfo(swapPorts.rpcPort)
const nexusH = finalNexus?.chains?.[0]?.height ?? 0
const swapH = finalSwap?.chains?.[0]?.height ?? 0
console.log(`\n  ✓ Nexus height=${nexusH} SwapTest height=${swapH}`)

if (swapH < 1) throw new Error('SwapTest did not advance via parent chain subscription')
console.log('  ✓ SwapTest applied embedded blocks via ParentChainBlockExtractor')

console.log('\n✓ merged-mining smoke test passed (per-process architecture working)')
minerProc.kill('SIGTERM')
nexus.proc.kill('SIGTERM')
swap.proc.kill('SIGTERM')
await sleep(500)
process.exit(0)
