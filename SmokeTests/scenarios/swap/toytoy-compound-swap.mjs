// Full realistic GRANDCHILD compound swap across TWO UNTRUSTED nodes — LIVE.
//
//   Nexus ── toy ── toytoy
//
// A mines Nexus + toy + toytoy CONTINUOUSLY (no freezing); each chain's coinbase is
// the seller of its coin. B (untrusted buyer) peers A for Nexus only + supervises
// children, then follows SEQUENTIALLY: toy first, waits until toy is fully caught up
// (toytoy's registration lives in toy's state), THEN toytoy. B buys toytoy paying up
// the hierarchy nexus -> toy -> toytoy against the live tip. premine:0; sellers funded
// by mining.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, genKeypair, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('toytoy-compound')
const [a, b, toyP, ttP] = await allocPorts(4, { seed: 71 })
const buyer = genKeypair()
const N1 = (1n).toString(16).padStart(32, '0')
const N2 = (2n).toString(16).padStart(32, '0')

console.log('=== two-node LIVE compound grandchild swap (nexus -> toy -> toytoy) ===')
const net = new LatticeNetwork(); net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
A.start(); await A.waitForRPC(); await A.readIdentity()
const nexusSeller = A._keypair
const NEXUS = (await A.chainInfo()).nexus
const Ptoy = [NEXUS, 'toy']; const Ptt = [NEXUS, 'toy', 'toytoy']

console.log('[A] spawn toy + toytoy')
const aToy = net.add(await A.spawnChild({ directory: 'toy', parentDirectory: NEXUS, ports: toyP, premine: 0, initialReward: 1_000_000 }))
await aToy.waitForRPC(); await aToy.readIdentity()
const toyGenesis = (await aToy.chainInfo()).genesisHash
const aTt = net.add(await aToy.spawnChild({ directory: 'toytoy', parentDirectory: 'toy', ports: ttP, premine: 0, initialReward: 1_000_000 }))
await aTt.waitForRPC()
const ttGenesis = (await aTt.chainInfo()).genesisHash
const toySeller = aToy._keypair; const ttSeller = aTt._keypair

// Mine continuously — never stop. Throttle to ~3s/block (> B's debug apply rate)
// so the untrusted buyer can catch up + keep up with the LIVE tip without freezing.
const miner = net.addMiner(new LatticeMiner(A, [aToy, aTt], { workers: 2, minBlockIntervalMs: 3000 }))
await miner.start()
const mineOnA = (check, desc) => waitFor(check, desc, { timeoutMs: 180_000, intervalMs: 2000 })

await A.announceChild({ nexusDir: NEXUS, child: 'toy', genesisHash: toyGenesis, fee: 1, minFunds: 50 })
await mineOnA(async () => (await aToy.height('toy')) >= 3 ? true : null, 'toy advancing')
await aToy.announceChild({ nexusDir: 'Nexus/toy', child: 'toytoy', genesisHash: ttGenesis, fee: 1, minFunds: 50 })

console.log('[A] fund buyer + sellers')
await mineOnA(async () => (await A.balance(nexusSeller.address, NEXUS)) >= 1_100 && (await aToy.balance(toySeller.address, Ptoy)) >= 1_100 && (await aTt.balance(ttSeller.address, Ptt)) >= 1_100 ? true : null, 'sellers funded')
await A.submitTx({ chainPath: [NEXUS], nonce: await A.nonce(nexusSeller.address, NEXUS), signers: [nexusSeller.address], fee: 1, accountActions: [{ owner: nexusSeller.address, delta: -1_001 }, { owner: buyer.address, delta: 1_000 }] }, NEXUS, nexusSeller)
await mineOnA(async () => (await A.balance(buyer.address, NEXUS)) >= 1_000 ? true : null, 'buyer funded')

console.log('[A] post both deposits')
await aToy.submitTx({ chainPath: Ptoy, nonce: await aToy.nonce(toySeller.address, Ptoy), signers: [toySeller.address], fee: 1, accountActions: [{ owner: toySeller.address, delta: -1001 }], depositActions: [{ nonce: N1, demander: toySeller.address, amountDemanded: 100, amountDeposited: 1000 }] }, 'toy', toySeller)
await aTt.submitTx({ chainPath: Ptt, nonce: await aTt.nonce(ttSeller.address, Ptt), signers: [ttSeller.address], fee: 1, accountActions: [{ owner: ttSeller.address, delta: -1001 }], depositActions: [{ nonce: N2, demander: ttSeller.address, amountDemanded: 100, amountDeposited: 1000 }] }, 'toytoy', ttSeller)
await mineOnA(async () => (await aToy.getDeposit(toySeller.address, 1000, N1, 'toy')) && (await aTt.getDeposit(ttSeller.address, 1000, N2, 'toytoy')) ? true : null, 'deposits visible')

// ---- Node B: untrusted buyer joins the LIVE chain ----
// toy is followed explicitly (so we can prove it's synced before toytoy exists in
// toy's state); toytoy SELF-ASSEMBLES via B's toy auto-follow (recursive grandchild
// supervision — parent-dependency.mjs), which the cascade only triggers after toy syncs.
console.log('[B] boot untrusted (peer A for Nexus only) + supervise children')
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))
B.start(['--peer', A.peerArg(), '--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC()

// Pure auto-follow (parent-dependency): B auto-follows toy (supervise inherited),
// and B's toy in turn auto-follows toytoy. Resolve each level via chain/map. Order is
// enforced — toytoy only appears in toy's map AFTER toy syncs enough to see its reg.
async function resolveLeaf(rootBase, fullPath) {
  let base = `${rootBase}/api`
  for (let depth = 2; depth <= fullPath.length; depth++) {
    const key = fullPath.slice(0, depth).join('/')
    base = await waitFor(async () => {
      const m = await fetch(`${base}/chain/map`).then((x) => x.json()).catch(() => null)
      return m?.[key] ?? null
    }, `B endpoint for ${key}`, { timeoutMs: 240_000, intervalMs: 3000 })
  }
  return base
}
const heightAt = async (ep, dir) => (await fetch(`${ep}/chain/info`).then((x) => x.json()).catch(() => null))?.chains?.find((c) => c.directory === dir)?.height ?? 0
const balAt = async (ep, addr) => (await fetch(`${ep}/balance/${addr}`).then((x) => x.json()).catch(() => null))?.balance ?? 0

// A withdrawal only becomes valid once the child's parentState advances past the
// receipt; on a LIVE tip the receipt may not be visible at first-submit time, so
// resubmit (re-reading the nonce) until the withdrawn balance lands. Mirrors the
// bounded-resubmit loop in grandchild-swap.mjs.
const landWithdraw = async (submit, check, desc) => {
  for (let i = 0; i < 40; i++) {
    if (await check()) return
    try { await submit() } catch { /* not yet valid — retry */ }
    await sleep(3000)
  }
  if (!(await check())) throw new Error(`${desc} never landed`)
}

const bToyEp = await resolveLeaf(B.base, Ptoy)
console.log('  B auto-followed toy →', bToyEp)
await waitFor(async () => (await heightAt(bToyEp, 'toy')) >= (await aToy.height('toy')) - 2 ? true : null, 'B toy caught up', { timeoutMs: 180_000, intervalMs: 2000 })
console.log('  toy synced @', await heightAt(bToyEp, 'toy'), '— B.toy now auto-follows toytoy')
const bTtEp = await resolveLeaf(B.base, Ptt)
console.log('  B.toy auto-followed toytoy →', bTtEp)
await waitFor(async () => (await heightAt(bTtEp, 'toytoy')) >= (await aTt.height('toytoy')) - 2 ? true : null, 'B toytoy caught up', { timeoutMs: 180_000, intervalMs: 2000 })
console.log('[B] source-agnostic-synced toy + toytoy against the LIVE tip')

// The grandchild lives under B's toy follower, not B's top-level node — so toytoy
// txs (nonce + submit) must target B's toytoy follower endpoint, not B.base.
const bTt = Object.create(B)
Object.defineProperty(bTt, 'base', { value: bTtEp.replace(/\/api$/, ''), configurable: true })

// LIVE: B submits on its node; A is mining, so it includes + B syncs the effect.
console.log('[B] LEG 1 (nexus->toy): pay 100 nexus, withdraw 1000 toy')
await B.submitTx({ chainPath: [NEXUS], nonce: await B.nonce(buyer.address, [NEXUS]), signers: [buyer.address], fee: 1, accountActions: [{ owner: buyer.address, delta: -101 }, { owner: toySeller.address, delta: 100 }], receiptActions: [{ withdrawer: buyer.address, nonce: N1, demander: toySeller.address, amountDemanded: 100, directory: 'toy' }] }, NEXUS, buyer)
await waitFor(async () => (await B.balance(buyer.address, [NEXUS])) <= 900 ? true : null, 'B sees leg1 receipt (paid nexus)', { timeoutMs: 120_000, intervalMs: 2000 })
await landWithdraw(
  async () => B.submitTx({ chainPath: Ptoy, nonce: await B.nonce(buyer.address, Ptoy), signers: [buyer.address], fee: 1, accountActions: [{ owner: buyer.address, delta: 999 }], withdrawalActions: [{ withdrawer: buyer.address, nonce: N1, demander: toySeller.address, amountDemanded: 100, amountWithdrawn: 1000 }] }, undefined, buyer),
  async () => (await balAt(bToyEp, buyer.address)) >= 999,
  'B received toy (leg1 withdrawal)')
console.log('[B] leg 1 done — buyer toy =', await balAt(bToyEp, buyer.address))

console.log('[B] LEG 2 (toy->toytoy): pay 100 toy, withdraw 1000 toytoy')
await B.submitTx({ chainPath: Ptoy, nonce: await B.nonce(buyer.address, Ptoy), signers: [buyer.address], fee: 1, accountActions: [{ owner: buyer.address, delta: -101 }, { owner: ttSeller.address, delta: 100 }], receiptActions: [{ withdrawer: buyer.address, nonce: N2, demander: ttSeller.address, amountDemanded: 100, directory: 'toytoy' }] }, undefined, buyer)
await waitFor(async () => (await balAt(bToyEp, buyer.address)) <= 900 ? true : null, 'B sees leg2 receipt (paid toy)', { timeoutMs: 120_000, intervalMs: 2000 })
await landWithdraw(
  async () => bTt.submitTx({ chainPath: Ptt, nonce: await bTt.nonce(buyer.address, Ptt), signers: [buyer.address], fee: 1, accountActions: [{ owner: buyer.address, delta: 999 }], withdrawalActions: [{ withdrawer: buyer.address, nonce: N2, demander: ttSeller.address, amountDemanded: 100, amountWithdrawn: 1000 }] }, undefined, buyer),
  async () => (await balAt(bTtEp, buyer.address)) >= 999,
  'B received toytoy (leg2 withdrawal)')

const finalTt = await balAt(bTtEp, buyer.address)
console.log('    buyer toytoy (FINAL, read from B) =', finalTt)
if (finalTt < 999) throw new Error(`buyer did not receive toytoy: ${finalTt}`)
console.log(`\n✓ PASS — untrusted buyer node purchased ${finalTt} toytoy via nexus -> toy -> toytoy (live)`)
net.teardown(); await sleep(300); process.exit(0)
