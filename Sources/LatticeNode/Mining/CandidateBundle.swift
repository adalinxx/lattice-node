import Foundation

// A CID-addressed snapshot of the merged-mining candidate tree that a template
// or candidate route assembles: the parent-carrier (root) block, and one entry
// per embedded child candidate, each named purely by CID. It carries NO
// VolumeBroker volume references, no broker handles, and no live node state —
// every datum is a content address or a hash string, so the whole bundle can be
// serialized to one fixture and re-loaded byte-for-byte. That makes a merged
// mining assembly reproducible: a test (the consumer here) can capture exactly
// what a fan-out produced and replay it deterministically.
//
// This is reproducibility tooling, not the consensus assembly path. The template
// RPC still owns assembly; this type is the narrow, CID-only description of its
// output and a set of structural checks over it.

/// One embedded child candidate, addressed by CID only.
public struct ChildCandidateRef: Codable, Sendable, Equatable {
    /// Full chain path of the child, e.g. `["Nexus", "SwapTest"]`. Validated via
    /// `ChainAddress` (non-empty, no empty components).
    public let chainPath: [String]
    /// CID of the child candidate block.
    public let blockCID: String
    /// CID of the child's PoW path proof (`ChildBlockProof` envelope), when the
    /// child commits under the parent carrier. `nil` means no proof was supplied.
    public let proofCID: String?

    public init(chainPath: [String], blockCID: String, proofCID: String?) {
        self.chainPath = chainPath
        self.blockCID = blockCID
        self.proofCID = proofCID
    }
}

/// CID-addressed candidate bundle for a single merged-mining assembly.
public struct CandidateBundle: Codable, Sendable, Equatable {
    /// CID of the root / parent-carrier block the children commit under.
    public let rootCandidateCID: String
    /// The parent-carrier block hash the children commit under. Must equal
    /// `rootCandidateCID` — the bundle is rooted at exactly one carrier.
    public let parentCarrierHash: String
    /// Embedded child candidates, each addressed by CID.
    public let childCandidates: [ChildCandidateRef]
    /// The effective mining target (hex) the assembly resolved.
    public let effectiveTarget: String

    public init(
        rootCandidateCID: String,
        parentCarrierHash: String,
        childCandidates: [ChildCandidateRef],
        effectiveTarget: String
    ) {
        self.rootCandidateCID = rootCandidateCID
        self.parentCarrierHash = parentCarrierHash
        self.childCandidates = childCandidates
        self.effectiveTarget = effectiveTarget
    }
}

// MARK: - Validation

/// A specific structural defect found while validating a `CandidateBundle`.
/// Each case maps to one of the CID/root checks the bundle must satisfy.
public enum CandidateBundleValidationError: Error, Equatable, Sendable {
    /// `parentCarrierHash` does not equal the bundle's declared root carrier CID.
    case parentCarrierMismatch(declared: String, root: String)
    /// A child's `chainPath` is empty or contains an empty component (rejected by
    /// `ChainAddress`).
    case malformedChainPath([String])
    /// Two children declare the same chain path.
    case duplicateChainPath([String])
    /// A child that requires a proof reference is missing one.
    case missingChildProof([String])
}

public enum CandidateBundleValidationResult: Equatable, Sendable {
    case valid
    case invalid(CandidateBundleValidationError)
}

extension CandidateBundle {
    /// Structural CID/root checks over the bundle. Pure data — no network, broker,
    /// or node calls.
    ///
    /// - `requireChildProofs`: when `true`, every child must carry a `proofCID`
    ///   (a child committing under the parent carrier must prove its path). When
    ///   `false`, missing proofs are allowed (e.g. a same-process child that needs
    ///   no cross-chain proof). Defaults to `true`.
    ///
    /// Checks performed:
    /// - `parentCarrierHash` matches `rootCandidateCID` (wrong carrier → invalid),
    /// - each child `chainPath` is well-formed via `ChainAddress` (wrong path → invalid),
    /// - child chain paths are non-duplicate,
    /// - each child carries a proof when `requireChildProofs` (missing proof → invalid).
    public func validate(requireChildProofs: Bool = true) -> CandidateBundleValidationResult {
        guard parentCarrierHash == rootCandidateCID else {
            return .invalid(.parentCarrierMismatch(
                declared: parentCarrierHash, root: rootCandidateCID))
        }

        var seenPaths = Set<[String]>()
        for child in childCandidates {
            guard ChainAddress(child.chainPath) != nil else {
                return .invalid(.malformedChainPath(child.chainPath))
            }
            guard seenPaths.insert(child.chainPath).inserted else {
                return .invalid(.duplicateChainPath(child.chainPath))
            }
            if requireChildProofs && child.proofCID == nil {
                return .invalid(.missingChildProof(child.chainPath))
            }
        }
        return .valid
    }

    /// Throwing convenience over `validate`.
    public func validated(requireChildProofs: Bool = true) throws {
        if case let .invalid(error) = validate(requireChildProofs: requireChildProofs) {
            throw error
        }
    }
}
