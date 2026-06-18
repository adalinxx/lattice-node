import Foundation
import Lattice

// The `ParentAnchor` struct (verified parent-chain carrier) now lives in Lattice
// (consensus data). This file keeps only the node-side canonical-ordering helper.

extension Sequence where Element == ParentAnchor {
    func canonicalAnchorSorted() -> [ParentAnchor] {
        sorted { lhs, rhs in
            ParentAnchor.canonicalSelectionLess(lhs, rhs)
        }
    }
}
