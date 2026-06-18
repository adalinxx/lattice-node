import Lattice
import Foundation
import Ivy
import LatticeNodeWire
import Tally

#if canImport(Darwin)
import Darwin
#endif

// Sync-request manager for ChainNetwork.
// Behavior-preserving extraction : bulk block-header fetch over
// getHeaders/getHeaders2, the pending-request registry keyed by request ID,
// and the headerBatch/headerBatch2 response parsers.
//
// ChainNetwork is the production `HeaderBatchSource` for the sync header walk;
// the conformance is satisfied by its existing requestHeaderBatch /
// requestHeaderBatchWithProofs / storeBlock methods (no new surface).
extension ChainNetwork: HeaderBatchSource {

    struct PendingHeaderRequest {
        let targetPeer: PeerID
        let resume: @Sendable ([(cid: String, data: Data)]) -> Void
    }

    struct PendingHeaderProofRequest {
        let targetPeer: PeerID
        let resume: @Sendable ([(cid: String, data: Data, proof: Data?)]) -> Void
    }

    enum HeaderBatchResponseOutcome: Equatable {
        case accepted
        case wrongPeer
        case unsolicited
        case malformed
    }

    // MARK: - Bulk Header Fetch

    /// Request up to `count` block headers walking backwards from `fromCID`.
    /// Returns (CID, blockData) pairs newest-first, or empty on timeout.
    public func requestHeaderBatch(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data)] {
        guard let requestID = makeUniqueHeaderRequestID(),
              let payload = NetworkWireCodecs.encodeHeaderRequest(
                  requestID: requestID,
                  fromCID: fromCID,
                  count: UInt32(min(count, Self.maxHeaderBatchSize))
              ) else { return [] }

        return await withCheckedContinuation { continuation in
            let inserted = registerPendingHeaderRequest(
                requestID: requestID,
                targetPeer: peer,
                resume: { continuation.resume(returning: $0) }
            )
            guard inserted else {
                continuation.resume(returning: [])
                return
            }
            Task {
                await ivy.sendMessage(to: peer, topic: "getHeaders", payload: payload)
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.pendingHeaderRequests.removeValue(forKey: requestID) {
                    pending.resume([])
                }
            }
        }
    }

    /// Proof-carrying header batch: each returned header is bundled with the serving
    /// peer's stored ChildBlockProof (F5-4). Child chains use this so the syncing node
    /// can verify each block's PoW against its cross-chain anchor (not the self-hash).
    /// An old peer that doesn't recognize `getHeaders2` never replies, so the request
    /// times out to an empty result — the caller then fails the child sync closed
    /// (a child header without a proof must never be accepted) rather than self-hashed.
    public func requestHeaderBatchWithProofs(fromCID: String, count: Int, peer: PeerID) async -> [(cid: String, data: Data, proof: Data?)] {
        guard let requestID = makeUniqueHeaderRequestID(),
              let payload = NetworkWireCodecs.encodeHeaderRequest(
                  requestID: requestID,
                  fromCID: fromCID,
                  count: UInt32(min(count, Self.maxHeaderBatchSize))
              ) else { return [] }

        return await withCheckedContinuation { continuation in
            let inserted = registerPendingHeaderProofRequest(
                requestID: requestID,
                targetPeer: peer,
                resume: { continuation.resume(returning: $0) }
            )
            guard inserted else {
                continuation.resume(returning: [])
                return
            }
            Task {
                await ivy.sendMessage(to: peer, topic: "getHeaders2", payload: payload)
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.pendingHeaderProofRequests.removeValue(forKey: requestID) {
                    pending.resume([])
                }
            }
        }
    }

    internal func makeUniqueHeaderRequestID(
        randomData: @Sendable (Int) -> Data? = { ChainNetwork.secureRandomData(count: $0) }
    ) -> Data? {
        for _ in 0..<16 {
            guard let requestID = randomData(16) else { return nil }
            if pendingHeaderRequests[requestID] == nil,
               pendingHeaderProofRequests[requestID] == nil {
                return requestID
            }
        }
        return nil
    }

    static func secureRandomData(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Darwin)
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        #else
        guard let random = fopen("/dev/urandom", "rb") else { return nil }
        defer { fclose(random) }
        guard fread(&bytes, 1, count, random) == count else { return nil }
        #endif
        return Data(bytes)
    }

    internal func registerPendingHeaderRequest(
        requestID: Data,
        targetPeer: PeerID,
        resume: @escaping @Sendable ([(cid: String, data: Data)]) -> Void
    ) -> Bool {
        guard requestID.count == 16,
              pendingHeaderRequests[requestID] == nil,
              pendingHeaderProofRequests[requestID] == nil else {
            return false
        }
        pendingHeaderRequests[requestID] = PendingHeaderRequest(targetPeer: targetPeer, resume: resume)
        return true
    }

    internal func registerPendingHeaderProofRequest(
        requestID: Data,
        targetPeer: PeerID,
        resume: @escaping @Sendable ([(cid: String, data: Data, proof: Data?)]) -> Void
    ) -> Bool {
        guard requestID.count == 16,
              pendingHeaderRequests[requestID] == nil,
              pendingHeaderProofRequests[requestID] == nil else {
            return false
        }
        pendingHeaderProofRequests[requestID] = PendingHeaderProofRequest(targetPeer: targetPeer, resume: resume)
        return true
    }

    @discardableResult
    internal func handleHeaderBatchResponse(payload: Data, from peer: PeerID) async -> HeaderBatchResponseOutcome {
        guard let requestID = NetworkWireCodecs.headerBatchResponseRequestID(payload) else { return .malformed }
        guard let pending = pendingHeaderRequests[requestID] else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return .unsolicited
        }
        guard pending.targetPeer == peer else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return .wrongPeer
        }

        // Canonical fail-closed parse: a malformed/truncated response, or a
        // declared numHeaders above the bound, yields the WHOLE response
        // dropped (nil → []) — never a silently-truncated prefix.
        let results = NetworkWireCodecs.parseHeaderBatch(payload, maxHeaders: Self.maxHeaderBatchSize) ?? []
        _ = pendingHeaderRequests.removeValue(forKey: requestID)
        pending.resume(results)
        return .accepted
    }

    @discardableResult
    internal func handleHeaderBatchWithProofsResponse(payload: Data, from peer: PeerID) async -> HeaderBatchResponseOutcome {
        guard let requestID = NetworkWireCodecs.headerBatchResponseRequestID(payload) else { return .malformed }
        guard let pending = pendingHeaderProofRequests[requestID] else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return .unsolicited
        }
        guard pending.targetPeer == peer else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return .wrongPeer
        }

        // Canonical fail-closed parse: a malformed/truncated response, or a
        // declared numHeaders above the bound, yields the WHOLE response
        // dropped (nil → []), never a silently-truncated prefix — the syncing
        // child then fails closed rather than accepting a short
        // anchored-header set.
        let results = NetworkWireCodecs.parseHeaderBatch2(payload, maxHeaders: Self.maxHeaderBatchSize) ?? []
        _ = pendingHeaderProofRequests.removeValue(forKey: requestID)
        pending.resume(results)
        return .accepted
    }
}
