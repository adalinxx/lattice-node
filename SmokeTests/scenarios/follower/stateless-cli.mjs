// Stateless-mode CLI surface:
//   `node --stateless` boots, logs "(stateless)", and serves RPC.
// (The old `--stateless --mine` rejection check is gone — the node no longer
// has a --mine flag; block production runs in the external lattice-miner.)

import { spawn } from 'node:child_process'
import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot, BIN, requireBinary } from 'lattice-node-sdk/env'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'

requireBinary()
const ROOT = smokeRoot('stateless-cli')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 7 })
const DIR = `${ROOT}/s`

console.log('=== stateless-mode CLI smoke test ===')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(DIR, { recursive: true })

console.log('\n[1] `--stateless` boots cleanly and RPC responds...')
const args = [
  'node', '--port', String(port), '--rpc-port', String(rpcPort),
  '--data-dir', DIR, '--no-dns-seeds', '--stateless',
  // Skip identity-key PoW grinding: at the 24-bit mainnet default a cold
  // node grinds for ~1min before RPC binds, blowing the 30s wait. Every
  // other node-spawning scenario passes 0 for the same reason.
  '--min-peer-key-bits', '0',
]
console.log(`  ${BIN} ${args.join(' ')}`)
const p = spawn(BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
let outBuf = ''
p.stdout.on('data', (d) => { outBuf += d.toString() })
p.stderr.on('data', (d) => { outBuf += d.toString() })
process.on('exit', () => { try { p.kill('SIGTERM') } catch {} })

await waitFor(async () => {
  try {
    const res = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)
    return res.ok ? true : null
  } catch { return null }
}, 'stateless node RPC up', { timeoutMs: 30_000, intervalMs: 500 })
console.log('  ✓ stateless node RPC up')

if (!outBuf.includes('(stateless)')) {
  console.error('  ✗ startup log missing "(stateless)" marker')
  console.log(outBuf.slice(0, 2000))
  p.kill('SIGTERM'); process.exit(1)
}
console.log('  ✓ log contains "(stateless)"')

const info = await (await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)).json()
if (!info.nexus) {
  console.error('  ✗ /api/chain/info missing nexus:', info)
  p.kill('SIGTERM'); process.exit(1)
}
console.log(`  ✓ /api/chain/info nexus=${info.nexus}`)

p.kill('SIGTERM')
await sleep(500)
console.log('\n✓ stateless CLI surface works end-to-end.')
process.exit(0)
