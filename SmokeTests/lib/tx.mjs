// Transaction submission: prepare → sign → submit. Wrapped so scenarios stop
// reimplementing the three-step dance and the bodyCID/bodyData plumbing.

import { sign } from './wallet.mjs'
import { sleep } from './waitFor.mjs'

// keypair: { privateKey, publicKey }
// chain: target chain directory (string)
// body: { chainPath, nonce, signers, fee, accountActions?, depositActions?, receiptActions?, withdrawalActions? }
export async function submitTx(node, body, chain, keypair) {
  let prep
  for (let attempt = 0; attempt < 8; attempt++) {
    prep = await node.rpc('POST', '/api/transaction/prepare', body)
    if (prep.ok || !JSON.stringify(prep.json).includes('rate limit')) break
    await sleep(100 * (attempt + 1))
  }
  if (!prep.ok) throw new Error(`prepare(${chain}) failed: ${JSON.stringify(prep.json)}`)
  const signature = sign(prep.json.signingPreimage ?? prep.json.bodyCID, keypair.privateKey)
  const sub = await node.rpc('POST', '/api/transaction', {
    signatures: { [keypair.publicKey]: signature },
    bodyCID: prep.json.bodyCID,
    bodyData: prep.json.bodyData,
    chainPath: body.chainPath,
  })
  return { prepared: prep.json, submit: sub.json, ok: sub.ok }
}
