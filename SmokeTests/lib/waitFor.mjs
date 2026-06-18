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
