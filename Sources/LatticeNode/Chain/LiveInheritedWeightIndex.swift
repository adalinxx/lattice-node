import Foundation
import UInt256

/// Synchronous fork-choice read model for Hierarchical-GHOST inherited weight.
///
/// A child block is committed by one or more parent ("securing") blocks — usually
/// exactly one, occasionally several across the parent's forks. The trusted parent
/// computes the faithful UNION inherited weight over those committers (every
/// grinding block counted once, `Chain.unionInheritedWeight`) and serves a single
/// number per child. This index holds that value per child for `ChainState`'s
/// synchronous provider, backed by a durable, only-grows floor.
///
/// Two maps, both keyed by CHILD block hash:
/// - `committersByChild` — the set of parent blocks that commit the child. Additive
///   (a committer is never dropped), so the set the parent is re-queried with is
///   complete across forks. This is the fix for the prior single-slot map that
///   silently dropped cross-fork carriers.
/// - `unionWeightByChild` — the parent-served faithful union weight, only-grows.
///   This is the single per-child fork-choice quantity, NOT a `max` of two
///   incompatible accounting bases.
final class LiveInheritedWeightIndex: @unchecked Sendable {
    private let lock = NSLock()
    /// Cap on the live projection; eviction over this is always safe (an evicted
    /// child falls back to the durable floor — only-grows).
    private static let maxLiveChildren = 8192
    private var committersByChild: [String: Set<String>] = [:]
    private var unionWeightByChild: [String: UInt256] = [:]
    /// Durable, only-grows inherited-weight floor keyed by child block hash. The
    /// live projection is bounded, so a child can fall out of `unionWeightByChild`;
    /// the durable `InheritedWeightStore` floor (the CID-deduped securing-work the
    /// node has verified) holds a correct LOWER bound until the parent is re-queried.
    /// The served union is always >= this floor (the cone contains the proof spine),
    /// so `max(live, floor)` compares two same-direction lower bounds, never two
    /// incompatible quantities.
    private var durableFloor: (@Sendable (String) -> UInt256)?

    /// Record that `parentHash` commits `childHash`. Additive (Set insert), never
    /// drops a prior committer. Returns true if this is a NEW committer — the caller
    /// should then re-query the parent for the union over the full committer set.
    @discardableResult
    func recordParentAnchor(childHash: String, parentHash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return committersByChild[childHash, default: []].insert(parentHash).inserted
    }

    /// The full committer set for `childHash` (all parent blocks that commit it),
    /// for re-querying the parent's faithful union.
    func committers(forChild childHash: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(committersByChild[childHash] ?? [])
    }

    /// Install the durable inherited-weight floor (the `InheritedWeightStore`
    /// provider). Idempotent: an only-grows provider never lowers a reported value.
    func setDurableFloor(_ floor: @escaping @Sendable (String) -> UInt256) {
        lock.lock(); defer { lock.unlock() }
        durableFloor = floor
    }

    /// Promote the parent-served faithful union weight for a child (only-grows).
    /// Bounds the live projection (eviction falls back to the durable floor).
    @discardableResult
    func promoteChildUnionWeight(childHash: String, weight: UInt256) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let existing = unionWeightByChild[childHash] ?? .zero
        guard weight > existing else { return false }
        unionWeightByChild[childHash] = weight
        if unionWeightByChild.count > Self.maxLiveChildren {
            var toDrop = unionWeightByChild.count - Self.maxLiveChildren
            for key in Array(unionWeightByChild.keys) where key != childHash {
                guard toDrop > 0 else { break }
                unionWeightByChild.removeValue(forKey: key)
                toDrop -= 1
            }
        }
        return true
    }

    func inheritedWeight(forChild childHash: String) -> UInt256 {
        lock.lock()
        let floor = durableFloor
        let live = unionWeightByChild[childHash] ?? .zero
        lock.unlock()
        // Never under-report a previously-counted child: the bounded live projection
        // can regress to .zero on eviction/restart, the durable floor cannot.
        guard let floor else { return live }
        let durable = floor(childHash)
        return durable > live ? durable : live
    }

    func makeProvider() -> @Sendable (String) -> UInt256 {
        { [self] childHash in inheritedWeight(forChild: childHash) }
    }
}
