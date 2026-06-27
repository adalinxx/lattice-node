// Depth-4 merged mining: a 4-level-deep LINEAR child hierarchy
// (Nexus → C1 → C2 → C3 → C4) must all advance under a single merged miner, and a tx
// at the DEEPEST chain must settle. multidepth-swap reaches depth-3 (ChainG); this
// validates the depth-general self-similarity one level deeper — every level's blocks
// are carried/proven up to the absolute root and secured by the same PoW, so a depth-4
// chain is not a special case. If the carrier/proof recursion had a depth limit, C4
// would never advance (or its tx would never settle).

import { rmSync, mkdirSync, readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, sleep, waitForProgress, genKeypair, computeAddress } from 'lattice-node-sdk'

const ROOT = smokeRoot('depth4-merged-mining')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [{ port, rpcPort }] = await allocPorts(1, { seed: 241 })

console.log('=== depth4-merged-mining smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()
const funder = genKeypair()
const user = genKeypair()
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port, rpcPort, coinbaseAddress: funder.address }))
node.start()
await node.waitForRPC()
await node.readIdentity()
const NEXUS = (await node.chainInfo()).nexus
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }

const fastChildSpec = { targetBlockTime: 1 }
const premineUnits = 5
const C1 = 'ChainC1', C2 = 'ChainC2', C3 = 'ChainC3', C4 = 'ChainC4'

async function registerWithNexus(child) {
  const authToken = readFileSync(`${child.dir}/.cookie`, 'utf8').trim()
  const r = await node.rpc('POST', '/api/chain/register-rpc', { chainPath: child.chainPath, endpoint: child.base, authToken })
  if (!r.ok) fail(`register ${child.name} failed: ${JSON.stringify(r.json)}`)
}

// [1] Build the linear depth-4 hierarchy (each child's parent is the level above).
console.log('\n[1] Deploy linear hierarchy Nexus → C1 → C2 → C3 → C4...')
const n1 = net.add(await node.spawnChild({ directory: C1, parentDirectory: NEXUS, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const n2 = net.add(await n1.spawnChild({ directory: C2, parentDirectory: C1, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const n3 = net.add(await n2.spawnChild({ directory: C3, parentDirectory: C2, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const n4 = net.add(await n3.spawnChild({ directory: C4, parentDirectory: C3, premine: premineUnits, premineRecipient: user.address, ...fastChildSpec }))
const children = [n1, n2, n3, n4]
for (const c of children) await registerWithNexus(c)
const chainNode = { [NEXUS]: node, [C1]: n1, [C2]: n2, [C3]: n3, [C4]: n4 }

// [2] Topology: C4 must genuinely be depth-4 (path = [Nexus, C1, C2, C3, C4]).
console.log('\n[2] Verify depth-4 topology...')
for (const [dir, parent] of [[C1, NEXUS], [C2, C1], [C3, C2], [C4, C3]]) {
  const chain = (await chainNode[dir].chainInfo()).chains.find(c => c.directory === dir)
  if (chain?.parentDirectory !== parent) fail(`${dir}.parentDirectory = ${chain?.parentDirectory}, expected ${parent}`)
}
console.log(`  C4 path: ${JSON.stringify(n4.chainPath)} (depth ${n4.chainPath.length - 1})`)
if (n4.chainPath.length !== 5) fail(`C4 is not depth-4 (path length ${n4.chainPath.length}, expected 5)`)
console.log('  ✓ depth-4 topology correct')

// [3] One merged miner must advance ALL five levels, including depth-4 C4.
console.log('\n[3] Merged-mine; require all 5 levels (incl. depth-4 C4) to advance...')
await node.startMining(NEXUS, { childNodes: children })
await waitForProgress(
  async () => Math.min(...await Promise.all([NEXUS, C1, C2, C3, C4].map((d) => chainNode[d].height(d)))),
  (minH) => minH >= 3,
  'all 5 levels (incl. depth-4) reach height ≥ 3',
  { stallMs: 120_000, intervalMs: 500 },
)
const heights = await Promise.all([NEXUS, C1, C2, C3, C4].map((d) => chainNode[d].height(d)))
console.log(`  heights: Nexus=${heights[0]} C1=${heights[1]} C2=${heights[2]} C3=${heights[3]} C4=${heights[4]}`)
if (heights[4] < 3) fail(`depth-4 C4 did not advance (height ${heights[4]})`)
console.log('  ✓ all five levels advanced under one merged miner')

// [4] A tx at the DEEPEST chain (C4) must settle — depth-4 state transitions are live.
console.log('\n[4] Settle a tx at depth-4 (C4)...')
const userC4 = await n4.balance(user.address, C4)
if (userC4 < 100) fail(`user has no spendable premine on C4 (balance ${userC4})`)
const recip = genKeypair()
const c4Nonce = await n4.nonce(user.address, C4)
const txR = await n4.submitTx({ nonce: c4Nonce, signers: [user.address], fee: 1, accountActions: [{ owner: user.address, delta: -101 }, { owner: recip.address, delta: 100 }] }, C4, user)
if (!txR.ok) fail(`depth-4 tx rejected: ${JSON.stringify(txR)}`)
await waitForProgress(async () => n4.balance(recip.address, C4), (b) => b >= 100, 'depth-4 tx settles', { stallMs: 90_000, intervalMs: 500 })
await node.stopMining(NEXUS)
console.log(`  ✓ depth-4 tx settled: recipient balance = ${await n4.balance(recip.address, C4)}`)

console.log('\n✓ depth4-merged-mining smoke test passed.')
net.teardown(); await sleep(500); process.exit(0)
