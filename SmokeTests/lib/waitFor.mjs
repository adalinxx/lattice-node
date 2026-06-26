// Poll-with-deadline, the only "wait" primitive scenarios should use.
// Sleeps mask flakes; deadlines surface them with informative messages.

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Load-aware timeout scaling. Under N parallel workers each scenario gets ~1/N of
// the CPU, so block production, gossip, and convergence run correspondingly
// slower; a fixed wall-clock deadline that's ample on an idle machine then
// false-fails under suite contention. `run.mjs` sets SMOKE_TIMEOUT_SCALE from the
// worker count so every deadline stretches with load. This only EXTENDS the
// deadline — a wait still returns the instant its condition holds, so green runs
// are unaffected; only a genuine hang takes proportionally longer to surface.
export const TIMEOUT_SCALE = Math.max(1, Number(process.env.SMOKE_TIMEOUT_SCALE) || 1)
export const scaledMs = (ms) => Math.round(ms * TIMEOUT_SCALE)

export async function waitFor(fn, desc, { timeoutMs = 30_000, intervalMs = 500 } = {}) {
  const deadline = scaledMs(timeoutMs)
  const start = Date.now()
  let lastErr
  while (Date.now() - start < deadline) {
    try {
      const r = await fn()
      if (r !== null && r !== undefined && r !== false) return r
    } catch (e) {
      lastErr = e
    }
    await sleep(intervalMs)
  }
  const tail = lastErr ? ` (last error: ${lastErr.message})` : ''
  const scaleNote = TIMEOUT_SCALE > 1 ? ` (base ${timeoutMs}ms × scale ${TIMEOUT_SCALE})` : ''
  throw new Error(`timed out after ${deadline}ms${scaleNote}: ${desc}${tail}`)
}

// Progress-aware wait: the primitive for "the system should reach state X by making
// forward progress" (chain height, peer count, sync cursor — any monotonic measure).
//
// A fixed wall-clock deadline asserts a LATENCY bound ("reach height N within 60s") on
// what is really a CORRECTNESS invariant ("the chain advances to N"). Under CI/parallel
// CPU contention block production slows, so that latency bound false-fails a slow-but-
// correct run — the single most common cause of flaky integration tests, and bumping the
// timeout only masks it. Instead this fails ONLY on a genuine STALL: the stall timer
// resets every time `measure()` reports a new high-water mark, so a chain that keeps
// advancing never times out no matter how slow the host. `safetyMs` is a last-resort
// backstop against a livelock that "progresses" forever. Both windows scale with load.
//
// `measure()` returns a number (the progress metric) or null/undefined (not ready yet).
// Resolves with the first measured value for which `satisfied(value)` is true.
export async function waitForProgress(measure, satisfied, desc, {
  stallMs = 30_000,
  safetyMs = 600_000,
  intervalMs = 500,
} = {}) {
  const stallDeadline = scaledMs(stallMs)
  const safetyDeadline = scaledMs(safetyMs)
  const start = Date.now()
  let best = -Infinity
  let lastProgress = Date.now()
  let lastErr
  while (true) {
    let v
    try { v = await measure() } catch (e) { lastErr = e; v = undefined }
    if (v !== null && v !== undefined) {
      if (satisfied(v)) return v
      if (typeof v === 'number' && v > best) { best = v; lastProgress = Date.now() }
    }
    const now = Date.now()
    const bestNote = best === -Infinity ? 'no progress yet' : `best=${best}`
    if (now - lastProgress > stallDeadline) {
      const tail = lastErr ? ` (last error: ${lastErr.message})` : ''
      throw new Error(`stalled: ${desc} — no forward progress for ${stallDeadline}ms (${bestNote})${tail}`)
    }
    if (now - start > safetyDeadline) {
      throw new Error(`safety-net timeout: ${desc} after ${safetyDeadline}ms (${bestNote})`)
    }
    await sleep(intervalMs)
  }
}
