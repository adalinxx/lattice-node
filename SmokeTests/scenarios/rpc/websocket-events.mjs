// WebSocket/SSE events: connect to /ws, mine a block, verify newBlock
// event arrives. Then submit a tx and verify newTransaction event.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep, waitFor } from 'lattice-node-sdk/waitFor'
import { genKeypair, computeAddress } from 'lattice-node-sdk/wallet'
import {
  chainInfo, getNonce, startMining, stopMining, awaitMiningQuiesced,
  waitForHeight, mineBurst,
} from 'lattice-node-sdk/chain'
import { submitTx } from 'lattice-node-sdk/tx'
import http from 'node:http'

const ROOT = smokeRoot('websocket-events')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 85 })

console.log('=== websocket-events smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

function fail(m) { console.error(`  ✗ ${m}`); node.stop(); process.exit(1) }
const isNewBlock = (e) => e.type === 'newBlock' || e.event === 'newBlock' || e.eventType === 'newBlock' || typeof e?.data?.height === 'number'
const isNewTx = (e) => e.type === 'newTransaction' || e.event === 'newTransaction' || e.eventType === 'newTransaction' || !!(e.txCID || e?.data?.txCID || e?.data?.cid)

function collectSSE(url, durationMs) {
  return new Promise((resolve) => {
    const events = []
    const req = http.get(url, (res) => {
      let buf = ''
      res.on('data', (chunk) => {
        buf += chunk.toString()
        const lines = buf.split('\n')
        buf = lines.pop()
        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try { events.push(JSON.parse(line.slice(6))) } catch {}
          }
        }
      })
    })
    req.on('error', () => {})
    setTimeout(() => { req.destroy(); resolve(events) }, durationMs)
  })
}

console.log('\n[1] Connect to SSE stream, mine, check for newBlock...')
const blockPromise = collectSSE(`${node.base}/ws`, 10000)
await sleep(500)
await mineBurst(node, nexusDir)
const blockEvents = await blockPromise
const newBlocks = blockEvents.filter(isNewBlock)
console.log(`  SSE events received: ${blockEvents.length} total, ${newBlocks.length} newBlock`)
if (newBlocks.length < 1) fail(`no newBlock event delivered over /ws while mining (got ${blockEvents.length} events)`) // REQUIRED: zero must fail
const blkHeight = newBlocks[0].data?.height ?? newBlocks[0].height
if (typeof blkHeight !== 'number') fail(`newBlock event missing a numeric height: ${JSON.stringify(newBlocks[0]).slice(0, 160)}`)
console.log(`  ✓ newBlock event delivered (height=${blkHeight})`)

console.log('\n[2] Submit tx during SSE stream, check for newTransaction...')
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const txPromise = collectSSE(`${node.base}/ws`, 8000)
await sleep(500)

const recipient = genKeypair()
const nonce = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: recipient.address, delta: 100 },
  ],
}, nexusDir, minerKP)

await startMining(node, nexusDir)
await sleep(3000)

const txEvents = await txPromise
const newTxs = txEvents.filter(isNewTx)
console.log(`  SSE events: ${txEvents.length} total, ${newTxs.length} newTransaction`)
if (newTxs.length < 1) fail(`no newTransaction event delivered over /ws after submitting a tx (got ${txEvents.length} events)`) // REQUIRED
console.log(`  ✓ newTransaction event delivered`)

console.log('\n[3] Verify /ws endpoint responds...')
let wsStatus = 0
try {
  const ctrl = new AbortController()
  const res = await fetch(`${node.base}/ws`, { signal: ctrl.signal })
  wsStatus = res.status
  ctrl.abort()
} catch (e) {
  if (e.name !== 'AbortError' && wsStatus === 0) {
    throw new Error(`/ws endpoint unreachable: ${e.message}`)
  }
}
if (wsStatus !== 200) throw new Error(`Expected /ws status 200, got ${wsStatus}`)
console.log(`  /ws status: ${wsStatus}`)
console.log(`  ✓ /ws endpoint reachable`)

console.log('\n✓ websocket-events smoke test passed.')
await node.stop()

await sleep(500)
process.exit(0)
