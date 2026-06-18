// Environment + binary + port discovery.

import { existsSync } from 'node:fs'
import { createServer } from 'node:net'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')

export const BIN = process.env.LATTICE_NODE_BIN
  || resolve(REPO_ROOT, '.build/debug/LatticeNode')

// The ONE canonical dev Nexus genesis timestamp (2025-03-22), passed to every
// spawned Nexus via --genesis-timestamp. A single fixed constant (not Date.now())
// is the whole point: it is the single source of truth for the dev Nexus, so its
// genesis hash is a stable golden value and every node in a multi-node scenario
// builds the SAME Nexus → same network. (The frozen mainnet/testnet genesis is
// dated at the future flag-day instant, so a node built from it cannot mine
// before launch; this dev value is in the past so dev Nexus nodes mine now.)
//
// Smoke also overrides Nexus timing away from production's one-hour block target.
// Otherwise fast smoke mining drops out of the 120-block retarget window around
// height ~140 and hardens into an unmineable difficulty cliff.
//
// This is ONLY the shared Nexus genesis. A test that wants an independent chain
// deploys a CHILD, which gets its own completely new genesis (its own timestamp,
// hash, and genesis block) at deploy time — child chains are never pinned to this
// Nexus timestamp.
export const DEV_GENESIS_TS = 1742601600000
export const DEV_GENESIS_TARGET_BLOCK_TIME_MS = Number.parseInt(
  process.env.SMOKE_GENESIS_TARGET_BLOCK_TIME_MS ?? '1000',
  10,
)
export const DEV_GENESIS_RETARGET_WINDOW = Number.parseInt(
  process.env.SMOKE_GENESIS_RETARGET_WINDOW ?? '1000',
  10,
)

export function devGenesisArgs(timestamp = DEV_GENESIS_TS) {
  return [
    '--genesis-timestamp', String(timestamp),
    '--genesis-target-block-time', String(DEV_GENESIS_TARGET_BLOCK_TIME_MS),
    '--genesis-retarget-window', String(DEV_GENESIS_RETARGET_WINDOW),
  ]
}

export function requireBinary() {
  if (!existsSync(BIN)) {
    console.error(`lattice-node binary not found at ${BIN}`)
    console.error(`build it with: (cd ${REPO_ROOT} && swift build)`)
    process.exit(1)
  }
}

// Each scenario gets its own ROOT (set by run.mjs per-test, or defaulted for
// standalone runs). Per-test isolation is the contract.
export function smokeRoot(defaultName) {
  return process.env.SMOKE_ROOT || `/tmp/smoke-${defaultName}`
}

const CONFIGURED_PORT_BASE = Number.parseInt(process.env.SMOKE_PORT_BASE ?? '', 10)
const CONFIGURED_PORT_SLICE = Number.parseInt(process.env.SMOKE_PORT_SLICE ?? '200', 10)
const USE_CONFIGURED_PORT_SLICE = Number.isInteger(CONFIGURED_PORT_BASE) && CONFIGURED_PORT_BASE > 0
let nextConfiguredPort = CONFIGURED_PORT_BASE

// Ask the OS for a free port. Returns immediately after the probe server
// releases it; used for standalone scenario runs that are not launched by
// run.mjs with a deterministic per-scenario port slice.
function findOsAssignedFreePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer()
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address()
      srv.close(() => resolve(port))
    })
    srv.on('error', reject)
  })
}

function canBindPort(port) {
  return new Promise((resolve) => {
    const srv = createServer()
    srv.once('error', () => resolve(false))
    srv.listen(port, '127.0.0.1', () => {
      srv.close(() => resolve(true))
    })
  })
}

async function findFreePort() {
  if (!USE_CONFIGURED_PORT_SLICE) return findOsAssignedFreePort()

  const end = CONFIGURED_PORT_BASE + CONFIGURED_PORT_SLICE
  while (nextConfiguredPort < end) {
    const port = nextConfiguredPort++
    if (await canBindPort(port)) return port
  }
  throw new Error(`exhausted smoke port slice ${CONFIGURED_PORT_BASE}-${end - 1}`)
}

// Allocate `count` (p2p, rpc) port pairs.
// The `seed` parameter is accepted for backward-compat but ignored.
export async function allocPorts(count, _opts = {}) {
  const results = []
  for (let i = 0; i < count; i++) {
    const port = await findFreePort()
    const rpcPort = await findFreePort()
    results.push({ port, rpcPort })
  }
  return results
}
