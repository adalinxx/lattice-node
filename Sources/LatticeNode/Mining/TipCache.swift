import Foundation
import Synchronization

/// Lock-free cache for the chain tip hash.
/// Allows BlockProducer to check for tip changes without an actor hop into ChainState.
/// Updated by LatticeNode whenever a block is accepted or mined.
public final class TipCache: Sendable {
    private let _tip: Mutex<String>

    public init(tip: String) {
        self._tip = Mutex(tip)
    }

    public var tip: String {
        _tip.withLock { $0 }
    }

    public func update(_ newTip: String) {
        _tip.withLock { $0 = newTip }
    }
}
