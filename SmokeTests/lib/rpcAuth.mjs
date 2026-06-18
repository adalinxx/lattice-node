import { existsSync, readFileSync } from 'node:fs'

export function rpcAuthHeaders(dir) {
  const cookiePath = `${dir}/.cookie`
  if (!existsSync(cookiePath)) return {}
  const token = readFileSync(cookiePath, 'utf8').trim()
  return token ? { Authorization: `Bearer ${token}` } : {}
}

export function jsonRpcHeaders(dir, hasBody = false) {
  return {
    ...(hasBody ? { 'content-type': 'application/json' } : {}),
    ...rpcAuthHeaders(dir),
  }
}
