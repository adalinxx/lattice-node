// External miner quickstart smoke test.
//
// Mirrors the documented production wiring:
//   1. Start a real LatticeNode process.
//   2. Start LatticeMiningCoordinatorTool against that node's RPC /api using
//      the node's RPC cookie.
//   3. Verify the chain advances through the RPC work/submit path.
//   4. Verify the node-owned miner identity receives the expected coinbase
//      rewards from the published chain spec.

import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createWriteStream, existsSync } from 'node:fs'
import { allocPorts, BIN, requireBinary, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'

requireBinary()

const ROOT = smokeRoot('external-miner-quickstart')
const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
if (!existsSync(MINER_BIN)) {
  console.error(`lattice mining coordinator binary not found at ${MINER_BIN}`)
  console.error('build it with: swift build')
  process.exit(1)
}
const [{ port, rpcPort }] = await allocPorts(1, { seed: 231 })

console.log('=== external-miner-quickstart smoke test ===')

const net = Network.fresh({
  root: ROOT,
  nodes: [{ name: 'node', port, rpcPort }],
})

let minerProc = null

function stopMiner() {
  if (!minerProc) return
  try { minerProc.kill('SIGTERM') } catch {}
  minerProc = null
}

function rewardAtBlock(spec, height) {
  const halvings = Math.floor(height / spec.halvingInterval)
  return Math.floor(spec.initialReward / (2 ** halvings))
}

function expectedRewards(spec, fromExclusive, toInclusive) {
  let total = 0
  for (let h = fromExclusive + 1; h <= toInclusive; h++) {
    total += rewardAtBlock(spec, h)
  }
  return total
}

const BASE32 = 'abcdefghijklmnopqrstuvwxyz234567'

function base32Encode(bytes) {
  let bits = 0, value = 0, out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      out += BASE32[(value >>> bits) & 0x1f]
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 0x1f]
  return out
}

function cborEncode(value) {
  const out = []
  function uint(n, major) {
    const mt = major << 5
    if (n < 24) out.push(mt | n)
    else if (n < 256) out.push(mt | 24, n)
    else if (n < 65536) out.push(mt | 25, n >> 8, n & 0xff)
    else out.push(mt | 26, (n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff)
  }
  function enc(v) {
    if (typeof v === 'string') {
      const b = new TextEncoder().encode(v)
      uint(b.length, 3); out.push(...b)
    } else {
      const keys = Object.keys(v).sort((a, b) => {
        const la = new TextEncoder().encode(a).length
        const lb = new TextEncoder().encode(b).length
        return la !== lb ? la - lb : (a < b ? -1 : a > b ? 1 : 0)
      })
      uint(keys.length, 5)
      for (const k of keys) {
        const kb = new TextEncoder().encode(k)
        uint(kb.length, 3); out.push(...kb); enc(v[k])
      }
    }
  }
  enc(value)
  return new Uint8Array(out)
}

function computeAddress(publicKeyHex) {
  const digest = createHash('sha256').update(cborEncode({ key: publicKeyHex })).digest()
  const cid = new Uint8Array(4 + digest.length)
  cid[0] = 0x01; cid[1] = 0x71; cid[2] = 0x12; cid[3] = 0x20
  cid.set(digest, 4)
  return `b${base32Encode(cid)}`
}

async function chainInfo(node) {
  const r = await node.rpc('GET', '/api/chain/info')
  return r.ok ? r.json : null
}

function chainOf(info, dir) {
  return info?.chains?.find(c => c.directory === dir)
}

async function height(node, dir) {
  const info = await chainInfo(node)
  return chainOf(info, dir)?.height ?? 0
}

async function balance(node, address, dir) {
  const r = await node.rpc('GET', `/api/balance/${address}?chainPath=${dir}`)
  if (!r.ok) throw new Error(`balance(${dir}) failed: ${JSON.stringify(r.json)}`)
  return r.json.balance ?? 0
}

async function awaitQuiesced(node, dir, { timeoutMs = 10_000, idleMs = 800 } = {}) {
  const start = Date.now()
  let last = await height(node, dir)
  while (Date.now() - start < timeoutMs) {
    await sleep(idleMs)
    const h = await height(node, dir)
    if (h === last) return h
    last = h
  }
  return last
}

try {
  console.log('\n[1] Start LatticeNode...')
  const node = net.byName('node')
  node.start()
  await node.waitForRPC()
  const info = await chainInfo(node)
  const nexusDir = info.nexus
  const startHeight = await height(node, nexusDir)
  console.log(`  ✓ node RPC up (${nexusDir}@${startHeight})`)

  console.log('\n[2] Read node-owned payout identity and chain economics...')
  const identity = await node.readIdentity()
  const minerAddress = computeAddress(identity.publicKey)
  const startingBalance = await balance(node, minerAddress, nexusDir)
  const specResp = await node.rpc('GET', `/api/chain/spec?chainPath=${nexusDir}`)
  if (!specResp.ok) throw new Error(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
  const spec = specResp.json
  console.log(`  miner=${minerAddress}`)
  console.log(`  reward=${spec.initialReward} halvingInterval=${spec.halvingInterval}`)

  console.log('\n[3] Start LatticeMiningCoordinatorTool with the documented RPC cookie path...')
  minerProc = spawn(MINER_BIN, [
    '--node', `${node.base}/api`,
    '--rpc-cookie-file', `${node.dir}/.cookie`,
    '--workers', '2',
    '--batch-size', '2000',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  const minerLog = createWriteStream(`${ROOT}/miner.log`, { flags: 'a' })
  minerProc.stdout.pipe(minerLog)
  minerProc.stderr.pipe(minerLog)
  minerProc.on('exit', code => console.log(`[external-miner] exited code=${code}`))

  const targetHeight = Math.max(startHeight + 3, 3)
  console.log(`\n[4] Wait for Nexus height >= ${targetHeight} via external work submission...`)
  await waitFor(async () => {
    const h = await height(node, nexusDir)
    process.stdout.write(`\r  ${nexusDir}@${h}   `)
    return h >= targetHeight ? h : null
  }, `${nexusDir} height >= ${targetHeight}`, { timeoutMs: 90_000, intervalMs: 500 })

  stopMiner()
  await awaitQuiesced(node, nexusDir, { timeoutMs: 10_000, idleMs: 800 })

  const finalHeight = await height(node, nexusDir)
  const finalBalance = await balance(node, minerAddress, nexusDir)
  const expectedDelta = expectedRewards(spec, startHeight, finalHeight)
  const actualDelta = finalBalance - startingBalance
  console.log(`\n  final ${nexusDir}@${finalHeight}`)
  console.log(`  payout delta=${actualDelta} expected=${expectedDelta}`)

  if (finalHeight <= startHeight) {
    throw new Error(`height did not advance: ${startHeight} -> ${finalHeight}`)
  }
  if (actualDelta !== expectedDelta) {
    throw new Error(`miner payout mismatch: delta=${actualDelta} expected=${expectedDelta}`)
  }

  console.log('\n✓ external-miner-quickstart smoke test passed.')
  net.teardown()
  await sleep(500)
  process.exit(0)
} catch (e) {
  stopMiner()
  net.teardown()
  await sleep(500)
  throw e
}
