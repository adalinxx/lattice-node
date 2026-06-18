import Lattice
import Foundation
import cashew
import Synchronization

/// Caches the resolved frontier LatticeState to avoid redundant Merkle
/// trie resolution during bursts of transaction validation against the
/// same chain tip. Keyed by frontier CID — automatically invalidated
/// when the chain advances to a new block.
///
/// Uses a `Mutex` instead of an `actor` so `get`, `set`, and `invalidate`
/// are synchronous. The actor formulation required `await` at every call site,
/// adding suspension points inside `validateNonce` and `validateBalances`
/// during concurrent transaction validation — serialising all validator tasks
/// through a single actor queue for what is ultimately a dictionary lookup.
public final class PostStateCache: @unchecked Sendable {
    private struct Entry {
        let cid: String
        let state: LatticeState
    }
    private let _entry = Mutex<Entry?>(nil)

    public init() {}

    public func get(frontierCID: String) -> LatticeState? {
        _entry.withLock { entry in
            guard let e = entry, e.cid == frontierCID else { return nil }
            return e.state
        }
    }

    public func set(frontierCID: String, state: LatticeState) {
        _entry.withLock { $0 = Entry(cid: frontierCID, state: state) }
    }

    public func invalidate() {
        _entry.withLock { $0 = nil }
    }
}
