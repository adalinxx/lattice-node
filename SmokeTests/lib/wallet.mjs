// Keypair + address derivation matching lattice-node's CryptoUtils.
//
// Algorithm: Ed25519 (Curve25519.Signing) — NOT secp256k1
// Private key: raw 32-byte seed, hex-encoded
// Public key:  Multikey encoding: 0xed 0x01 + 32 raw pubkey bytes, hex-encoded
// Sign:        ed25519_sign(message.utf8, privKey)  — no SHA256 prehash
//
// Address = CIDv1(dag_cbor, sha256(DagCBOR({"key":"<pubkeyHex>"})))
//   DagCBOR: JSON → CBOR with map keys sorted by byte-length then lex (cashew's sort)

import * as ed from '@noble/ed25519'
import { sha256 } from '@noble/hashes/sha256'
import { sha512 } from '@noble/hashes/sha512'
import { bytesToHex, hexToBytes, randomBytes } from '@noble/hashes/utils'

// noble/ed25519 requires hashes.sha512 to be set for sync operations
ed.hashes.sha512 = sha512

const BASE32 = 'abcdefghijklmnopqrstuvwxyz234567'

function base32Encode(bytes) {
  let bits = 0, value = 0, out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) { bits -= 5; out += BASE32[(value >>> bits) & 0x1f] }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 0x1f]
  return out
}

// DAG-CBOR encoder matching cashew's DagCBOR.serializeValue:
// map keys sorted by UTF-8 byte length, then lexicographically.
function cborEncode(value) {
  const out = []
  function uint(n, major) {
    const mt = major << 5
    if (n < 24)        out.push(mt | n)
    else if (n < 256)  out.push(mt | 24, n)
    else if (n < 65536) out.push(mt | 25, n >> 8, n & 0xff)
    else               out.push(mt | 26, (n>>>24)&0xff, (n>>>16)&0xff, (n>>>8)&0xff, n&0xff)
  }
  function enc(v) {
    if (v === null)              { out.push(0xf6) }
    else if (typeof v === 'boolean') { out.push(v ? 0xf5 : 0xf4) }
    else if (typeof v === 'number') {
      if (Number.isInteger(v))  { v >= 0 ? uint(v, 0) : uint(~v, 1) }
      else {
        out.push(0xfb)
        const b = new ArrayBuffer(8)
        new DataView(b).setFloat64(0, v, false)
        out.push(...new Uint8Array(b))
      }
    }
    else if (typeof v === 'string') {
      const b = new TextEncoder().encode(v)
      uint(b.length, 3); out.push(...b)
    }
    else if (Array.isArray(v)) {
      uint(v.length, 4); v.forEach(enc)
    }
    else {
      const keys = Object.keys(v).sort((a, b) => {
        const la = new TextEncoder().encode(a).length
        const lb = new TextEncoder().encode(b).length
        return la !== lb ? la - lb : (a < b ? -1 : a > b ? 1 : 0)
      })
      uint(keys.length, 5)
      for (const k of keys) {
        const kb = new TextEncoder().encode(k)
        uint(kb.length, 3); out.push(...kb); enc(v[k])
      }
    }
  }
  enc(value)
  return new Uint8Array(out)
}

export function computeAddress(publicKeyHex) {
  const digest = sha256(cborEncode({ key: publicKeyHex }))
  const cid = new Uint8Array(4 + digest.length)
  cid[0] = 0x01; cid[1] = 0x71; cid[2] = 0x12; cid[3] = 0x20
  cid.set(digest, 4)
  return 'b' + base32Encode(cid)
}

// Sign the domain-separated payload with Ed25519 — NO SHA256 prehash. Mirrors
// CryptoUtils.signaturePayload: the signed bytes are `signatureDomain.utf8 +
// message.utf8`, where signatureDomain is "lattice-tx-v1:".
const SIGNATURE_DOMAIN = 'lattice-tx-v1:'
export function sign(message, privateKeyHex) {
  const msgBytes = new TextEncoder().encode(SIGNATURE_DOMAIN + message)
  const privBytes = hexToBytes(privateKeyHex)
  const sig = ed.sign(msgBytes, privBytes)  // returns Uint8Array (sync via sha512Sync hook)
  return bytesToHex(sig)
}

export function genKeypair() {
  const privBytes = randomBytes(32)
  const privateKey = bytesToHex(privBytes)
  const pubBytes = ed.getPublicKey(privBytes)            // sync via sha512Sync hook
  // Multikey encoding: 0xed 0x01 + raw 32-byte Ed25519 public key
  const mk = new Uint8Array(2 + pubBytes.length)
  mk[0] = 0xed; mk[1] = 0x01; mk.set(pubBytes, 2)
  const publicKey = bytesToHex(mk)
  return { privateKey, publicKey, address: computeAddress(publicKey) }
}
