import Lattice
import Foundation
import Crypto
import _CryptoExtras
import Ivy
import Tally

struct IdentityFile: Codable {
    let publicKey: String
    let privateKey: String?
    let encryptedPrivateKey: String?
    let salt: String?
}

enum IdentityError: Error {
    case decryptionFailed
    case missingPrivateKey
    case invalidKeyData
}

/// Key-work bits of an identity public key under the EXACT measure the Ivy
/// identify gate applies to peers (`KeyDifficulty.trailingZeroBits` of the key
/// string presented on the wire). The node presents the raw 32-byte hex key
/// (`LatticeNodeConfig.p2pPublicKey` strips the `ed01` Multikey prefix), so the
/// measure must be taken on the stripped form — the prefixed string hashes to an
/// unrelated value. Delegates to the single shared implementation so the
/// identity grind and the outbound peer-diversity filter can never diverge.
func identityKeyWorkBits(of publicKey: String) -> Int {
    KeyDifficulty.keyWorkBits(publicKey)
}

/// Grind a Curve25519 keypair whose raw hex public key meets `minBits` under the
/// Ivy gate's measure. `Ivy.generateKey(targetDifficulty:)` is total as of Ivy
/// 6.0.0 — it grinds until a conforming key is found, so no retry loop or
/// exhaustion handling is needed here.
func grindWorkedIdentityKey(minBits: Int) -> (publicKey: String, privateKey: Data) {
    Ivy.generateKey(targetDifficulty: minBits)
}

/// Write a private-key-bearing file atomically with 0600 from creation: content
/// lands in a same-directory temp file opened `O_CREAT|O_EXCL|O_WRONLY, 0o600`
/// — the file is BORN owner-only, unlike `FileManager.createFile(attributes:)`,
/// whose write-then-chmod implementation exposes a default-umask (0644) window
/// mid-write — then renamed over the destination, so no reader ever sees a
/// partial file or a permissions window. Fails closed: any error unlinks the
/// temp and throws; a partial file is never left behind.
func writePrivateKeyFile(_ data: Data, to path: URL) throws {
    let dir = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    #if os(Windows)
    try data.write(to: path, options: .atomic)
    #else
    let tmp = dir.appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)")
    let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }

    let wroteAll = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        guard let base = buf.baseAddress else { return buf.isEmpty }
        var offset = 0
        while offset < buf.count {
            let n = write(fd, base + offset, buf.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
    let closed = close(fd) == 0

    guard wroteAll, closed, rename(tmp.path, path.path) == 0 else {
        unlink(tmp.path)
        throw CocoaError(.fileWriteUnknown)
    }
    #endif
}

/// Whether a usable, current-bits identity is already on disk so the caller can
/// tell, before booting, whether `loadOrCreateIdentity` will block on a grind.
/// Mirrors the reuse condition in `loadOrCreateIdentity`: a persisted identity
/// that meets the CURRENT `minKeyBits` (or `minKeyBits == 0`) is reusable; the
/// `LATTICE_PRIVATE_KEY` env override is always instant. Used by the daemon to
/// decide whether to grind in the background and to log the right message while
/// it boots the rest of the node (#243: a cold first boot must not block RPC on
/// the multi-minute 24-bit grind any longer than necessary).
func identityGrindRequired(dataDir: URL, minKeyBits: Int) -> Bool {
    if minKeyBits == 0 { return false }
    if ProcessInfo.processInfo.environment["LATTICE_PRIVATE_KEY"] != nil { return false }
    let path = dataDir.appendingPathComponent("identity.json")
    guard FileManager.default.fileExists(atPath: path.path),
          let data = try? Data(contentsOf: path),
          let identity = try? JSONDecoder().decode(IdentityFile.self, from: data) else {
        // No identity yet → fresh grind needed.
        return true
    }
    return identityKeyWorkBits(of: identity.publicKey) < minKeyBits
}

/// Load — or create — the node's main identity. `minKeyBits`  is the
/// configured `minPeerKeyBits`: every remote default-config node gates OUR
/// identify key on it, so the identity must be ground to at least that many
/// key-work bits or the node cannot peer. A persisted identity that meets the
/// CURRENT bits is reused as-is; one that no longer does (stale/under-ground
/// after a raise) is discarded and reground — pre-testnet, identity churn is
/// acceptable. `minKeyBits == 0` preserves the legacy behavior exactly (never
/// grinds, never discards).
func loadOrCreateIdentity(dataDir: URL, password: String? = nil, minKeyBits: Int = 0) throws -> IdentityFile {
    if let privateKey = ProcessInfo.processInfo.environment["LATTICE_PRIVATE_KEY"],
       let privateKeyData = Data(hex: privateKey),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) {
        let publicKey = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return IdentityFile(publicKey: publicKey, privateKey: privateKey, encryptedPrivateKey: nil, salt: nil)
    }

    let path = dataDir.appendingPathComponent("identity.json")
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        let identity = try JSONDecoder().decode(IdentityFile.self, from: data)

        let bits = identityKeyWorkBits(of: identity.publicKey)
        if minKeyBits == 0 || bits >= minKeyBits {
            // Re-assert key-at-rest hygiene on the reuse path.
            #if !os(Windows)
            chmod(path.path, 0o600)
            #endif

            // If file has encrypted key but no plaintext, decrypt it
            if identity.privateKey == nil, let encrypted = identity.encryptedPrivateKey, let saltHex = identity.salt {
                guard let password else { throw IdentityError.missingPrivateKey }
                let decrypted = try decryptKey(encrypted: encrypted, saltHex: saltHex, password: password)
                return IdentityFile(publicKey: identity.publicKey, privateKey: decrypted, encryptedPrivateKey: encrypted, salt: saltHex)
            }

            // Migrate: if plaintext key exists and password provided, encrypt it
            if let privKey = identity.privateKey, let password, !password.isEmpty {
                let (encrypted, salt) = try encryptKey(privateKey: privKey, password: password)
                let upgraded = IdentityFile(publicKey: identity.publicKey, privateKey: nil, encryptedPrivateKey: encrypted, salt: salt)
                let encoded = try JSONEncoder().encode(upgraded)
                try writePrivateKeyFile(encoded, to: path)
                return IdentityFile(publicKey: identity.publicKey, privateKey: privKey, encryptedPrivateKey: encrypted, salt: salt)
            }

            return identity
        }

        // Fail closed: an operator who encrypted the identity at rest must supply
        // the password before we replace it — regrinding without one would
        // silently downgrade the new key to plaintext storage.
        if identity.encryptedPrivateKey != nil, password?.isEmpty ?? true {
            throw IdentityError.missingPrivateKey
        }

        // Validate the supplied password against the OLD encrypted key before
        // replacing it: a typo would otherwise destroy the old key and encrypt
        // the new one under the wrong password.
        if let encrypted = identity.encryptedPrivateKey, let saltHex = identity.salt,
           let password, !password.isEmpty {
            do { _ = try decryptKey(encrypted: encrypted, saltHex: saltHex, password: password) }
            catch { throw IdentityError.decryptionFailed }
        }

        // Preserve the old identity before regrinding — its nodeAddress may hold
        // funds that become unrecoverable if the key is destroyed.
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = dataDir.appendingPathComponent("identity.json.pre-grind-\(stamp)")
        var bump = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = dataDir.appendingPathComponent("identity.json.pre-grind-\(stamp).\(bump)")
            bump += 1
        }
        try FileManager.default.moveItem(at: path, to: backup)

        print("  Node identity \(identity.publicKey.prefix(16))… has \(bits) key-work bits, need \(minKeyBits) — regrinding (peer ID and node address will change).")
        print("  Previous identity preserved at \(backup.path) — keep it to recover funds held by the old node address.")
    }

    let kp: (privateKey: String, publicKey: String)
    if minKeyBits > 0 {
        print("  Grinding node identity key to \(minKeyBits) trailing-zero bits — one-time per data dir, may take minutes...")
        let ground = grindWorkedIdentityKey(minBits: minKeyBits)
        // Store in the same Multikey (`ed01`-prefixed) form CryptoUtils.generateKeyPair()
        // emits; `p2pPublicKey` strips the prefix back to the raw ground key Ivy presents.
        kp = (privateKey: ground.privateKey.map { String(format: "%02x", $0) }.joined(),
              publicKey: "ed01" + ground.publicKey)
    } else {
        kp = CryptoUtils.generateKeyPair()
    }

    let identity: IdentityFile
    if let password, !password.isEmpty {
        let (encrypted, salt) = try encryptKey(privateKey: kp.privateKey, password: password)
        identity = IdentityFile(publicKey: kp.publicKey, privateKey: nil, encryptedPrivateKey: encrypted, salt: salt)
    } else {
        identity = IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey, encryptedPrivateKey: nil, salt: nil)
    }

    let data = try JSONEncoder().encode(identity)
    try writePrivateKeyFile(data, to: path)
    return IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey, encryptedPrivateKey: identity.encryptedPrivateKey, salt: identity.salt)
}

private func encryptKey(privateKey: String, password: String) throws -> (encrypted: String, salt: String) {
    var salt = [UInt8](repeating: 0, count: 16)
    #if canImport(Darwin)
    _ = salt.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    #else
    if let f = fopen("/dev/urandom", "r") { defer { fclose(f) }; _ = fread(&salt, 1, 16, f) }
    #endif

    let key = try deriveKey(password: password, salt: salt)
    let nonce = try AES.GCM.Nonce(data: Data(salt.prefix(12)))
    let sealed = try AES.GCM.seal(Data(privateKey.utf8), using: key, nonce: nonce)
    guard let combined = sealed.combined else { throw IdentityError.invalidKeyData }
    return (combined.map { String(format: "%02x", $0) }.joined(), salt.map { String(format: "%02x", $0) }.joined())
}

private func decryptKey(encrypted: String, saltHex: String, password: String) throws -> String {
    guard let encData = Data(hex: encrypted), let salt = Data(hex: saltHex) else {
        throw IdentityError.invalidKeyData
    }
    let key = try deriveKey(password: password, salt: Array(salt))
    let box = try AES.GCM.SealedBox(combined: encData)
    let decrypted = try AES.GCM.open(box, using: key)
    guard let result = String(data: decrypted, encoding: .utf8) else {
        throw IdentityError.decryptionFailed
    }
    return result
}

private func deriveKey(password: String, salt: [UInt8]) throws -> SymmetricKey {
    // PBKDF2-HMAC-SHA256 with 100,000 iterations — password-hardened KDF.
    // HKDF is NOT suitable for passwords (no computational hardness) and
    // must never be used as a fallback. If PBKDF2 is unavailable, throw
    // rather than silently downgrading to a brute-force-trivial derivation.
    return try KDF.Insecure.PBKDF2.deriveKey(
        from: Data(password.utf8),
        salt: Data(salt),
        using: .sha256,
        outputByteCount: 32,
        rounds: 210_000
    )
}

// Data(hex:) is provided by the Lattice library via CryptoUtils
