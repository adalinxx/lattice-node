// Operator/miner CLI journey — drives the REAL `lattice-node` subcommands an operator
// actually runs, end to end, NOT raw RPC via the SDK. This is the only smoke coverage
// of the CLI layer itself: argument parsing, key-file handling, nonce/fee derivation,
// output formatting, the admin-authed deploy/attach/detach commands, and the offline
// storage-reading commands (status/query/identity). The raw-RPC scenarios exercise the
// endpoints but reimplement this orchestration, so CLI-only bugs (e.g. the swap-sell
// 128-bit-nonce serialization bug) slip past them — exactly the class this catches.
//
// Covers (per operator workflow):
//   wallet+tx : keys generate/address/show -> send -> tx -> (verify)
//   chain     : chain deploy (CLI) -> chain genesis -> chain attach -> chain detach
//   node ops  : status, query height/tip/balance, identity, diag, init
//
// A single Nexus miner funds the CLI-generated funder (coinbase) and confirms the
// send/tx/deploy state txs. status/query/identity read the node's storage directly, so
// they run AFTER the node is stopped (no SQLite contention with the live writer).

import { rmSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { allocPorts, smokeRoot, BIN } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, genKeypair } from 'lattice-node-sdk'

const ROOT = smokeRoot('cli-operator-journey')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const WAIT_MS = 300_000
let failed = false
const fail = (msg) => { console.error(`✗ ${msg}`); failed = true }

console.log('=== operator CLI journey smoke test ===')

// Scale the per-command deadline with the suite (CI runs workers:2 + SMOKE_TIMEOUT_SCALE),
// so a loaded `chain deploy`/`diag` on a busy runner isn't SIGTERM'd into a spurious 124.
const CLI_TIMEOUT_MS = 120_000 * (Number(process.env.SMOKE_TIMEOUT_SCALE) || 1)

// Run the real binary as an operator would; map any error (incl. timeout SIGTERM, which
// reports code:null) to a non-zero code so a hung/failed CLI is never read as success.
function runCli(args, opts = {}) {
  return new Promise((resolve) => {
    execFile(BIN, args, { timeout: CLI_TIMEOUT_MS, cwd: opts.cwd }, (err, stdout, stderr) => {
      const code = err ? (err.code ?? 124) : 0
      resolve({ code, signal: err?.signal ?? null, stdout: stdout ?? '', stderr: stderr ?? '' })
    })
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase A — keys (local, no node)
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n[A] keys generate / address / show')
const funderKeyFile = `${ROOT}/funder.json`
const gen = await runCli(['keys', 'generate', '--output', funderKeyFile])
if (gen.code !== 0) fail(`keys generate exited ${gen.code}: ${gen.stderr}`)
if (!existsSync(funderKeyFile)) fail('keys generate did not write the key file')
const funder = existsSync(funderKeyFile) ? JSON.parse(readFileSync(funderKeyFile, 'utf8')) : {}
if (!funder.publicKey || !funder.privateKey || !funder.address) fail('key file missing publicKey/privateKey/address')
console.log(`  funder address=${funder.address}`)

const addr = await runCli(['keys', 'address', funder.publicKey])
if (addr.code !== 0) fail(`keys address exited ${addr.code}`)
if (funder.address && !addr.stdout.includes(funder.address)) fail(`keys address ${funder.address} not in output: ${addr.stdout.trim()}`)

const show = await runCli(['keys', 'show', funderKeyFile])
if (show.code !== 0) fail(`keys show exited ${show.code}`)
if (funder.address && !show.stdout.includes(funder.address)) fail('keys show did not echo the address')

if (failed) { console.error('keys phase failed; aborting'); process.exit(1) }

// ─────────────────────────────────────────────────────────────────────────────
// Phase B — node + miner; RPC-client commands (send, tx, chain deploy/genesis/attach/detach)
// ─────────────────────────────────────────────────────────────────────────────
const [nexusPorts] = await allocPorts(1)
const nexusNode = new LatticeNode({
  name: 'node', dir: `${ROOT}/node`,
  port: nexusPorts.port, rpcPort: nexusPorts.rpcPort,
  coinbaseAddress: funder.address,
})
const net = new LatticeNetwork()
net.add(nexusNode)
net.installSignalHandlers()

nexusNode.start()
await nexusNode.waitForRPC()
const info = await nexusNode.chainInfo()
const nexusDir = info.nexus
const cookie = `${nexusNode.dir}/.cookie`

const miner = new LatticeMiner(nexusNode, [])
net.addMiner(miner)
await miner.start()
console.log(`\n[B] node up (${nexusNode.base}); Nexus miner started`)

// Funder accrues coinbase.
await waitFor(async () => (await nexusNode.balance(funder.address, nexusDir)) >= 5000,
  'funder coinbase balance', { timeoutMs: WAIT_MS, intervalMs: 1_000 })

// send <to> <amount> --key --rpc
console.log('  send (CLI)')
const recipient = genKeypair()
const send = await runCli(['send', recipient.address, '500', '--key', funderKeyFile, '--rpc', nexusNode.base])
if (send.code !== 0) fail(`send exited ${send.code}: ${send.stderr}`)
else await waitFor(async () => (await nexusNode.balance(recipient.address, nexusDir)) >= 500 ? true : null,
  'send recipient credited', { timeoutMs: WAIT_MS, intervalMs: 1_000 })

// tx --key --to --amount --rpc (the general tx builder)
console.log('  tx (CLI)')
const r2 = genKeypair()
const tx = await runCli(['tx', '--key', funderKeyFile, '--to', r2.address, '--amount', '300', '--rpc', nexusNode.base])
if (tx.code !== 0) fail(`tx exited ${tx.code}: ${tx.stderr}`)
else await waitFor(async () => (await nexusNode.balance(r2.address, nexusDir)) >= 300 ? true : null,
  'tx recipient credited', { timeoutMs: WAIT_MS, intervalMs: 1_000 })

// chain deploy (CLI) — admin-authed; submits the genesisAction signed by --key.
console.log('  chain deploy (CLI)')
const CHILD = 'CliChild'
const childPath = `${nexusDir}/${CHILD}`
const deploy = await runCli(['chain', 'deploy',
  '--rpc', nexusNode.base, '--cookie-file', cookie, '--key', funderKeyFile,
  '--directory', CHILD, '--parent-directory', nexusDir,
  '--target-block-time', '30000', '--initial-reward', '1000000'])
if (deploy.code !== 0) fail(`chain deploy exited ${deploy.code}: ${deploy.stderr}`)
else console.log(`    ${deploy.stdout.split('\n').find((l) => /genesis/i.test(l))?.trim() ?? 'deployed'}`)

// chain genesis (CLI) — fetch the staged genesis for the deployed child.
console.log('  chain genesis (CLI)')
let genesisOk = false
await waitFor(async () => {
  const g = await runCli(['chain', 'genesis', '--rpc', nexusNode.base, '--chain-path', childPath])
  if (g.code === 0 && /[0-9a-f]{16,}/i.test(g.stdout)) { genesisOk = true; return true }
  return null
}, 'chain genesis returns the staged child genesis', { timeoutMs: 60_000, intervalMs: 2_000 }).catch(() => {})
if (!genesisOk) fail('chain genesis did not return the deployed child genesis')

// chain attach (CLI) — register a (dummy) child RPC endpoint, verify it shows in chain/map.
console.log('  chain attach / detach (CLI)')
const [dummyPorts] = await allocPorts(1)
const dummyChildBase = `http://127.0.0.1:${dummyPorts.rpcPort}`
const attach = await runCli(['chain', 'attach',
  '--rpc', nexusNode.base, '--cookie-file', cookie,
  '--chain-path', childPath, '--child-rpc', dummyChildBase, '--child-auth-token', 'dummy'])
if (attach.code !== 0) fail(`chain attach exited ${attach.code}: ${attach.stderr}`)
else {
  const map = await nexusNode.rpc('GET', '/api/chain/map')
  const mapStr = JSON.stringify(map)
  if (!mapStr.includes(CHILD)) fail('attached child not present in chain/map')
}

// chain detach (CLI) — drop the registration; verify it's actually gone from chain/map
// (a detach that silently no-ops must fail the test). This is an RPC read, so it must
// run while the node is still up.
const detach = await runCli(['chain', 'detach', '--rpc', nexusNode.base, '--cookie-file', cookie, '--chain-path', childPath])
if (detach.code !== 0) fail(`chain detach exited ${detach.code}: ${detach.stderr}`)
else {
  const map2 = await nexusNode.rpc('GET', '/api/chain/map')
  if (JSON.stringify(map2).includes(CHILD)) fail('detached child still present in chain/map')
}

// Capture the live height so we can assert the offline `query`/`status` read matches.
const latest = await nexusNode.rpc('GET', '/api/block/latest').catch(() => null)
const liveHeight = Number(latest?.blockHeight ?? latest?.height ?? 0)

// ─────────────────────────────────────────────────────────────────────────────
// Phase C — stop the node, then the offline storage-reading commands
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n[C] stopping node for offline status/query/identity')
await miner.stop()
await nexusNode.stop()
await sleep(1_500)

const status = await runCli(['status', '--storage-path', nexusNode.dir, '--directory', nexusDir])
if (status.code !== 0) fail(`status exited ${status.code}: ${status.stderr}`)
if (!/Chain Tip/i.test(status.stdout) || !/Height/i.test(status.stdout)) fail(`status output missing tip/height: ${status.stdout.trim()}`)

const qHeight = await runCli(['query', 'height', '--storage-path', nexusNode.dir, '--directory', nexusDir])
if (qHeight.code !== 0) fail(`query height exited ${qHeight.code}`)
const reportedHeight = parseInt(qHeight.stdout.trim(), 10)
if (!(reportedHeight >= 1)) fail(`query height returned a non-positive value: ${qHeight.stdout.trim()}`)
if (liveHeight && reportedHeight + 2 < liveHeight) fail(`query height ${reportedHeight} far below live ${liveHeight}`)

const qTip = await runCli(['query', 'tip', '--storage-path', nexusNode.dir, '--directory', nexusDir])
if (qTip.code !== 0 || qTip.stdout.trim().length < 10) fail(`query tip failed: code=${qTip.code} out=${qTip.stdout.trim()}`)

// `query balance` is intentionally an offline no-op: it prints guidance to use a running
// node's GET /api/balance rather than reading the state trie offline. Pin that behavior
// (asserting code 0 alone tests nothing). Live balance reads are covered by send/tx above.
const qBal = await runCli(['query', 'balance', funder.address, '--storage-path', nexusNode.dir, '--directory', nexusDir])
if (qBal.code !== 0) fail(`query balance exited ${qBal.code}: ${qBal.stderr}`)
if (!/running node|\/api\/balance/i.test(qBal.stdout)) fail(`query balance: expected offline guidance, got: ${qBal.stdout.trim()}`)

// identity --data-dir --public-key-only must match the node's persisted identity key.
const ident = await runCli(['identity', '--data-dir', nexusNode.dir, '--public-key-only'])
const persistedIdentity = existsSync(`${nexusNode.dir}/identity.json`)
  ? JSON.parse(readFileSync(`${nexusNode.dir}/identity.json`, 'utf8')).publicKey : null
if (ident.code !== 0) fail(`identity exited ${ident.code}: ${ident.stderr}`)
if (persistedIdentity && !ident.stdout.includes(persistedIdentity)) fail('identity --public-key-only did not match persisted identity.json')

// ─────────────────────────────────────────────────────────────────────────────
// Phase D — local scaffold/diagnostic commands
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n[D] diag / init')
const diag = await runCli(['diag'])
if (diag.code !== 0) fail(`diag exited ${diag.code}: ${diag.stderr}`)
if (!/Genesis Serialization Diagnostic/i.test(diag.stdout)) fail('diag missing diagnostic output')

const initOut = await runCli(['init', 'demoproj', '--template', 'basic'], { cwd: ROOT })
if (initOut.code !== 0) fail(`init exited ${initOut.code}: ${initOut.stderr}`)
if (!existsSync(`${ROOT}/demoproj/Package.swift`)) fail('init did not scaffold Package.swift')

// ─────────────────────────────────────────────────────────────────────────────
console.log('')
if (failed) { console.error('=== operator CLI journey: FAILED ==='); net.teardown(); await sleep(500); process.exit(1) }
console.log('✓ operator CLI journey: keys, send, tx, chain deploy/genesis/attach/detach, status, query, identity, diag, init all succeeded')
net.teardown()
await sleep(500)
process.exit(0)
