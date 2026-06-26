// Chain introspection + RPC wrappers. All take a Node so multi-node scenarios
// can probe each independently.

import { sleep, waitFor, waitForProgress, scaledMs } from './waitFor.mjs'

export async function chainInfo(node) {
  const r = await node.rpc('GET', '/api/chain/info')
  return r.ok ? r.json : null
}

export const chainOf = (info, dir) => info?.chains?.find((c) => c.directory === dir)

export async function tipInfo(node, dir) {
  // Retry a few times — node may briefly be busy processing blocks
  for (let i = 0; i < 3; i++) {
    const info = await chainInfo(node)
    if (info) {
      const target = dir ?? info.nexus
      const c = chainOf(info, target)
      return { directory: target, height: c?.height ?? 0, tip: c?.tip ?? '', nexus: info.nexus }
    }
    if (i < 2) await sleep(300)
  }
  return null
}

export async function getNonce(node, addr, chain) {
  const r = await node.rpc('GET', `/api/nonce/${addr}?chainPath=${chain}`)
  if (!r.ok) throw new Error(`nonce(${chain}) failed: ${JSON.stringify(r.json)}`)
  return r.json.nonce
}

export async function getBalance(node, addr, chain) {
  const r = await node.rpc('GET', `/api/balance/${addr}?chainPath=${chain}`)
  if (!r.ok) throw new Error(`balance(${chain}) failed: ${JSON.stringify(r.json)}`)
  return r.json.balance
}

export async function getDeposit(node, demander, amount, nonceHex, chain) {
  const r = await node.rpc(
    'GET',
    `/api/deposit?demander=${demander}&amount=${amount}&nonce=${nonceHex}&chainPath=${chain}`,
  )
  return r.json
}

export async function getReceipt(node, demander, amount, nonceHex, directory) {
  const r = await node.rpc(
    'GET',
    `/api/receipt-state?demander=${demander}&amount=${amount}&nonce=${nonceHex}&chainPath=${directory}`,
  )
  return r.json
}

// Block production runs in the external lattice-miner (the node never mines
// in-process). These delegate to the node's miner lifecycle, which spawns the
// real `lattice-miner` binary bound to the node.
export async function startMining(node, chain) {
  await node.startMining(chain)
}

export async function stopMining(node, chain) {
  await node.stopMining(chain)
}

// Wait until height stops advancing — used after stopMining to drain in-flight
// blocks before staging txs that depend on a stable nonce.
export async function awaitMiningQuiesced(node, chain, { timeoutMs = 5_000, idleMs = 600 } = {}) {
  const start = Date.now()
  let last = (await tipInfo(node, chain))?.height ?? 0
  while (Date.now() - start < timeoutMs) {
    await sleep(idleMs)
    const h = (await tipInfo(node, chain))?.height ?? 0
    if (h === last) return h
    last = h
  }
  return last
}

// Wait for every chain in `dirs` to hit two consecutive height-stable samples.
// Used after stopMining when scenarios stage txs across multiple chains and
// need every chain's nonce to be deterministic.
export async function awaitChainsQuiesced(node, dirs, { timeoutMs = 15_000, intervalMs = 500 } = {}) {
  const set = new Set(dirs)
  let last = null
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    await sleep(intervalMs)
    const info = await chainInfo(node)
    const snap = (info?.chains ?? [])
      .filter((c) => set.has(c.directory))
      .map((c) => `${c.directory}@${c.height}`)
      .sort().join(',')
    if (last === snap) return snap
    last = snap
  }
  throw new Error(`chains never stabilized within ${timeoutMs}ms: ${last}`)
}

// Progress-based: the height target is a CORRECTNESS invariant (the chain advances to
// `minHeight`), not a latency bound. Fails only if production STALLS (no new block for
// the stall window), so a slow-but-advancing chain under CI contention still passes.
// The legacy 4th arg (a number = old hard timeoutMs) is reinterpreted as the stall
// window — "no progress for that long" — which is a strict robustness upgrade.
export async function waitForHeight(node, chain, minHeight, opts = {}) {
  const o = typeof opts === 'number' ? { stallMs: opts } : opts
  return waitForProgress(
    async () => { const t = await tipInfo(node, chain); return t ? t.height : null },
    (h) => h >= minHeight,
    `${node.name}/${chain} height ≥ ${minHeight}`,
    { stallMs: o.stallMs ?? 30_000, safetyMs: o.safetyMs ?? 600_000, intervalMs: o.intervalMs ?? 1_000 },
  )
}

// Best-effort burst: mine until `targetHeight`, or until production stalls (no new block
// for `stallMs`), or an absolute backstop — progress-based rather than a fixed wall-clock
// window, so a loaded host that mines slowly-but-steadily still reaches the target instead
// of being cut off mid-burst. Never throws; returns the tip reached (or null).
export async function mineBurst(node, chain, { targetHeight = 5, stallMs = 8000, maxMs = 120_000 } = {}) {
  await startMining(node, chain)
  const start = Date.now()
  const stallDeadline = scaledMs(stallMs)
  const maxDeadline = scaledMs(maxMs)
  let best = -1
  let lastProgress = Date.now()
  while (true) {
    const t = await tipInfo(node, chain)
    if (t && t.height >= targetHeight) break
    if (t && t.height > best) { best = t.height; lastProgress = Date.now() }
    const now = Date.now()
    if (now - lastProgress > stallDeadline) break
    if (now - start > maxDeadline) break
    await sleep(200)
  }
  await stopMining(node, chain)
  // Retry tipInfo a few times — node may briefly be processing the last block
  for (let i = 0; i < 5; i++) {
    await sleep(500)
    const t = await tipInfo(node, chain)
    if (t) return t
  }
  return null
}

// Common defaults match the swap tests' fast child chain.
export async function deployChild(node, opts) {
  const minerIdent = opts.minerIdentity ?? (await node.readIdentity())
  const body = {
    directory: opts.directory,
    parentDirectory: opts.parentDirectory,
    targetBlockTime: opts.targetBlockTime ?? 1000,
    initialReward: opts.initialReward ?? 1024,
    halvingInterval: opts.halvingInterval ?? 210000,
    premine: opts.premine ?? 0,
    maxTransactionsPerBlock: opts.maxTransactionsPerBlock ?? 100,
    maxStateGrowth: opts.maxStateGrowth ?? 100_000,
    maxBlockSize: opts.maxBlockSize ?? 1_000_000,
    retargetWindow: opts.retargetWindow ?? 120,
    wasmPolicies: opts.wasmPolicies ?? [],
    startMining: opts.startMining ?? true,
  }
  if (opts.premineRecipient) body.premineRecipient = opts.premineRecipient
  const r = await node.rpc('POST', '/api/chain/deploy', body)
  if (!r.ok) throw new Error(`deploy ${opts.directory} failed: ${JSON.stringify(r.json)}`)
  return r.json
}
