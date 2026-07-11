import Lattice
import cashew

extension Block {
    /// Re-anchor a freshly built GENESIS block onto the correct parent state.
    ///
    /// CORE INVARIANT (child-parentstate-is-carrier-prevstate): a child block's
    /// `parentState` is the CARRIER parent block's PRE-state. A child genesis is carried
    /// by the parent block that mines its genesis action, so it must anchor at that
    /// block's prevState (= the parent tip's post-state at deploy) — NOT the empty state
    /// `BlockBuilder.buildGenesis` defaults to. This re-anchor is done node-side (rather
    /// than in the consensus `buildGenesis`) so the node depends only on the pinned
    /// Lattice API. It is a PURE field-preserving reconstruction — only `parentState`
    /// changes; `prevState` (the child's own empty start), `postState`, and all tx/spec/
    /// children roots are carried verbatim, so a deploy and a later subscribe/follow
    /// rebuild that thread the SAME `parentState` reproduce the identical genesis CID.
    /// A ROOT genesis (no parent) is left anchored at its own empty state.
    func reanchoredGenesisParentState(_ parentState: Reference<LatticeState>) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
