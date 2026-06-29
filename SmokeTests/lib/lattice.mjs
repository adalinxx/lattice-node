/**
 * Lattice JavaScript SDK
 *
 * Provides ergonomic wrappers for per-process lattice-node tests.
 * Each chain runs as a separate OS process; LatticeNode.spawnChild()
 * handles deploy + bootstrap automatically.
 *
 * Design mirrors the Swift LatticeNode API:
 *   - LatticeNode   → one chain process
 *   - LatticeMiner  → compatibility wrapper around the coordinator process
 *   - spawnChild()  → deploy on parent + start child process
 */

import { spawn } from 'node:child_process'
import { mkdirSync, createWriteStream, readFileSync, writeFileSync } from 'node:fs'
import { BIN, allocPorts, devGenesisArgs } from './env.mjs'
import { waitFor, waitForProgress, sleep, scaledMs } from './waitFor.mjs'
import { sign as signMsg, genKeypair } from './wallet.mjs'
import { jsonRpcHeaders } from './rpcAuth.mjs'

const MINER_BIN = BIN.replace('LatticeNode', 'LatticeMiningCoordinatorTool')
const CONFIGURED_MINER_STALL_MS = Number.parseInt(process.env.SMOKE_MINER_STALL_MS ?? '', 10)

function defaultMinerStallMs(childNodeCount) {
  if (Number.isFinite(CONFIGURED_MINER_STALL_MS) && CONFIGURED_MINER_STALL_MS > 0) {
    return CONFIGURED_MINER_STALL_MS
  }
  // The external coordinator owns template fetch, nonce search, and submit-work.
  // Treating 15s of unchanged scenario-level state as a dead miner false-restarts
  // valid work, causing side-fork setup transactions and one-block-per-restart
  // progress. Keep the watchdog, but give the coordinator a real block window.
  return 60_000
}

function processRunning(proc) {
  return Boolean(proc && proc.exitCode === null && proc.signalCode === null)
}

function signalProcess(proc, signal = 'SIGTERM') {
  if (!processRunning(proc)) return false
  try {
    proc.kill(signal)
    return true
  } catch {
    return false
  }
}

async function waitForProcessExit(proc, name, { sigkillAfterMs = 3_000, timeoutMs = 8_000 } = {}) {
  if (!proc) return
  if (proc.exitCode !== null || proc.signalCode !== null) return
  await new Promise((resolve, reject) => {
    let settled = false
    let killTimer
    let timeoutTimer
    const finish = () => {
      if (settled) return
      settled = true
      clearTimeout(killTimer)
      clearTimeout(timeoutTimer)
      resolve()
    }
    proc.once('exit', finish)
    killTimer = setTimeout(() => {
      signalProcess(proc, 'SIGKILL')
    }, sigkillAfterMs)
    timeoutTimer = setTimeout(() => {
      if (settled) return
      settled = true
      clearTimeout(killTimer)
      reject(new Error(`[${name}] did not exit after SIGTERM/SIGKILL wait`))
    }, timeoutMs)
  })
}

// ─── LatticeNode ────────────────────────────────────────────────────────────

export class LatticeNode {
  constructor({ name, dir, port, rpcPort, chainPath = null, coinbaseAddress = null }) {
    this.name = name
    this.dir = dir
    this.port = port
    this.rpcPort = rpcPort
    this.coinbaseAddress = coinbaseAddress
    this.proc = null
    this._identity = null
    this._keypair = null
    this._logStream = null
    // Full chain path from Nexus root, e.g. ["Nexus","Mid","Stable"].
    // Set at construction for per-process nodes; null means this is the Nexus root.
    this._chainPath = chainPath
  }

  /** The chain path used in transactions submitted to this node. Null for root. */
  get chainPath() { return this._chainPath }

  get base() { return `http://127.0.0.1:${this.rpcPort}` }
  get logPath() { return `${this.dir}/../${this.name}.log` }

  // ── Lifecycle ──

  /** Boot this node. extraArgs are appended to the node command. */
  start(extraArgs = [], options = {}) {
    mkdirSync(this.dir, { recursive: true })
    // Pre-seed a stable identity so the node's --coinbase-address is known up
    // front; externally-mined blocks (Mechanism A) credit it, replacing the old
    // internal-miner self-coinbase. --min-fee-rate 0 disables the relay-only
    // per-byte fee floor for generic flat-fee scenarios. Both reused on restart.
    if (!this._keypair) {
      this._keypair = genKeypair()
      const rewardAddress = this.coinbaseAddress ?? this._keypair.address
      this._identity = {
        publicKey: this._keypair.publicKey,
        privateKey: this._keypair.privateKey,
        rewardAddress,
        coinbaseAddress: rewardAddress,
      }
      writeFileSync(`${this.dir}/identity.json`, JSON.stringify(this._identity))
    }
    const rewardAddress = this.coinbaseAddress ?? this._keypair.address
    const args = [
      'node',
      '--port', String(this.port),
      '--rpc-port', String(this.rpcPort),
      '--data-dir', this.dir,
      '--no-dns-seeds',
      ...devGenesisArgs(options.genesisTimestamp),
      '--coinbase-address', rewardAddress,
      '--min-fee-rate', '0',
      // Disable the peer-admission key-PoW gate (default 24 bits): the harness
      // uses random throwaway identities on a trusted loopback topology.
      '--min-peer-key-bits', '0',
      ...extraArgs,
    ]
    // Stash for waitForRPC's respawn-on-startup-crash path.
    this._startArgs = extraArgs
    this._startOptions = options
    this._exitInfo = null
    this._rpcCameUp = false
    this._logStream?.end()
    this._logStream = createWriteStream(this.logPath, { flags: 'a' })
    const proc = spawn(BIN, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, ...(options.env ?? {}) },
    })
    this.proc = proc
    proc.stdout.pipe(this._logStream)
    proc.stderr.pipe(this._logStream)
    // Record the exit so waitForRPC can fail fast (and respawn) on a startup crash
    // instead of polling a dead process to the deadline. Guard on proc identity so a
    // respawn's new process isn't clobbered by the old one's late exit event.
    proc.on('exit', (code, signal) => {
      console.log(`[${this.name}] exited code=${code}`)
      if (this.proc === proc) this._exitInfo = { code, signal }
    })
    return this
  }

  async stop() {
    const miner = this._miner
    if (miner) {
      this._miner = null
      miner.requestStop()
    }
    const proc = this.proc
    this.proc = null
    signalProcess(proc, 'SIGTERM')
    const results = await Promise.allSettled([
      miner ? miner.stop() : Promise.resolve(),
      waitForProcessExit(proc, this.name),
    ])
    const failed = results.find((r) => r.status === 'rejected')
    if (failed) throw failed.reason
    this._logStream?.end()
    this._logStream = null
  }

  requestStop() {
    this._miner?.requestStop()
    signalProcess(this.proc, 'SIGTERM')
  }

  async waitForRPC(timeoutMs = 30_000) {
    const deadline = scaledMs(timeoutMs)
    const startedAt = Date.now()
    let respawns = 0
    const maxRespawns = 2
    while (Date.now() - startedAt < deadline) {
      // A node that died before its RPC ever came up is a startup crash — typically
      // a transient resource race under suite CPU/disk contention. Respawn a bounded
      // number of times; a persistent crash exhausts the budget and fails FAST with
      // the log path, instead of polling a dead process to the full deadline (which
      // turned a ~5s crash into a 2-minute opaque "RPC up" timeout). Respawn ONLY in
      // the pre-first-success startup window: once this node's RPC has answered, a
      // later exit is a real mid-run crash and must surface, never be respawned.
      if (this._exitInfo) {
        const { code, signal } = this._exitInfo
        const how = `code=${code}${signal ? ` signal=${signal}` : ''}`
        if (!this._rpcCameUp && respawns < maxRespawns) {
          respawns += 1
          console.log(`[${this.name}] exited (${how}) before RPC up — respawn ${respawns}/${maxRespawns}`)
          this.start(this._startArgs, this._startOptions)
          await sleep(scaledMs(300))
          continue
        }
        const ctx = this._rpcCameUp ? 'after its RPC was up' : `before RPC came up after ${respawns} respawns`
        throw new Error(`${this.name} exited (${how}) ${ctx} — see ${this.logPath}`)
      }
      try {
        this.invalidateChainInfoCache()
        const r = await this.rpc('GET', '/api/chain/info', null, { timeoutMs: 1_000 })
        if (r.ok && r.json) {
          this._chainInfoCache = r.json
          this._chainInfoCacheTs = Date.now()
          this._rpcCameUp = true
          return r.json
        }
      } catch { /* RPC socket not up yet — keep polling */ }
      await sleep(300)
    }
    throw new Error(`timed out after ${deadline}ms: ${this.name} RPC up`)
  }

  async readIdentity() {
    if (this._identity) return this._identity
    this._identity = await waitFor(() => {
      try {
        const p = JSON.parse(readFileSync(`${this.dir}/identity.json`, 'utf8'))
        return p.publicKey ? p : null
      } catch { return null }
    }, `${this.name} identity`, { timeoutMs: 20_000, intervalMs: 200 })
    return this._identity
  }

  peerArg() {
    if (!this._identity) throw new Error(`${this.name}: call readIdentity() first`)
    return `${this._identity.publicKey}@127.0.0.1:${this.port}`
  }

  // ── Per-process child chain spawn ──────────────────────────────────────────
  //
  // Mirrors Swift deployChildChain + LatticeNode.init(prebuiltGenesisBlock):
  //   1. POST /api/chain/deploy → genesisHex + chainP2PAddress
  //   2. Start child process with --genesis-hex + --subscribe-p2p + --peer
  //
  /**
   * Deploy a child chain on this node IN-PROCESS (no separate process).
   * Returns the same node with knowledge of the child chain path.
   * Use this for tests that use the internal miner with merged mining.
   * The child chain runs inside THIS node process.
   */
  async deployInProcess(opts = {}) {
    const {
      directory,
      parentDirectory,
      targetBlockTime = 1000,
      initialReward = 1024,
      halvingInterval = 210_000,
      premine = 0,
      premineRecipient,
      maxTransactionsPerBlock = 100,
      maxStateGrowth = 100_000,
      maxBlockSize = 1_000_000,
      retargetWindow = 120,
      wasmPolicies = [],
      startMining = false,
    } = opts

    const ident = await this.readIdentity()
    const info = await this.chainInfo()
    const parentDir = parentDirectory ?? info.nexus
    const body = {
      directory, parentDirectory: parentDir,
      targetBlockTime, initialReward, halvingInterval, premine,
      maxTransactionsPerBlock, maxStateGrowth, maxBlockSize,
      retargetWindow, wasmPolicies,
      startMining,
    }
    if (premineRecipient) body.premineRecipient = premineRecipient

    // Retry on transient "Failed to deploy chain" — under parallel test load the
    // node's actor queue may not be ready immediately after waitForRPC().
    let r
    for (let attempt = 0; attempt < 5; attempt++) {
      r = await this.rpc('POST', '/api/chain/deploy', body)
      if (r.ok) break
      const isTransient = JSON.stringify(r.json).includes('Failed to deploy') || r.status === 500
      if (!isTransient) break
      await sleep(200 * (attempt + 1))
    }
    if (!r.ok) throw new Error(`deploy ${directory} on ${this.name} failed: ${JSON.stringify(r.json)}`)
    this.invalidateChainInfoCache()
    r.json._childDirectory = directory
    r.json._childParentDir = parentDir

    // Build the child chain path for submitTx convenience. If parentDirectory
    // is a known per-process child, use its stored path so grandchildren get
    // the correct full path (e.g. [nexus, Mid, Alpha]).
    const parentPath = (parentDir && this._childPaths?.[parentDir])
      ?? this._chainPath
      ?? [info.nexus]
    this._childPaths = this._childPaths ?? {}
    this._childPaths[directory] = [...parentPath, directory]

    return r.json  // returns deploy info including genesisHash, chainP2PAddress
  }

  /** Get the full chain path for a deployed per-process child. */
  childChainPath(directory) {
    return this._childPaths?.[directory] ?? null
  }

  /** submitTx to a deployed child chain using its full chain path. */
  async submitToChild(body, directory, keypair) {
    const childPath = this.childChainPath(directory)
    if (!childPath) throw new Error(`${directory} not deployed from ${this.name}`)
    return this.submitTx({ ...body, chainPath: childPath }, directory, keypair)
  }

  /**
   * Announce a child this node deployed into the parent's on-chain GenesisState so
   * OTHER nodes can permissionlessly discover it (deploy only pins/serves the
   * genesis — it does NOT write it to GenesisState; this genesisAction does).
   * Uses this node's coinbase keypair as the funder, so mining must be running to
   * accrue the fee. Pair with followChild() on the joiner.
   */
  async announceChild({ nexusDir, child, genesisHash, fee = 1000, minFunds = 5000, timeoutMs = 400_000 }) {
    const funder = this._keypair
    if (!funder) throw new Error(`${this.name}: start() the node before announceChild`)
    await waitFor(async () => (await this.balance(funder.address, nexusDir)) >= minFunds ? true : null,
      `${this.name} coinbase funded for ${child} announce`, { timeoutMs, intervalMs: 1000 })
    await waitFor(async () => {
      const base = await this.nonce(funder.address, nexusDir)
      const r = await this.submitTx({
        nonce: base, signers: [funder.address], fee,
        accountActions: [{ owner: funder.address, delta: -fee }],
        genesisActions: [{ directory: child, blockCID: genesisHash }],
      }, nexusDir, funder)
      return r.ok ? true : null
    }, `${this.name} submit ${child} genesisAction (announce)`, { timeoutMs: 60_000, intervalMs: 1000 })
    await waitFor(async () => {
      const r = await this.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
      const dirs = (r?.json?.children ?? []).map((c) => c.directory)
      return dirs.includes(child) ? true : null
    }, `${this.name} announced ${child} in GenesisState`, { timeoutMs: 300_000, intervalMs: 2000 })
  }

  /**
   * Permissionlessly JOIN a child chain this node did NOT deploy — the realistic
   * untrusted-joiner path (vs spawnChild, which hand-feeds genesis-hex + a peer).
   *
   * Discovers the child from THIS node's OWN synced GenesisState (no genesis-hex,
   * no peer, no subscribe-p2p hand-off), follows it (the reconciler self-resolves
   * the genesis from on-chain GenesisState + CAS by CID and boots a supervised
   * child), and the child finds a same-chain peer via getChildPeers over the parent
   * link. Requires this node to have been started with `--supervise-children`.
   *
   * Returns a lightweight handle over the supervised child's RPC endpoint with the
   * same height()/tip()/balance() shape as a LatticeNode, so convergence assertions
   * read identically whether the peer is a deployer or a permissionless joiner.
   */
  async followChild({ nexusDir, child, expectGenesis = null, timeoutMs = 240_000 } = {}) {
    const childPathStr = `${nexusDir}/${child}`
    // 1. Discover from OUR OWN synced GenesisState — not a query to the source node.
    await waitFor(async () => {
      const r = await this.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
      const dirs = (r?.json?.children ?? []).map((c) => c.directory)
      return dirs.includes(child) ? dirs : null
    }, `${this.name} discovered ${child} from synced GenesisState`, { timeoutMs, intervalMs: 2000 })
    // 2. Follow — NO genesis-hex / subscribe-p2p / peer supplied.
    const fol = await this.rpc('POST', '/api/chain/follow', { chainPath: [nexusDir, child] })
    if (!fol.ok) throw new Error(`${this.name} follow ${childPathStr} failed: ${JSON.stringify(fol.json)}`)
    // 3. The reconciler self-resolves genesis + spawns a supervised child, then
    //    registers its RPC endpoint in chain/map once up.
    let endpoint = null
    await waitFor(async () => {
      const m = await this.rpc('GET', '/api/chain/map').catch(() => null)
      const ep = m?.json?.[childPathStr]
      if (ep) { endpoint = ep; return true }
      return null
    }, `${this.name} spawned + registered followed ${child}`, { timeoutMs, intervalMs: 3000 })
    // 4. Verify the booted genesis (resolved from GenesisState) is the expected one.
    const info = async () => fetch(`${endpoint}/chain/info`).then((x) => x.json()).catch(() => null)
    const chainOf = (i) => i?.chains?.find((c) => c.directory === child) ?? null
    const genesis = (await info())?.genesisHash
    if (!genesis) throw new Error(`${this.name} followed ${child} reported no genesis (spawn/boot failed)`)
    if (expectGenesis && genesis !== expectGenesis) {
      throw new Error(`${this.name} ${child} booted genesis ${genesis} != expected ${expectGenesis} (wrong genesis resolution)`)
    }
    return {
      endpoint,
      genesis,
      directory: child,
      async height() { return chainOf(await info())?.height ?? 0 },
      async tip() { return chainOf(await info())?.tip ?? '' },
      async balance(addr) {
        const r = await fetch(`${endpoint}/balance/${addr}?chainPath=${encodeURIComponent(childPathStr)}`)
          .then((x) => x.json()).catch(() => null)
        return r?.balance ?? 0
      },
    }
  }

  /**
   * Fetch genesis hex for a child chain deployed on this node.
   * Alternative to getting it from the deploy response — useful when
   * bootstrapping from an existing deployment.
   */
  async fetchGenesisHex(directory) {
    const chainPath = this.childChainPath(directory) ?? [directory]
    const r = await this.rpc('GET', `/api/chain/genesis?chainPath=${encodeURIComponent(chainPath.join('/'))}`)
    if (!r.ok) throw new Error(`fetchGenesisHex(${directory}) failed: ${JSON.stringify(r.json)}`)
    return r.json.genesisHex
  }

  /** Deploy a child chain on this node and start it as a separate process. */
  async spawnChild(opts = {}) {
    const {
      directory,
      parentDirectory,
      ports,
      name = directory,
      targetBlockTime = 1000,
      initialReward = 1024,
      halvingInterval = 210_000,
      premine = 0,
      premineRecipient,
      maxTransactionsPerBlock = 100,
      maxStateGrowth = 100_000,
      maxBlockSize = 1_000_000,
      retargetWindow = 120,
      wasmPolicies = [],
      extraArgs = [],
    } = opts

    const ident = await this.readIdentity()
    const parentInfo = await this.chainInfo()
    // Build full chain path: parent's path + this directory.
    // Root nexus node has no _chainPath, so we resolve its directory from chain info.
    const parentDir2 = parentInfo?.nexus ?? directory
    const parentPath = this._chainPath ?? [parentDir2]
    const childFullPath = [...parentPath, directory]
    const body = {
      directory,
      parentDirectory: parentDirectory ?? parentPath[parentPath.length - 1],
      chainPath: childFullPath,
      targetBlockTime, initialReward, halvingInterval, premine,
      maxTransactionsPerBlock, maxStateGrowth, maxBlockSize,
      retargetWindow, wasmPolicies,
      startMining: false,
    }
    if (premineRecipient) body.premineRecipient = premineRecipient

    const r = await this.rpc('POST', '/api/chain/deploy', body)
    if (!r.ok) throw new Error(`deploy ${directory} on ${this.name} failed: ${JSON.stringify(r.json)}`)
    this.invalidateChainInfoCache()
    const { genesisHex, chainP2PAddress } = r.json
    if (!genesisHex) throw new Error(`deploy ${directory}: missing genesisHex`)
    const parentP2P = parentInfo.p2pAddress

    const childPorts = ports ?? (await allocPorts(1))[0]
    const childDir = `${this.dir}/../${name}`
    const child = new LatticeNode({
      name,
      dir: childDir,
      port: childPorts.port,
      rpcPort: childPorts.rpcPort,
      chainPath: childFullPath,
      coinbaseAddress: this.coinbaseAddress,
    })
    child.start([
      '--genesis-hex', genesisHex,
      '--chain-directory', directory,
      '--chain-path', childFullPath.join('/'),
      '--subscribe-p2p', parentP2P,
      '--peer', chainP2PAddress ?? parentP2P,
      ...extraArgs,
    ])
    await child.waitForRPC()
    child._deployInfo = r.json
    // Pre-load identity so callers can use child.peerArg() immediately
    // without a separate readIdentity() call.
    await child.readIdentity()
    // Register this child's RPC endpoint with the parent so chain/map works.
    const childAuthToken = readFileSync(`${child.dir}/.cookie`, 'utf8').trim()
    await this.rpc('POST', '/api/chain/register-rpc', {
      chainPath: childFullPath,
      endpoint: child.base,
      authToken: childAuthToken,
    })
    return child
  }

  // ── RPC ───────────────────────────────────────────────────────────────────

  async rpc(method, path, body, { timeoutMs = 30_000 } = {}) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const res = await fetch(`${this.base}${path}`, {
        method,
        headers: jsonRpcHeaders(this.dir, Boolean(body)),
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })
      let json
      try { json = await res.json() } catch { json = {} }
      if (res.ok && path.includes('/chain/deploy')) this.invalidateChainInfoCache()
      return { ok: res.ok, status: res.status, json }
    } catch (e) {
      return { ok: false, status: 0, json: { error: String(e) } }
    } finally {
      clearTimeout(timer)
    }
  }

  // ── Chain queries ─────────────────────────────────────────────────────────

  async chainInfo() {
    const now = Date.now()
    if (this._chainInfoCache && now - this._chainInfoCacheTs < 200) {
      return this._chainInfoCache
    }
    const r = await this.rpc('GET', '/api/chain/info')
    const info = r.ok ? r.json : null
    if (info) { this._chainInfoCache = info; this._chainInfoCacheTs = now }
    return info
  }

  invalidateChainInfoCache() { this._chainInfoCache = null }

  chainOf(info, dir) {
    return info?.chains?.find(c => c.directory === dir)
  }

  // Resolve a directory/path to the chainPath string a read query should send to THIS
  // node. A per-process child node has a multi-segment base path (e.g.
  // ["Root","FastTest"]); the node's selector prepends its base path to any
  // selector that doesn't already start at the base root, so sending the bare
  // leaf ("FastTest") would double it ("Root/FastTest/FastTest"). When the
  // requested directory is this node's own leaf, send the full base path.
  _queryPath(dirOrPath) {
    if (Array.isArray(dirOrPath)) return dirOrPath.join('/')
    if (this._chainPath && dirOrPath === this._chainPath[this._chainPath.length - 1]) {
      return this._chainPath.join('/')
    }
    return dirOrPath
  }

  async height(dir) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    return this.chainOf(info, d)?.height ?? 0
  }

  async tip(dir) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    return this.chainOf(info, d)?.tip ?? ''
  }

  async balance(addr, dir) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    const r = await this.rpc('GET', `/api/balance/${addr}?chainPath=${this._queryPath(d)}`)
    if (!r.ok) throw new Error(`balance(${d}) failed: ${JSON.stringify(r.json)}`)
    return r.json.balance ?? 0
  }

  async nonce(addr, dir) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    const r = await this.rpc('GET', `/api/nonce/${addr}?chainPath=${this._queryPath(d)}`)
    if (!r.ok) throw new Error(`nonce(${d}) failed: ${JSON.stringify(r.json)}`)
    return r.json.nonce ?? 0
  }

  async getDeposit(demander, amount, nonceHex, dir) {
    const r = await this.rpc('GET', `/api/deposit?demander=${demander}&amount=${amount}&nonce=${nonceHex}&chainPath=${this._queryPath(dir)}`)
    return r.json
  }

  async getReceipt(demander, amount, nonceHex, dir) {
    const r = await this.rpc('GET', `/api/receipt-state?demander=${demander}&amount=${amount}&nonce=${nonceHex}&chainPath=${this._queryPath(dir)}`)
    return r.json
  }

  async getFinality(dir) {
    const d = dir ?? (await this.chainInfo())?.nexus
    const r = await this.rpc('GET', `/api/finality?chainPath=${this._queryPath(d)}`)
    return r.ok ? r.json : null
  }

  // ── Mining ────────────────────────────────────────────────────────────────

  /**
   * Start producing blocks for this node's chain. The node never mines
   * in-process — this spawns the external mining coordinator bound to this node
   * (template fetch and work submission over RPC; publication is node-owned).
   * `childNodes` enables merged-mining of per-process
   * child chains. `dir` is accepted for backward-compat and ignored.
   */
  async startMining(dir, { childNodes = [], workers, batchSize } = {}) {
    if (this._miner) {
      await this._miner.start()
      return
    }
    await this.readIdentity()
    this._miner = new LatticeMiner(this, childNodes, { workers, batchSize })
    await this._miner.start()
  }

  async stopMining(dir) {
    if (!this._miner) return
    await this._miner.stop()
    this._miner = null
  }

  async mineUntil(check, dir, { childNodes = [], workers, batchSize, ...options } = {}) {
    await this.startMining(dir, { childNodes, workers, batchSize })
    return this._miner.mineUntil(check, options)
  }

  /** Mine until the chain reaches `targetHeight`, then stop. */
  async mineToHeight(targetHeight, dir, { timeoutMs = 300_000 } = {}) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    await this.mineUntil(async () => {
      const h = await this.height(d)
      return h >= targetHeight ? h : null
    }, d, {
      desc: `${this.name}/${d} height ≥ ${targetHeight}`,
      timeoutMs,
      intervalMs: 200,
      progress: () => this.height(d),
    })
    await this.stopMining(d)
    await this.awaitQuiesced(d)
    return this.height(d)
  }

  async awaitQuiesced(dir, { timeoutMs = 8_000, idleMs = 600 } = {}) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    const start = Date.now()
    let last = await this.height(d)
    while (Date.now() - start < timeoutMs) {
      await sleep(idleMs)
      const h = await this.height(d)
      if (h === last) return h
      last = h
    }
    return last
  }

  // Progress-based (height is a correctness invariant, not a latency bound): fails only
  // if production stalls (no new block for the stall window), so a slow-but-advancing
  // chain still passes. Legacy numeric 3rd/4th arg (old hard timeoutMs) → stall window.
  async waitForHeight(targetHeight, dir, opts = {}) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    const o = typeof opts === 'number' ? { stallMs: opts } : opts
    return waitForProgress(
      async () => this.height(d),
      (h) => h >= targetHeight,
      `${this.name}/${d} height ≥ ${targetHeight}`,
      { stallMs: o.stallMs ?? 30_000, safetyMs: o.safetyMs ?? 600_000, intervalMs: o.intervalMs ?? 500 },
    )
  }

  async waitForTip(expectedTip, dir, { timeoutMs = 60_000 } = {}) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    return waitFor(async () => {
      const t = await this.tip(d)
      return t === expectedTip ? t : null
    }, `${this.name}/${d} tip == ${expectedTip?.slice(0, 12)}…`, { timeoutMs, intervalMs: 500 })
  }

  // ── Transactions ──────────────────────────────────────────────────────────

  /**
   * Prepare + sign + submit a transaction.
   * keypair: { privateKey, publicKey }
   * body: { chainPath, nonce, signers, fee, accountActions?, ... }
   */
  async submitTx(body, dir, keypair) {
    const info = await this.chainInfo()
    const d = dir ?? info?.nexus
    // Auto-fill chainPath from this node's known full path if not provided.
    // External actors can submit using the full ancestral path (e.g. ["Nexus","Mid","Stable"])
    // directly to any per-process node.
    const bodyWithPath = body.chainPath
      ? body
      : { ...body, chainPath: this._chainPath ?? [d] }
    let prep
    for (let i = 0; i < 8; i++) {
      prep = await this.rpc('POST', '/api/transaction/prepare', bodyWithPath)
      if (prep.ok || !JSON.stringify(prep.json).includes('rate limit')) break
      await sleep(100 * (i + 1))
    }
    if (!prep.ok) throw new Error(`prepare(${d}) failed: ${JSON.stringify(prep.json)}`)
    const sig = signMsg(prep.json.signingPreimage ?? prep.json.bodyCID, keypair.privateKey)
    const sub = await this.rpc('POST', '/api/transaction', {
      signatures: { [keypair.publicKey]: sig },
      bodyCID: prep.json.bodyCID,
      bodyData: prep.json.bodyData,
      chainPath: bodyWithPath.chainPath,
    })
    return { ok: sub.ok, ...sub.json }
  }

  /**
   * Peer address string: "<pubkey>@127.0.0.1:<port>"
   * Requires readIdentity() to have been called.
   */
  p2pArg() { return this.peerArg() }
}

// ─── LatticeMiner compatibility wrapper ─────────────────────────────────────

export class LatticeMiner {
  /**
   * @param {LatticeNode} rootNode  — the Nexus node
   * @param {LatticeNode[]} childNodes — direct child chain nodes
   * @param {object} opts — workers, batchSize
   */
  constructor(rootNode, childNodes = [], opts = {}) {
    this.rootNode = rootNode
    this.childNodes = childNodes
    this.opts = opts
    this.proc = null
    this._logStream = null
    this._exit = null
  }

  get logPath() {
    return `${this.rootNode.dir}/../miner.log`
  }

  async start() {
    if (this.proc && this.proc.exitCode === null && this.proc.signalCode === null) return this
    if (this.proc) {
      await this.stop()
    }
    await this.rootNode.readIdentity()
    const args = [
      '--node', `${this.rootNode.base}/api`,
      // Default 1: the test genesis is max-target, so worker 0 satisfies PoW on its first
      // hash (nonce=0) — additional workers only burn CPU that contends with parallel
      // scenarios' nodes, slowing block production. Scenarios needing real parallel search
      // can still pass `{ workers: N }` explicitly.
      '--workers', String(this.opts.workers ?? 1),
      '--batch-size', String(this.opts.batchSize ?? 2000),
    ]
    if (this.opts.minBlockIntervalMs) {
      args.push('--min-block-interval-ms', String(this.opts.minBlockIntervalMs))
    }
    for (const child of this.childNodes) {
      args.push('--child-node', `${child.base}/api`)
      args.push('--child-rpc-cookie-file', `${child.dir}/.cookie`)
    }
    const identityPath = `${this.rootNode.dir}/identity.json`
    args.push('--identity-file', identityPath)
    args.push('--rpc-cookie-file', `${this.rootNode.dir}/.cookie`)
    this._logStream = createWriteStream(this.logPath, { flags: 'a' })
    this.proc = spawn(MINER_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
    this._exit = null
    this.proc.stdout.pipe(this._logStream)
    this.proc.stderr.pipe(this._logStream)
    const proc = this.proc
    this.proc.on('exit', (code, signal) => {
      this._exit = { code, signal, at: Date.now() }
      if (this.proc === proc) {
        this.proc = null
      }
      console.log(`[miner] exited code=${code}`)
    })
    return this
  }

  get running() {
    return Boolean(this.proc && this.proc.exitCode === null && this.proc.signalCode === null)
  }

  requestStop() {
    signalProcess(this.proc, 'SIGTERM')
  }

  async stop({ timeoutMs = 5_000 } = {}) {
    if (!this.proc) return
    const proc = this.proc
    this.proc = null
    const waitForExit = async (ms) => {
      if (proc.exitCode !== null || proc.signalCode !== null) return true
      return Promise.race([
        new Promise(resolve => proc.once('exit', () => resolve(true))),
        sleep(ms).then(() => false),
      ])
    }
    signalProcess(proc, 'SIGTERM')
    if (!(await waitForExit(timeoutMs))) {
      signalProcess(proc, 'SIGKILL')
      if (!(await waitForExit(2_000))) {
        throw new Error('miner coordinator did not exit after SIGKILL')
      }
    }
    this._logStream?.end()
    this._logStream = null
  }

  async restart() {
    await this.stop()
    await sleep(500)
    return this.start()
  }

  // Progress-based: when a `progress` metric is supplied, the chain advancing resets the
  // stall window, so a slow-but-advancing run under CPU contention NEVER times out — only
  // a genuine stall (no forward progress for `stallMs`, even after `maxStallRestarts`
  // miner kicks) fails. `timeoutMs` is now only an absolute safety-net backstop against a
  // livelock that progresses forever without satisfying `check` (was a hard wall-clock cap
  // that false-failed correct-but-slow runs — the #1 integration-test flake cause).
  async mineUntil(check, {
    desc = 'mining condition',
    timeoutMs = 600_000,
    intervalMs = 500,
    stallMs = defaultMinerStallMs(this.childNodes.length),
    maxStallRestarts = 3,
    progress = null,
  } = {}) {
    await this.start()
    const start = Date.now()
    const safetyDeadline = scaledMs(timeoutMs)
    const stallDeadline = scaledMs(stallMs)
    let lastProgress = progress ? await progress() : null
    let lastAdvance = Date.now()
    let restarts = 0
    while (true) {
      const value = await check()
      // Zero can be a successful observed value (for example, a drained mempool).
      // Reserve null/undefined/false for "keep waiting".
      if (value !== null && value !== undefined && value !== false) return value
      const now = Date.now()
      if (!this.running) {
        await this.start()
        lastAdvance = now
      } else if (progress) {
        const current = await progress()
        if (current !== lastProgress) {
          lastProgress = current
          lastAdvance = now
          restarts = 0
        } else if (now - lastAdvance > stallDeadline) {
          if (restarts < maxStallRestarts) {
            console.log(`[miner] stalled while waiting for ${desc}; restarting (${restarts + 1}/${maxStallRestarts})`)
            await this.restart()
            lastAdvance = now
            restarts++
          } else {
            throw new Error(`stalled: ${desc} — no forward progress for ${stallDeadline}ms across ${restarts} miner restarts`)
          }
        }
      }
      if (now - start > safetyDeadline) {
        throw new Error(`safety-net timeout: ${desc} after ${safetyDeadline}ms`)
      }
      await sleep(intervalMs)
    }
  }
}

// ─── LatticeNetwork ─────────────────────────────────────────────────────────

/**
 * Manages a set of nodes with centralised teardown.
 * Registers SIGINT / uncaughtException handlers automatically.
 */
export class LatticeNetwork {
  constructor(nodes = []) {
    this.nodes = nodes
    this._miners = []
    this._installed = false
  }

  add(node) { this.nodes.push(node); return node }
  addMiner(miner) { this._miners.push(miner); return miner }

  async teardown() {
    // Async functions run synchronously until the first await. Signal everything
    // up front so legacy call sites that omit `await` still trigger deterministic
    // cleanup before a nearby process.exit().
    for (const m of this._miners) m.requestStop()
    for (const n of this.nodes) n.requestStop()
    await Promise.allSettled(this._miners.map((m) => m.stop()))
    await Promise.allSettled(this.nodes.map((n) => n.stop()))
    this._miners = []
  }

  installSignalHandlers() {
    if (this._installed) return
    this._installed = true
    process.on('SIGINT', () => { void this.teardown().finally(() => process.exit(1)) })
    process.on('uncaughtException', e => {
      console.error('UNCAUGHT EXCEPTION:', e.stack || e)
      void this.teardown().finally(() => process.exit(1))
    })
    process.on('unhandledRejection', (reason) => {
      console.error('UNHANDLED REJECTION:', reason?.stack || reason)
      void this.teardown().finally(() => process.exit(1))
    })
  }
}

// ─── Convenience factory ─────────────────────────────────────────────────────

/**
 * Create a fresh test root, build a LatticeNetwork, and install signal handlers.
 * Usage:
 *   const { net, root } = await latticeTest('my-test', { nodes: [{ name: 'A', ... }] })
 */
import { smokeRoot } from './env.mjs'
import { rmSync } from 'node:fs'

export async function latticeTest(testName, { nodes = [] } = {}) {
  const ROOT = smokeRoot(testName)
  rmSync(ROOT, { recursive: true, force: true })
  mkdirSync(ROOT, { recursive: true })

  const net = new LatticeNetwork()
  net.installSignalHandlers()

  const built = []
  for (const n of nodes) {
    const ports = n.ports ?? (await allocPorts(1))[0]
    const node = new LatticeNode({
      name: n.name,
      dir: `${ROOT}/${n.name}`,
      port: ports.port,
      rpcPort: ports.rpcPort,
    })
    net.add(node)
    built.push(node)
  }

  return { net, nodes: built, ROOT }
}

// ─── Re-export lower-level helpers for tests that need them ──────────────────
export { sleep, waitFor, waitForProgress } from './waitFor.mjs'
export { genKeypair, computeAddress, sign } from './wallet.mjs'
export { submitTx } from './tx.mjs'
export { dirSizeBytes, rssBytes, peerCount, peers } from './probe.mjs'
