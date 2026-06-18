import Foundation
import Lattice
import UInt256

/// Decentralized Sybil gate for the faucet.
///
/// A requester must submit a proof-of-work solution bound to the address it is
/// requesting tokens for — no CAPTCHA, no account/auth infrastructure. This is
/// the same shape as the chain's PoW (`ProofOfWork`): a nonce hashed under a
/// target, with the identical `target >= hash` acceptance test and the same
/// `CryptoUtils` SHA-256 / `UInt256` primitives the miner uses. We do NOT
/// invent a new hash.
///
/// The work is bound to the requested address (and a caller-chosen challenge
/// nonce so distinct requests for the same address each cost work), so a
/// pre-computed solution cannot be replayed across addresses.
enum FaucetPoW {
    /// Domain separator so a faucet PoW digest can never collide with another
    /// protocol hash.
    static let domain = "lattice-faucet-pow-v1:"

    /// Default difficulty in leading-zero bits. `target = UInt256.max >> bits`,
    /// so a valid nonce is found after ~2^bits hashes on average. 20 bits is a
    /// modest few-seconds cost on a laptop — enough friction to defeat trivial
    /// scripted Sybil bursts, cheap enough for a legitimate testnet user.
    static let defaultDifficultyBits: UInt8 = 20

    /// The acceptance target for a given difficulty.
    static func target(difficultyBits: UInt8) -> UInt256 {
        UInt256.max >> Int(difficultyBits)
    }

    /// SHA-256 digest of the work string, as a big-endian `UInt256` — the same
    /// digest→`UInt256` mapping `ProofOfWork.hash` uses.
    static func digest(address: String, challenge: String, nonce: UInt64) -> UInt256 {
        let payload = "\(domain)\(address)|\(challenge)|\(nonce)"
        let bytes = CryptoUtils.sha256Data(Data(payload.utf8))
        return bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            return UInt256([
                UInt64(bigEndian: p[0]),
                UInt64(bigEndian: p[1]),
                UInt64(bigEndian: p[2]),
                UInt64(bigEndian: p[3])
            ])
        }
    }

    /// True iff `nonce` is a valid solution for `address`/`challenge` at the
    /// given difficulty. Fail-closed: anything that does not clear the target
    /// is invalid.
    static func isValid(
        address: String,
        challenge: String,
        nonce: UInt64,
        difficultyBits: UInt8
    ) -> Bool {
        target(difficultyBits: difficultyBits) >= digest(address: address, challenge: challenge, nonce: nonce)
    }

    /// Solve the challenge by linear nonce search. Used by tests and by any
    /// requester tooling; the server only ever *verifies*.
    static func solve(
        address: String,
        challenge: String,
        difficultyBits: UInt8
    ) -> UInt64 {
        let t = target(difficultyBits: difficultyBits)
        var nonce: UInt64 = 0
        while true {
            if t >= digest(address: address, challenge: challenge, nonce: nonce) { return nonce }
            nonce &+= 1
        }
    }
}

/// A requester-supplied PoW solution bound to a requested address.
struct FaucetPoWSolution: Equatable, Sendable {
    let challenge: String
    let nonce: UInt64
}

/// A faucet-issued PoW challenge.
///
/// SYBIL GATE provenance: the challenge token is server-generated (random),
/// bound to a single requested `address`, has an `expiry`, and is single-use.
/// Accepting an arbitrary requester-chosen challenge would let an attacker
/// pre-compute one solution offline and reuse it across an unlimited burst of
/// requests, defeating the work gate — so the drip path only honours tokens
/// this faucet actually issued for exactly that address.
struct FaucetChallenge: Equatable, Sendable {
    let token: String
    let address: String
    let expiry: Date

    /// Fresh server-issued challenge: a 128-bit random token bound to `address`.
    static func issue(address: String, ttl: TimeInterval, now: Date = Date()) -> FaucetChallenge {
        var bytes = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        return FaucetChallenge(token: token, address: address, expiry: now.addingTimeInterval(ttl))
    }
}
