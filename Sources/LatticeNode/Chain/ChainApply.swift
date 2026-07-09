import Foundation
import Tally
import UInt256

/// A candidate chain extension gathered from ANY source — a gossiped block, a sync
/// batch, or a rescue backfill. It is just a claimed tip plus enough to reach the
/// blocks/proofs on the path from our chain to it. Sources differ only in how they
/// GATHER (single-block fast path vs batched bulk path); they all produce this.
struct CandidateExtension: Sendable, Equatable {
    let tipCID: String
    let tipHeight: UInt64
    /// UNVERIFIED work hint from the gatherer (may be nil from an old peer). Used
    /// only as a cheap fork-choice pre-filter; the authoritative weight comparison
    /// is re-done at adopt, under the commit lock, against verified data.
    let claimedWork: UInt256?
    /// The peer that offered it — a fetch hint and the attributability handle for
    /// graduated penalties (invalid → ban; can't-serve → retry; withheld → light).
    let source: PeerID?
}

/// The four — and only four — fates of a candidate. This is the spine: there is no
/// "silent nothing." Availability failures are `pendingUnavailable` (retry, NOT a
/// verdict on validity); only provably-bad data is `invalid`.
enum ChainOutcome: Equatable, Sendable {
    case adopted(tipCID: String)   // heavier + available + valid → reorged to it
    case ignoredLighter            // fork choice: not strictly heavier → hold incumbent
    case pendingUnavailable        // data not fetchable yet → retry later (never a ban)
    case invalid(reason: String)   // bad PoW / proof / content-binding / state → reject
}

extension ChainOutcome {
    /// Did the candidate get adopted? (bridges the former `Bool` return of
    /// `finalizeSyncResult` while call sites migrate to the full outcome.)
    var wasAdopted: Bool { if case .adopted = self { return true } else { return false } }
}

/// Result of gathering a candidate's reachable blocks/proofs by content hash.
enum GatherResult: Equatable, Sendable {
    case complete                  // everything reachable is present + content-bound
    case incomplete                // some bytes not fetchable yet (transient, not fraud)
    case contentMismatch(String)   // bytes served don't hash to their CID (attributable)
}

enum ValidationResult: Equatable, Sendable {
    case valid
    case invalid(String)           // PoW / proof / state re-execution failed
}

/// Result of the authoritative adopt step, which re-checks fork choice UNDER the
/// commit lock (the chain may have advanced during gather/validate) and then commits.
enum AdoptResult: Equatable, Sendable {
    case adopted
    case supersededByHeavierLocal  // local chain advanced under us → hold incumbent
    case transientFailure          // a commit-time availability/IO miss → retry
}

/// THE single apply operation — our `ActivateBestChain`. Gossip, sync, and rescue
/// are just gatherers that call this. The four steps map 1:1 to the SOTA-validated
/// model: fork choice (cheap, first) → availability (missing = pending) → validate
/// (verify-not-trust) → adopt (authoritative re-check under lock, then commit).
///
/// Collaborators are injected as closures so the whole contract is testable with
/// fakes — no actor, no live network. The real wiring passes closures that call the
/// node's fork-choice / fetcher / validator / commit paths.
struct ChainApply: Sendable {
    /// Cheap pre-filter: is the candidate plausibly heavier (may use claimedWork)?
    /// Not authoritative — `adopt` re-checks against verified data under the lock.
    var isStrictlyHeavier: @Sendable (CandidateExtension) async -> Bool
    /// Fetch the reachable blocks/proofs by content hash from any peer/CAS.
    var gather: @Sendable (CandidateExtension) async -> GatherResult
    /// PoW + proofs + state re-execution over the gathered data.
    var validate: @Sendable (CandidateExtension) async -> ValidationResult
    /// Re-check fork choice under the commit lock, then commit/reorg.
    var adopt: @Sendable (CandidateExtension) async -> AdoptResult

    func apply(_ candidate: CandidateExtension) async -> ChainOutcome {
        // 1. Fork choice first — cheapest gate. A not-heavier candidate is dropped
        //    before any fetch/validation bandwidth is spent (Bitcoin: only fetch
        //    along the best-work chain).
        guard await isStrictlyHeavier(candidate) else { return .ignoredLighter }

        // 2. Availability — gather the reachable path. Missing bytes are NOT a
        //    validity verdict: they are transient and retried. Only bytes that fail
        //    content binding are attributable and rejected here.
        switch await gather(candidate) {
        case .incomplete:              return .pendingUnavailable
        case .contentMismatch(let r):  return .invalid(reason: r)
        case .complete:                break
        }

        // 3. Validate — verify-not-trust: PoW + proofs + re-execute state.
        if case .invalid(let r) = await validate(candidate) { return .invalid(reason: r) }

        // 4. Adopt — the authoritative fork-choice re-check happens HERE, under the
        //    commit lock, because the local chain may have advanced during 2–3. A
        //    transient commit-time miss retries rather than dead-ends.
        switch await adopt(candidate) {
        case .adopted:                 return .adopted(tipCID: candidate.tipCID)
        case .supersededByHeavierLocal: return .ignoredLighter
        case .transientFailure:        return .pendingUnavailable
        }
    }
}
