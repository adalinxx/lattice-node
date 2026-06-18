import Foundation
import Ivy
import Tally

/// Node-side spawn-tree trust (step 2b). Verifies the spawn-certificate
/// chain a peer presented (transported by Ivy, step 2a) against THIS node's
/// trusted spawn-tree root, binding the chain's leaf to the peer's AUTHENTICATED
/// identity, and records each peer's proven scope.
///
/// A peer is **trusted** for exactly the chain path its certificate proves, and
/// **federated** (no entry) otherwise — no chain, an unverifiable chain, a chain
/// rooted at a different tree, or a chain whose leaf isn't this peer's real key.
/// Trust here is *authority* (which peer may serve the consensus view, and for
/// which path); content is still verified everywhere else. Failing closed to
/// federated is always safe: it only means "verify more".
public actor SpawnTrust {
    /// The spawn-tree root public key every trusted chain must terminate at.
    /// `nil` ⇒ this node has no spawn tree (federated-only): every peer is federated.
    private let trustedRoot: String?
    private var scopes: [PeerID: [String]] = [:]

    public init(trustedRoot: String?) {
        self.trustedRoot = trustedRoot
    }

    /// Whether this node verifies spawn-tree membership at all.
    public var hasTrustedRoot: Bool { trustedRoot != nil }

    /// Classify a peer from the chain it presented. The `leaf` MUST be the peer's
    /// authenticated `PeerID` (Ivy's post-identify realID) — never a key lifted
    /// from the chain — so a stolen chain ending in someone else's key fails.
    /// Returns the proven scope (trusted) or `nil` (federated); records the result.
    @discardableResult
    public func classify(presentedChain chain: [SpawnCertificate], peer: PeerID) -> [String]? {
        guard let trustedRoot, !chain.isEmpty,
              let scope = SpawnCertificateChain.verifiedScope(chain: chain, leaf: peer, trustedRoot: trustedRoot)
        else {
            scopes.removeValue(forKey: peer)
            return nil
        }
        scopes[peer] = scope
        return scope
    }

    /// The proven scope for a peer, or `nil` if federated/unknown.
    public func verifiedScope(for peer: PeerID) -> [String]? { scopes[peer] }

    /// Whether the peer is a verified spawn-tree member.
    public func isTrusted(_ peer: PeerID) -> Bool { scopes[peer] != nil }

    /// Whether the peer is trusted to serve/assert consensus for `chainPath`.
    /// Enforces the proven scope: a trusted peer may speak only for its own scope
    /// and descendants of it (a `Nexus/Alpha` peer cannot speak for `Nexus/Beta`).
    public func isTrusted(_ peer: PeerID, forChainPath chainPath: [String]) -> Bool {
        guard let scope = scopes[peer] else { return false }
        guard chainPath.count >= scope.count else { return false }
        return Array(chainPath.prefix(scope.count)) == scope
    }

    /// Whether `peer` (a trusted member scoped to some path S) may **query** the
    /// consensus weight of `chainPath` from us — true iff that chain is an
    /// ANCESTOR-or-equal of the peer's proven scope (a descendant reads its
    /// ancestors' weight). The inverse direction of `isTrusted(_:forChainPath:)`:
    /// a `Nexus/Alpha/X` peer may query `Nexus` and `Nexus/Alpha`, but not
    /// `Nexus/Beta` (not its ancestor) nor `Nexus/Alpha/X/Y` (its descendant).
    public func mayServeConsensus(to peer: PeerID, forChainPath chainPath: [String]) -> Bool {
        guard let scope = scopes[peer], !chainPath.isEmpty else { return false }
        guard chainPath.count <= scope.count else { return false }
        return Array(scope.prefix(chainPath.count)) == chainPath
    }

    /// Drop a peer's recorded trust (on disconnect), so trust never outlives the
    /// authenticated connection that earned it.
    public func forget(_ peer: PeerID) {
        scopes.removeValue(forKey: peer)
    }
}
