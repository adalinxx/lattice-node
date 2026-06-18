// Cookie auth routing regression:
//   - public read endpoints stay public;
//   - privileged endpoints require Authorization: Bearer <cookie>;
//   - ?token= is not accepted as an admin-route credential.

import { rmSync, mkdirSync, readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { sleep } from 'lattice-node-sdk/waitFor'
import { LatticeNode, LatticeNetwork, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('cookie-query-token')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [ports] = await allocPorts(1)

console.log('=== cookie-query-token smoke test ===')

// --rpc-auth is retained for compatibility; cookie auth is now enabled by default.
const net = new LatticeNetwork()
net.installSignalHandlers()
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: ports.port, rpcPort: ports.rpcPort }))
node.start(['--rpc-auth', '--rpc-bind', '127.0.0.1'])
await waitFor(async () => {
  try {
    const r = await fetch(`http://127.0.0.1:${ports.rpcPort}/api/chain/info`)
    return r.status === 200 ? true : null
  } catch { return null }
}, 'node RPC server up', { timeoutMs: 30_000, intervalMs: 300 })

// Read the generated cookie.
const cookiePath = `${ROOT}/node/.cookie`
const token = readFileSync(cookiePath, 'utf8').trim()
console.log(`  Token loaded from cookie (${token.length} chars)`)

async function request(method, path, { auth, body } = {}) {
  const headers = {}
  if (auth === 'bearer') headers['Authorization'] = `Bearer ${token}`
  if (body) headers['content-type'] = 'application/json'
  const sep = path.includes('?') ? '&' : '?'
  const url = auth === 'query' ? `http://127.0.0.1:${ports.rpcPort}${path}${sep}token=${token}`
           : auth === 'wrong'  ? `http://127.0.0.1:${ports.rpcPort}${path}${sep}token=wrongtoken`
           : `http://127.0.0.1:${ports.rpcPort}${path}`
  const r = await fetch(url, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  })
  return { status: r.status, ok: r.ok }
}

// ── [1] Public read endpoint stays public ────────────────────────────────
console.log('\n[1] Unauthenticated GET /api/chain/info → expect 200...')
const noAuth = await request('GET', '/api/chain/info')
if (noAuth.status !== 200) {
  console.error(`  ✗ Expected 200, got ${noAuth.status}`)
  net.teardown(); process.exit(1)
}
console.log('  ✓ public chain info is readable without auth')

// ── [2] ?token= does not authenticate privileged routes ──────────────────
console.log('\n[2] ?token= on POST /api/chain/deploy → expect 401...')
const queryAuth = await request('POST', '/api/chain/deploy', {
  auth: 'query',
  body: {},
})
if (queryAuth.status !== 401) {
  console.error(`  ✗ Expected query-token admin request to return 401, got ${queryAuth.status}`)
  net.teardown(); process.exit(1)
}
console.log('  ✓ query token rejected on admin route')

// ── [3] Bearer token reaches privileged handlers ─────────────────────────
console.log('\n[3] Bearer token on POST /api/chain/deploy → expect handler response, not 401...')
const bearerAuth = await request('POST', '/api/chain/deploy', {
  auth: 'bearer',
  body: {},
})
if (bearerAuth.status === 401) {
  console.error('  ✗ Bearer token was rejected on admin route')
  net.teardown(); process.exit(1)
}
console.log(`  ✓ bearer credential accepted by auth gate (handler returned ${bearerAuth.status})`)

// ── [4] Wrong ?token= still does not affect public reads ─────────────────
console.log('\n[4] Wrong ?token= on public /api/chain/info → expect 200...')
const wrongToken = await request('GET', '/api/chain/info', { auth: 'wrong' })
if (wrongToken.status !== 200) {
  console.error(`  ✗ Public read should ignore wrong query token and return 200, got ${wrongToken.status}`)
  net.teardown(); process.exit(1)
}
console.log('  ✓ public read remains public')

console.log('\n✓ cookie-query-token passed.')
net.teardown()
await sleep(500)
process.exit(0)
