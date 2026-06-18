// Compatibility API for older smoke scenarios. The implementation lives in
// lattice.mjs; this file only adapts the old Node/Network names.

import { existsSync, mkdirSync, rmSync } from 'node:fs'
import { sleep } from './waitFor.mjs'
import { LatticeNode, LatticeNetwork } from './lattice.mjs'

function nodeArgs(extras) {
  if (Array.isArray(extras)) return extras
  const args = []
  for (const peer of extras.peers ?? []) {
    args.push('--peer', typeof peer === 'string' ? peer : peer.peerArg())
  }
  for (const sub of extras.subscribe ?? []) args.push('--subscribe', sub)
  if (extras.extraArgs) args.push(...extras.extraArgs)
  return args
}

export class Node extends LatticeNode {
  start(extras = []) {
    if (Array.isArray(extras)) return super.start(extras)
    return super.start(nodeArgs(extras), {
      env: extras.env,
      genesisTimestamp: extras.genesisTimestamp,
    })
  }

  get pid() {
    return this.proc?.pid ?? null
  }

  async stopAndAwaitShutdown({ timeoutMs = 30_000 } = {}) {
    await this.stop()
    const start = Date.now()
    while (Date.now() - start < timeoutMs) {
      try {
        await fetch(`${this.base}/api/chain/info`, { signal: AbortSignal.timeout(500) })
      } catch {
        return
      }
      await sleep(500)
    }
    throw new Error(`${this.name} failed to shut down within ${timeoutMs}ms`)
  }

  async restart(extras) {
    await this.stopAndAwaitShutdown()
    return this.start(extras)
  }
}

export class Network extends LatticeNetwork {
  constructor({ root, nodes }) {
    super(nodes.map((n) => new Node({ ...n, dir: `${root}/${n.name}` })))
    this.root = root
  }

  static fresh(opts) {
    rmSync(opts.root, { recursive: true, force: true })
    mkdirSync(opts.root, { recursive: true })
    const net = new Network(opts)
    net.installSignalHandlers()
    return net
  }

  byName(name) {
    const node = this.nodes.find((n) => n.name === name)
    if (!node) throw new Error(`no node named ${name}`)
    return node
  }
}

export function singleNode({ root, name = 'node', port, rpcPort }) {
  if (existsSync(root)) rmSync(root, { recursive: true, force: true })
  const net = Network.fresh({ root, nodes: [{ name, port, rpcPort }] })
  return net.byName(name)
}
