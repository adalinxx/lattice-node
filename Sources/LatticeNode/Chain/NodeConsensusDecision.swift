import Lattice
import Tally

/// Node-level interpretation of Lattice's chain-local admission result.
///
/// This type is intentionally about meaning, not transport. Gossip, sync, mining,
/// parent extraction, rescue, and restart must all map the same Lattice result to
/// the same decision.
enum NodeConsensusDecision: Sendable, Equatable {
    /// Valid and selected by this chain's fork choice.
    case canonicalized
    /// Valid and retained in this chain's graph, but not selected.
    case acceptedSide
    /// The same valid block/evidence is already known.
    case duplicate
    /// Required complete Volumes or evidence are not currently available.
    case unavailable
    /// Complete evidence was obtained and violated protocol rules.
    case invalid
    /// Local durable persistence failed; this says nothing about a peer.
    case storageFailed

    init(_ result: ChainLocalBlockResult) {
        switch result {
        case .canonicalized:
            self = .canonicalized
        case .acceptedSide:
            self = .acceptedSide
        case .duplicate:
            self = .duplicate
        case .invalid:
            self = .invalid
        case .unavailable:
            self = .unavailable
        case .storageFailed:
            self = .storageFailed
        }
    }

    var isValidAdmission: Bool {
        switch self {
        case .canonicalized, .acceptedSide, .duplicate: return true
        case .unavailable, .invalid, .storageFailed: return false
        }
    }

    /// Only a chain-local canonicalization may publish a new canonical tip.
    var shouldPublishCanonicalTip: Bool { self == .canonicalized }

    /// Only an obtained, protocol-invalid candidate is attributable as invalid
    /// peer evidence. Availability and local storage failures are never penalties.
    var mayPenalizeSupplyingPeer: Bool { self == .invalid }

    var shouldRetryWhenAvailabilityChanges: Bool { self == .unavailable }

    /// Typed Tally observation when this decision is attributed to a remote
    /// delivery. The caller still controls attribution; this mapping prevents
    /// local availability/durability conditions from becoming generic failures.
    var attributedPeerObservation: PeerObservation {
        switch self {
        case .canonicalized, .acceptedSide, .duplicate:
            return .responseSucceeded()
        case .invalid:
            return .remoteFailure(.invalidEvidence)
        case .unavailable:
            return .localFailure(.validationUnavailable)
        case .storageFailed:
            return .localFailure(.storageUnavailable)
        }
    }
}
