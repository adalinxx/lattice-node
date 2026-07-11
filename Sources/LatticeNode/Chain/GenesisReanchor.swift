import Lattice
import cashew

extension Block {
    /// Re-anchor a freshly built child GENESIS block onto a parent-state BOOTSTRAP anchor.
    ///
    /// SCOPE — this is a NODE-LEVEL, deploy-time bootstrap checkpoint, NOT a consensus
    /// invariant. `BlockBuilder.buildGenesis` anchors a genesis at the empty state; a
    /// child genesis instead records the parent's current tip post-state at DEPLOY time,
    /// so a follower rebuilding the genesis reproduces its CID. The consensus library does
    /// NOT model or check this: `GenesisAction` binds only (directory, blockCID), and
    /// `validateGenesis` never validates the genesis `parentState` against a creation
    /// carrier. Concretely, it is a checkpoint, NOT a guarantee that this value equals the
    /// prevState of the parent block that eventually MINES the GenesisAction: deploy and
    /// announcement are separate steps, so if the parent mines blocks between them the
    /// actual carrier's prevState will differ. Binding the genesis to its true creation
    /// carrier is a consensus concern (tracked as a Lattice change), not something this
    /// node-side helper can enforce.
    ///
    /// Mechanically it is a PURE field-preserving reconstruction — only `parentState`
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
