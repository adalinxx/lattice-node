import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { singleNode } from 'lattice-node-sdk/node'
import { sleep } from 'lattice-node-sdk/waitFor'
import { chainInfo, startMining } from 'lattice-node-sdk/chain'

const ROOT = smokeRoot('repro-crash')
const [{ port, rpcPort }] = await allocPorts(1, { seed: 99 })
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const info = await chainInfo(node)
const nexusDir = info.nexus
console.log(`mining nexus=${nexusDir}, watching for crash. logs: ${ROOT}`)
await startMining(node, nexusDir)

for (let i = 0; i < 180; i++) {
  await sleep(2000)
  const ci = await chainInfo(node).catch(() => null)
  const h = ci?.chains?.[0]?.height
  console.log(`t=${i * 2}s height=${h ?? 'UNREACHABLE'}`)
  if (ci === null || h === undefined) {
    console.log('NODE UNREACHABLE — crashed. See node log in ' + ROOT)
    break
  }
}
process.exit(0)
