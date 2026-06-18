// Privileged control-plane boundary smoke:
//   - every admin route rejects missing auth and query-token auth;
//   - bearer auth reaches the handler;
//   - child-node/register endpoints reject non-loopback URLs;
//   - legacy bare `chain` selectors are rejected on mining routes.

import { rmSync, mkdirSync, readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('privileged-control-plane')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [ports] = await allocPorts(1)
const net = new LatticeNetwork()
net.installSignalHandlers()

console.log('=== privileged-control-plane smoke test ===')

const node = net.add(new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: ports.port,
  rpcPort: ports.rpcPort,
}))
node.start(['--rpc-auth', '--rpc-bind', '127.0.0.1'])

await waitFor(async () => {
  try {
    const r = await fetch(`${node.base}/api/chain/info`)
    return r.status === 200 ? true : null
  } catch { return null }
}, 'node RPC up', { timeoutMs: 30_000, intervalMs: 300 })

const token = readFileSync(`${node.dir}/.cookie`, 'utf8').trim()
const info = await node.chainInfo()
const nexus = info.nexus

async function request(method, path, { auth, body } = {}) {
  const headers = {}
  if (auth === 'bearer') headers.Authorization = `Bearer ${token}`
  if (body !== undefined) headers['content-type'] = 'application/json'
  const sep = path.includes('?') ? '&' : '?'
  const url = auth === 'query'
    ? `${node.base}${path}${sep}token=${encodeURIComponent(token)}`
    : `${node.base}${path}`
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  let json = {}
  try { json = await res.json() } catch {}
  return { ok: res.ok, status: res.status, json }
}

const privilegedRoutes = [
  { label: 'deploy', method: 'POST', path: '/api/chain/deploy', body: {} },
  {
    label: 'register-rpc',
    method: 'POST',
    path: '/api/chain/register-rpc',
    body: { chainPath: [nexus, 'AuthProbe'], endpoint: 'http://127.0.0.1:1' },
  },
  { label: 'template', method: 'POST', path: '/api/chain/template', body: { chainPath: [nexus] } },
  { label: 'submit-work', method: 'POST', path: '/api/chain/submit-work', body: { chainPath: [nexus], workId: 'not-a-cid', nonce: 0 } },
  { label: 'candidate-get', method: 'GET', path: `/api/chain/candidate?chainPath=${encodeURIComponent(nexus)}` },
  { label: 'candidate-post', method: 'POST', path: '/api/chain/candidate', body: { chainPath: [nexus] } },
]

console.log('\n[1] Privileged routes reject missing bearer auth...')
for (const route of privilegedRoutes) {
  const r = await request(route.method, route.path, { body: route.body })
  if (r.status !== 401) {
    throw new Error(`${route.label}: expected 401 without auth, got ${r.status} ${JSON.stringify(r.json)}`)
  }
}
console.log('  ✓ all privileged routes reject unauthenticated calls')

console.log('\n[2] Query tokens do not authenticate privileged routes...')
for (const route of privilegedRoutes) {
  const r = await request(route.method, route.path, { auth: 'query', body: route.body })
  if (r.status !== 401) {
    throw new Error(`${route.label}: expected 401 with ?token=, got ${r.status} ${JSON.stringify(r.json)}`)
  }
}
console.log('  ✓ query-token auth rejected on all privileged routes')

console.log('\n[3] Bearer token reaches handlers...')
for (const route of privilegedRoutes) {
  const r = await request(route.method, route.path, { auth: 'bearer', body: route.body })
  if (r.status === 401 || r.status === 403) {
    throw new Error(`${route.label}: bearer auth did not reach handler (${r.status})`)
  }
}
console.log('  ✓ bearer auth reaches every privileged handler')

console.log('\n[4] Non-loopback SSRF targets are rejected...')
const badURL = 'http://169.254.169.254/latest/meta-data'
const ssrfCases = [
  { label: 'template childNodes', method: 'POST', path: '/api/chain/template', body: { chainPath: [nexus], childNodes: [badURL] } },
  { label: 'candidate childNodes', method: 'POST', path: '/api/chain/candidate', body: { chainPath: [nexus], childNodes: [badURL] } },
  { label: 'register-rpc endpoint', method: 'POST', path: '/api/chain/register-rpc', body: { chainPath: [nexus, 'Evil'], endpoint: badURL } },
]
for (const c of ssrfCases) {
  const r = await request(c.method, c.path, { auth: 'bearer', body: c.body })
  if (r.status !== 400) {
    throw new Error(`${c.label}: expected 400 for non-loopback URL, got ${r.status} ${JSON.stringify(r.json)}`)
  }
}
console.log('  ✓ SSRF targets rejected before outbound fetch/register')

console.log('\n[5] Bare `chain` selectors are rejected on mining routes...')
const bareCases = [
  { label: 'template', method: 'POST', path: '/api/chain/template', body: { chain: nexus } },
  { label: 'candidate', method: 'POST', path: '/api/chain/candidate', body: { chain: nexus } },
  { label: 'submit-work', method: 'POST', path: '/api/chain/submit-work', body: { chain: nexus, workId: 'not-a-cid', nonce: 0 } },
]
for (const c of bareCases) {
  const r = await request(c.method, c.path, { auth: 'bearer', body: c.body })
  if (r.status !== 400 || !String(r.json?.error ?? '').includes('chainPath')) {
    throw new Error(`${c.label}: expected chainPath-only 400, got ${r.status} ${JSON.stringify(r.json)}`)
  }
}
console.log('  ✓ mining routes require chainPath selectors')

console.log('\n✓ privileged-control-plane smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
