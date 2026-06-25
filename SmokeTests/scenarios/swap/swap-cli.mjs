// Cross-chain swap driven through the `swap sell` / `swap buy` / `swap status` CLI
// (not raw RPC submitTx). The only end-to-end coverage of the swap CLI orchestration:
// fee-policy gate, parent visibleStateHeight gate, receiptTxCID → receiptBlockHeight
// resolution, and txCID withdrawal confirmation.
//
// It also exercises the CORE merged-mining model directly: a SINGLE merged
// coordinator (LatticeMiner(nexus, [child])) runs for the whole test and advances
// BOTH chains — the funding + receipt state-access txs on the parent AND the
// deposit/withdrawal on the child. No miner alternation: the node builds each
// template with full state access, the coordinator only does PoW.

import { rmSync, mkdirSync, writeFileSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { allocPorts, smokeRoot, BIN } from 'lattice-node-sdk/env'
import {
  LatticeNode, LatticeNetwork, LatticeMiner,
  sleep, waitFor, genKeypair,
} from 'lattice-node-sdk'

const ROOT = smokeRoot('swap-cli')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })

const [nexusPorts] = await allocPorts(1)
const CHILD = 'FastTest'
const WAIT_MS = 300_000

console.log('=== cross-chain swap CLI smoke test (single merged miner) ===')

function runSwapCli(args) {
  return new Promise((resolve) => {
    execFile(BIN, args, { timeout: 300_000 }, (err, stdout, stderr) => {
      // A timeout/kill is reported as { code: null, signal: 'SIGTERM', killed: true } —
      // map any error to a non-zero code (124 = timeout convention) so a hung CLI is never
      // mistaken for success; keep signal/killed for diagnostics.
      const code = err ? (err.code ?? 124) : 0
      resolve({ code, signal: err?.signal ?? null, killed: err?.killed ?? false, stdout: stdout ?? '', stderr: stderr ?? '' })
    })
  })
}

const funder = genKeypair()
const seller = genKeypair()
const buyer = genKeypair()
const sellerKeyFile = `${ROOT}/seller.json`
const buyerKeyFile = `${ROOT}/buyer.json`
writeFileSync(sellerKeyFile, JSON.stringify({ publicKey: seller.publicKey, privateKey: seller.privateKey }))
writeFileSync(buyerKeyFile, JSON.stringify({ publicKey: buyer.publicKey, privateKey: buyer.privateKey }))

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
console.log(`funder=${funder.address}\nseller=${seller.address}\nbuyer=${buyer.address}`)

console.log(`deploying ${CHILD}...`)
const [childPorts] = await allocPorts(1)
const childNode = await nexusNode.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: childPorts,
  premine: 100, premineRecipient: funder.address,
})
net.add(childNode)

// ── ONE merged miner for the whole test: advances Nexus AND FastTest together ──
const miner = new LatticeMiner(nexusNode, [childNode])
net.addMiner(miner)
await miner.start()
console.log('merged miner started (advances both chains)')

// Tx fees are byte-priced (~500+ per swap tx), so size escrow/demand WELL above the
// fee. The withdrawal fee must be strictly less than the escrow, so DEPOSIT is large.
const DEPOSIT = 3000        // child-coin escrow (must exceed the ~500 withdrawal fee)
const DEMAND = 100          // parent-coin the buyer pays the seller
const SELLER_CHILD_FUND = DEPOSIT + 1500   // escrow + deposit fee headroom
const BUYER_NEXUS_FUND = DEMAND + 1500     // demand + receipt fee headroom

// Wait until the funder has accrued enough on each chain (Nexus + child coinbase).
await waitFor(async () => (await nexusNode.balance(funder.address, nexusDir)) >= (BUYER_NEXUS_FUND + 100),
  'funder Nexus balance', { timeoutMs: WAIT_MS, intervalMs: 1_000 })
await waitFor(async () => (await childNode.balance(funder.address, CHILD)) >= (SELLER_CHILD_FUND + 100),
  'funder child balance (merged miner advancing child)', { timeoutMs: WAIT_MS, intervalMs: 1_000 })
console.log('funder funded on both chains by the merged miner')

// Fund seller (child) and buyer (nexus) via the funder. These are STATE-ACCESS txs
// on each chain; the single merged miner mines them — proving the alternation in the
// older swap scenarios is unnecessary.
async function fund(node, chain, chainPathArr, to, amount) {
  await waitFor(async () => {
    const base = await node.nonce(funder.address, chain)
    const body = {
      nonce: base, signers: [funder.address], fee: 1,
      accountActions: [{ owner: funder.address, delta: -(amount + 1) }, { owner: to, delta: amount }],
    }
    if (chainPathArr) body.chainPath = chainPathArr
    const r = await node.submitTx(body, chain, funder)
    return r.ok ? true : null
  }, `submit fund ${chain}`, { timeoutMs: 60_000, intervalMs: 1_000 })
  await waitFor(async () => (await node.balance(to, chain)) >= amount,
    `${chain} funded for ${to.slice(0, 10)}`, { timeoutMs: WAIT_MS, intervalMs: 1_000 })
}

console.log('funding seller (child) + buyer (nexus)...')
await fund(childNode, CHILD, [nexusDir, CHILD], seller.address, SELLER_CHILD_FUND)
await fund(nexusNode, nexusDir, null, buyer.address, BUYER_NEXUS_FUND)

const sellerChild0 = await childNode.balance(seller.address, CHILD)
const sellerNexus0 = await nexusNode.balance(seller.address, nexusDir)
const buyerNexus0 = await nexusNode.balance(buyer.address, nexusDir)
const buyerChild0 = await childNode.balance(buyer.address, CHILD)
console.log(`pre-swap  seller[child=${sellerChild0} nexus=${sellerNexus0}]  buyer[nexus=${buyerNexus0} child=${buyerChild0}]`)

// ── [1] swap sell (CLI): seller escrows on the child, prints the swap-id ──────
console.log('\n[1] swap sell (CLI)')
const sell = await runSwapCli([
  'swap', 'sell', '--rpc', `${childNode.base}`, '--key', sellerKeyFile,
  '--deposit', String(DEPOSIT), '--demand', String(DEMAND),
])
console.log(sell.stdout.trim())
if (sell.code !== 0) { console.error('swap sell failed:', sell.stderr); net.teardown(); process.exit(1) }
const m = sell.stdout.match(/(FastTest:\d+:[a-z0-9]+:\d+:\d+)/i)
if (!m) { console.error('could not parse swap-id'); net.teardown(); process.exit(1) }
const swapId = m[1]
console.log(`  swap-id = ${swapId}`)

// Confirm the deposit mined via the seller's escrow being locked (balance drops by
// deposit+fee). The swap-id encodes the nonce in decimal; the /api/deposit query wants
// hex, so we use the balance signal here (swap buy verifies the deposit internally).
await waitFor(async () => {
  const bal = await childNode.balance(seller.address, CHILD)
  return bal <= sellerChild0 - DEPOSIT ? bal : null
}, 'deposit mined (seller escrow locked)', { timeoutMs: WAIT_MS, intervalMs: 1_000 })
console.log('  ✓ deposit mined')

// ── [2] swap buy (CLI): pay receipt on parent, wait for child visibleStateHeight,
//        withdraw, confirm by txCID — all under the single merged miner. ─────────
console.log('\n[2] swap buy (CLI)')
const buy = await runSwapCli([
  'swap', 'buy',
  '--child-rpc', `${childNode.base}`, '--rpc', `${nexusNode.base}`,
  '--key', buyerKeyFile, '--swap-id', swapId,
  '--yes', '--min-confirmations', '0',
  '--receipt-timeout', '240', '--withdraw-timeout', '240',
])
console.log(buy.stdout.trim())
if (buy.code !== 0) { console.error('swap buy failed:', buy.stderr); net.teardown(); process.exit(1) }
if (!/Swap complete/i.test(buy.stdout)) { console.error('swap buy did not report completion'); net.teardown(); process.exit(1) }
console.log('  ✓ swap buy reported completion')

// ── [3] swap status (CLI) ─────────────────────────────────────────────────────
console.log('\n[3] swap status (CLI)')
const status = await runSwapCli([
  'swap', 'status', '--child-rpc', `${childNode.base}`, '--rpc', `${nexusNode.base}`, '--swap-id', swapId,
])
console.log(status.stdout.trim())
if (status.code !== 0) {
  console.error(`swap status failed: code=${status.code} signal=${status.signal} ${status.stderr}`)
  net.teardown(); process.exit(1)
}

// ── Verify balances ───────────────────────────────────────────────────────────
await miner.stop()
await sleep(2_000)
const sellerNexus1 = await nexusNode.balance(seller.address, nexusDir)
const sellerChild1 = await childNode.balance(seller.address, CHILD)
const buyerNexus1 = await nexusNode.balance(buyer.address, nexusDir)
const buyerChild1 = await childNode.balance(buyer.address, CHILD)

console.log('\n=== RESULTS ===')
console.log(`seller nexus ${sellerNexus0}→${sellerNexus1} (Δ${sellerNexus1 - sellerNexus0}, expect +${DEMAND})`)
console.log(`seller child ${sellerChild0}→${sellerChild1} (Δ${sellerChild1 - sellerChild0}, expect −${DEPOSIT}−fee)`)
console.log(`buyer  nexus ${buyerNexus0}→${buyerNexus1} (Δ${buyerNexus1 - buyerNexus0}, expect −${DEMAND}−fee)`)
console.log(`buyer  child ${buyerChild0}→${buyerChild1} (Δ${buyerChild1 - buyerChild0}, expect +escrow−fee)`)

let ok = true
if (sellerNexus1 - sellerNexus0 !== DEMAND) { console.error('✗ seller did not receive the demanded parent-coin'); ok = false }
if (sellerChild0 - sellerChild1 < DEPOSIT) { console.error('✗ seller child escrow not deducted'); ok = false }
if (buyerNexus0 - buyerNexus1 < DEMAND) { console.error('✗ buyer did not pay the demanded parent-coin'); ok = false }
if (buyerChild1 <= buyerChild0) { console.error('✗ buyer did not receive the child escrow'); ok = false }

if (!ok) { net.teardown(); await sleep(500); process.exit(1) }
console.log('\n✓ swap CLI deposit → receipt → withdrawal completed under a single merged miner')
net.teardown()
await sleep(500)
process.exit(0)
