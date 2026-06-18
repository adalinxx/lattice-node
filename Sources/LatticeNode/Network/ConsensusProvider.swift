import Foundation
import Tally
import UInt256
import Lattice

/// the trusted consensus provider. Inside a spawn tree, an
/// ancestor SERVES a chain block's authoritative fork-choice weight
/// (`trueCumWork = subtreeWeight + inherited`, from Lattice's
/// `effectiveWeight(forBlockHash:)`) to a verified descendant over the
/// authenticated link, and a descendant REQUESTS it — so the descendant READS
/// the parent's already-computed value instead of re-deriving it.
///
/// Scope-gated: a peer may only query an ANCESTOR-or-equal of its proven scope
/// (`SpawnTrust.mayServeConsensus`). Generic over its node capabilities (weight
/// lookup, scope gate, send) so the protocol + correlation are unit-testable
/// without a live network. The serve path is a pure `handleRequest -> Data?`
/// (the node replies on the network the request arrived on); only the client
/// path needs `send`.
public actor ConsensusProvider {
    /// Look up the faithful Hierarchical-GHOST inherited weight a parent serves for
    /// a child committed by `committerHashes` (the set of this-chain blocks that
    /// commit the child — usually exactly one, occasionally several across forks).
    /// The parent computes the union (each grinding block once) via
    /// `Chain.unionInheritedWeight`; a single committer reduces to its `trueCumWork`.
    public typealias WeightLookup = @Sendable (_ chainPath: [String], _ committerHashes: [String]) async -> UInt256?
    public typealias ScopeGate = @Sendable (_ peer: PeerID, _ chainPath: [String]) async -> Bool
    public typealias Send = @Sendable (_ peer: PeerID, _ topic: String, _ payload: Data) async -> Void

    public static let requestTopic = "cw-request"
    public static let responseTopic = "cw-response"

    private let weightLookup: WeightLookup
    private let mayServe: ScopeGate
    private let send: Send
    private let requestTimeout: Duration

    private var nextId: UInt64 = 0
    // Each pending request is BOUND to the peer it was sent to: a response is
    // accepted only if it arrives from that exact peer. Without this, any connected
    // peer could forge a cw-response with the (predictable) requestId and feed an
    // arbitrary weight into fork choice. (The serve side gates by scope; the client
    // gates by responder identity.)
    private var pending: [UInt64: (peer: PeerID, cont: CheckedContinuation<UInt256?, Never>)] = [:]

    public init(
        requestTimeout: Duration = .seconds(5),
        weightLookup: @escaping WeightLookup,
        mayServe: @escaping ScopeGate,
        send: @escaping Send
    ) {
        self.requestTimeout = requestTimeout
        self.weightLookup = weightLookup
        self.mayServe = mayServe
        self.send = send
    }

    // MARK: - Client (descendant asks an ancestor)

    /// Query `peer` for the faithful Hierarchical-GHOST inherited weight of a child
    /// committed by `committerHashes` on `chainPath`. Returns the value, or `nil` on
    /// timeout / refusal / unknown. A single-element set is the common case
    /// (`trueCumWork(committer)`); several elements request the cross-fork union.
    public func requestWeight(from peer: PeerID, chainPath: [String], committerHashes: [String]) async -> UInt256? {
        let id = nextId
        nextId &+= 1
        let payload = Self.encodeRequest(requestId: id, chainPath: chainPath, committerHashes: committerHashes)
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt256?, Never>) in
            pending[id] = (peer, cont)
            Task {
                await send(peer, Self.requestTopic, payload)
                try? await Task.sleep(for: requestTimeout)
                self.timeout(id)
            }
        }
    }

    private func timeout(_ id: UInt64) {
        if let entry = pending.removeValue(forKey: id) { entry.cont.resume(returning: nil) }
    }

    /// Resolve a pending request, but ONLY if `responder` is the peer we sent it to —
    /// a response from anyone else is dropped (the anti-forgery gate).
    private func resolve(_ id: UInt64, from responder: PeerID, _ value: UInt256?) {
        guard let entry = pending[id], entry.peer == responder else { return }
        pending.removeValue(forKey: id)
        entry.cont.resume(returning: value)
    }

    // MARK: - Serve (ancestor answers a verified descendant)

    /// Decode + scope-gate + look up the weight, returning the response payload to
    /// send back on the arriving network. `nil` (no reply) when the request is
    /// undecodable or the peer is not a verified descendant of the queried chain —
    /// weight is never revealed to an out-of-scope / federated peer.
    public func handleRequest(_ payload: Data, from peer: PeerID) async -> Data? {
        guard let req = Self.decodeRequest(payload) else { return nil }
        guard await mayServe(peer, req.chainPath) else { return nil }
        let weight = await weightLookup(req.chainPath, req.committerHashes)
        return Self.encodeResponse(requestId: req.requestId, weight: weight)
    }

    /// Correlate a response to a pending request — accepted only if `peer` is the
    /// peer the request was sent to (anti-forgery; see `pending`).
    public func handleResponse(_ payload: Data, from peer: PeerID) async {
        guard let resp = Self.decodeResponse(payload) else { return }
        resolve(resp.requestId, from: peer, resp.weight)
    }

    public func pendingCountForTesting() -> Int { pending.count }

    // MARK: - Wire format (manual, bounded)

    static let maxChainPathDepth = 64
    /// Bound the committer set on the wire. A child is normally committed by one
    /// parent block; several arise only across parent forks (rate-limited, since
    /// each carrier is a distinct PoW block). Cap to keep the request bounded.
    static let maxCommitters = 256

    static func encodeRequest(requestId: UInt64, chainPath: [String], committerHashes: [String]) -> Data {
        var out = Data()
        out.appendUInt64BE(requestId)
        out.appendUInt16BE(UInt16(Swift.min(chainPath.count, maxChainPathDepth)))
        for element in chainPath.prefix(maxChainPathDepth) { out.appendLPString(element) }
        let committers = committerHashes.prefix(maxCommitters)
        out.appendUInt16BE(UInt16(committers.count))
        for hash in committers { out.appendLPString(hash) }
        return out
    }

    static func decodeRequest(_ data: Data) -> (requestId: UInt64, chainPath: [String], committerHashes: [String])? {
        var r = ByteCursor(data)
        guard let id = r.readUInt64BE(), let count = r.readUInt16BE(), count <= maxChainPathDepth else { return nil }
        var path: [String] = []
        for _ in 0..<count { guard let s = r.readLPString() else { return nil }; path.append(s) }
        guard let committerCount = r.readUInt16BE(), committerCount <= maxCommitters else { return nil }
        var committers: [String] = []
        for _ in 0..<committerCount { guard let s = r.readLPString() else { return nil }; committers.append(s) }
        return (id, path, committers)
    }

    static func encodeResponse(requestId: UInt64, weight: UInt256?) -> Data {
        var out = Data()
        out.appendUInt64BE(requestId)
        if let weight {
            out.append(1)
            out.appendLPString(weight.toPrefixedHexString())
        } else {
            out.append(0)
        }
        return out
    }

    static func decodeResponse(_ data: Data) -> (requestId: UInt64, weight: UInt256?)? {
        var r = ByteCursor(data)
        guard let id = r.readUInt64BE(), let has = r.readUInt8() else { return nil }
        if has == 0 { return (id, nil) }
        guard let hex = r.readLPString(), let weight = UInt256.fromHexString(hex) else { return nil }
        return (id, weight)
    }
}

// MARK: - Minimal big-endian byte helpers (local to the provider wire)

private extension Data {
    mutating func appendUInt64BE(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(shift)) & 0xff)) }
    }
    mutating func appendUInt16BE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendLPString(_ s: String) {
        let bytes = Data(s.utf8)
        let n = Swift.min(bytes.count, 0xffff)
        appendUInt16BE(UInt16(n))
        append(bytes.prefix(n))
    }
}

private struct ByteCursor {
    private let data: Data
    private var i: Int
    init(_ data: Data) { self.data = data; self.i = data.startIndex }
    mutating func readUInt8() -> UInt8? {
        guard i < data.endIndex else { return nil }
        defer { i += 1 }
        return data[i]
    }
    mutating func readUInt16BE() -> UInt16? {
        guard let a = readUInt8(), let b = readUInt8() else { return nil }
        return (UInt16(a) << 8) | UInt16(b)
    }
    mutating func readUInt64BE() -> UInt64? {
        var v: UInt64 = 0
        for _ in 0..<8 { guard let b = readUInt8() else { return nil }; v = (v << 8) | UInt64(b) }
        return v
    }
    mutating func readLPString() -> String? {
        guard let len = readUInt16BE() else { return nil }
        guard i + Int(len) <= data.endIndex else { return nil }
        let slice = data[i..<i + Int(len)]
        i += Int(len)
        return String(data: slice, encoding: .utf8)
    }
}
