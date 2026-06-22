// Process + disk + peer-count probes. Used by stability and stateless-follower
// scenarios that assert resource invariants alongside chain progress.

import { execSync } from 'node:child_process'

export function dirSizeBytes(path) {
  const out = execSync(`du -sk "${path}"`).toString().trim().split(/\s+/)[0]
  return Number(out) * 1024
}

export function rssBytes(pid) {
  const out = execSync(`ps -o rss= -p ${pid}`).toString().trim()
  return Number(out) * 1024
}

export async function peerCount(node) {
  const r = await node.rpc('GET', '/api/peers')
  if (!r.ok) return 0
  if (typeof r.json.count === 'number') return r.json.count
  if (Array.isArray(r.json.peers)) return r.json.peers.length
  return 0
}

// The victim's connected peers as { publicKey, host, port } objects (publicKey
// is truncated to a 16-hex prefix by the node). A peer still mid-identify is
// listed under a temporary `inbound-<uuid>` id with host "unknown"; only after
// identify clears is it re-keyed to its real public key. Callers that need to
// distinguish a genuinely admitted peer from a transient pre-identify dial use
// this instead of `peerCount`.
export async function peers(node) {
  const r = await node.rpc('GET', '/api/peers')
  if (!r.ok || !Array.isArray(r.json.peers)) return []
  return r.json.peers
}
