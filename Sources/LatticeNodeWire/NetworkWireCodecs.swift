import Foundation

public struct NewBlockWireFrame: Sendable, Equatable {
    public let cid: String
    public let blockData: Data?
}

public struct ChildBlockWireFrame: Sendable, Equatable {
    public let proofData: Data?
    public let cid: String
    public let blockData: Data
}

public struct HeaderRequestWireFrame: Sendable, Equatable {
    public let requestID: Data
    public let fromCID: String
    public let count: UInt32
}

public enum NetworkWireCodecs {
    private static let childProofEnvelopeMagic = Data([0x4C, 0x4E, 0x50, 0x46, 0x53, 0x45, 0x54, 0x31]) // LNPFSET1

    public static func encodeBlockPayload(cid: String, data: Data) -> Data {
        let cidBytes = Data(cid.utf8)
        guard !cidBytes.isEmpty,
              cidBytes.count <= Int(UInt16.max),
              !data.isEmpty else { return Data() }

        var payload = Data(capacity: 2 + cidBytes.count + data.count)
        var cidLen = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLen, count: 2))
        payload.append(cidBytes)
        payload.append(data)
        return payload
    }

    public static func decodeBlockPayload(_ payload: Data) -> (cid: String, data: Data)? {
        guard payload.count > 2 else { return nil }
        let cidLen = Int(payload[payload.startIndex]) | (Int(payload[payload.startIndex + 1]) << 8)
        guard cidLen > 0,
              payload.count >= 2 + cidLen + 1,
              let cid = String(data: payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + cidLen)], encoding: .utf8) else {
            return nil
        }
        let blockData = Data(payload[(payload.startIndex + 2 + cidLen)...])
        guard !blockData.isEmpty else { return nil }
        return (cid, blockData)
    }

    public static func parseNewBlockPayload(_ payload: Data) -> NewBlockWireFrame? {
        if let decoded = decodeBlockPayload(payload) {
            return NewBlockWireFrame(cid: decoded.cid, blockData: decoded.data)
        }

        guard payload.count <= 2 else { return nil }
        guard let cid = String(data: payload, encoding: .utf8) else { return nil }
        return NewBlockWireFrame(cid: cid, blockData: nil)
    }

    /// the DECLARED inline-proof length (the `proofLen` header field),
    /// read straight from the raw childBlock wire bytes WITHOUT copying the proof
    /// body. Lets the gossip handler reject an oversized declared proof at the
    /// node-controlled wire boundary BEFORE `parseChildBlockPayload` allocates the
    /// `Data(...)` copy of the proof. Returns nil when the frame is too short to
    /// carry the `[proofLen:UInt32 LE]` prefix. Fail closed.
    public static func childBlockDeclaredProofLength(_ payload: Data) -> Int? {
        guard payload.count >= 4 else { return nil }
        let offset = payload.startIndex
        return Int(payload[offset]) | (Int(payload[offset + 1]) << 8)
            | (Int(payload[offset + 2]) << 16) | (Int(payload[offset + 3]) << 24)
    }

    public static func parseChildBlockPayload(_ payload: Data) -> ChildBlockWireFrame? {
        parseCurrentChildBlockPayload(payload)
    }

    private static func parseCurrentChildBlockPayload(_ payload: Data) -> ChildBlockWireFrame? {
        guard payload.count > 6 else { return nil }
        var offset = payload.startIndex
        guard payload.distance(from: offset, to: payload.endIndex) >= 4 else { return nil }
        let proofLength = Int(payload[offset]) | (Int(payload[offset + 1]) << 8)
            | (Int(payload[offset + 2]) << 16) | (Int(payload[offset + 3]) << 24)
        offset += 4

        let proofData: Data?
        if proofLength > 0 {
            guard payload.distance(from: offset, to: payload.endIndex) >= proofLength else { return nil }
            let proofStart = offset
            let proofEnd = offset + proofLength
            guard payload.distance(from: proofStart, to: proofEnd) >= childProofEnvelopeMagic.count,
                  payload[proofStart..<proofStart + childProofEnvelopeMagic.count] == childProofEnvelopeMagic else {
                return nil
            }
            proofData = Data(payload[proofStart..<proofEnd])
            offset += proofLength
        } else {
            proofData = nil
        }

        guard payload.distance(from: offset, to: payload.endIndex) > 2 else { return nil }
        let cidLength = Int(payload[offset]) | (Int(payload[offset + 1]) << 8)
        offset += 2
        guard payload.distance(from: offset, to: payload.endIndex) >= cidLength + 1,
              let cid = String(data: payload[offset..<(offset + cidLength)], encoding: .utf8) else {
            return nil
        }
        offset += cidLength

        let blockData = Data(payload[offset...])
        guard !blockData.isEmpty else { return nil }
        return ChildBlockWireFrame(
            proofData: proofData,
            cid: cid,
            blockData: blockData
        )
    }

    // MARK: - Header batch wire codec (getHeaders/getHeaders2 ↔ headerBatch/headerBatch2)
    //
    // Canonical, fail-closed codec for the bulk header-fetch wire format.
    // This is the SINGLE implementation: ChainNetwork+SyncRequests and
    // ParentChainBlockExtractor both build requests and parse responses
    // through these functions (previously each re-implemented the format,
    // and the extractor twin accepted a silently-truncated PREFIX of a
    // proof-carrying header set — fail open on untrusted peer bytes).
    //
    // Wire layout (all integers little-endian):
    //   request   = requestID(16) | cidLen:u16 | fromCID | count:u32
    //   response  = requestID(16) | numHeaders:u32 | entries…
    //   entry     = cidLen:u16 | cid | dataLen:u32 | data            (headerBatch)
    //   entry2    = entry | proofLen:u32 | proof                     (headerBatch2)
    //
    // Fail-closed semantics: ANY truncation/malformation, or a declared
    // numHeaders above `maxHeaders`, rejects the WHOLE response (nil) —
    // never a truncated prefix. `maxHeaders` is a parameter because the
    // bound lives with the caller (ChainNetwork.maxHeaderBatchSize /
    // the extractor's announce-backfill tuning); LatticeNodeWire stays
    // dependency-free.

    /// Encode a getHeaders/getHeaders2 request. Returns nil when the
    /// requestID is not exactly 16 bytes or the CID overflows its u16
    /// length prefix.
    public static func encodeHeaderRequest(requestID: Data, fromCID: String, count: UInt32) -> Data? {
        guard requestID.count == 16 else { return nil }
        let cidBytes = Data(fromCID.utf8)
        guard cidBytes.count <= Int(UInt16.max) else { return nil }

        var payload = Data(capacity: 16 + 2 + cidBytes.count + 4)
        payload.append(requestID)
        var cidLen = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLen, count: 2))
        payload.append(cidBytes)
        var countLE = count.littleEndian
        payload.append(Data(bytes: &countLE, count: 4))
        return payload
    }

    /// Encode a headerBatch response body: the serving side of
    /// `parseHeaderBatch`. Layout (matched byte-for-byte by the parser):
    /// requestID(16) | numHeaders(u32 LE) | per-header { cidLen(u16 LE) | cid |
    /// dataLen(u32 LE) | data }.
    public static func encodeHeaderBatch(requestID: Data, headers: [(cid: String, data: Data)]) -> Data {
        var response = Data(requestID)
        var numHeaders = UInt32(headers.count).littleEndian
        response.append(Data(bytes: &numHeaders, count: 4))
        for (cid, data) in headers {
            appendHeaderEntry(to: &response, cid: cid, data: data)
        }
        return response
    }

    /// Encode a headerBatch2 (proof-carrying) response body: the serving side
    /// of `parseHeaderBatch2`. Layout (matched byte-for-byte by the parser):
    /// requestID(16) | numHeaders(u32 LE) | per-header { cidLen(u16 LE) | cid |
    /// dataLen(u32 LE) | data | proofLen(u32 LE) | proof }. A nil proof encodes
    /// as a zero-length proof (proofLen = 0, no bytes), which the parser reads
    /// back as nil.
    public static func encodeHeaderBatch2(requestID: Data, entries: [(cid: String, data: Data, proof: Data?)]) -> Data {
        var response = Data(requestID)
        var numHeaders = UInt32(entries.count).littleEndian
        response.append(Data(bytes: &numHeaders, count: 4))
        for (cid, data, proof) in entries {
            appendHeaderEntry(to: &response, cid: cid, data: data)
            let proofBytes = proof ?? Data()
            var pl = UInt32(proofBytes.count).littleEndian
            response.append(Data(bytes: &pl, count: 4))
            response.append(proofBytes)
        }
        return response
    }

    private static func appendHeaderEntry(to response: inout Data, cid: String, data: Data) {
        let cidBytes = Data(cid.utf8)
        var cl = UInt16(cidBytes.count).littleEndian
        response.append(Data(bytes: &cl, count: 2))
        response.append(cidBytes)
        var dl = UInt32(data.count).littleEndian
        response.append(Data(bytes: &dl, count: 4))
        response.append(data)
    }

    /// The 16-byte request ID echoed at the head of a headerBatch/headerBatch2
    /// response, or nil when the payload is too short to be a response at all
    /// (requestID + numHeaders). Extracted separately from the body parse so
    /// the caller can classify unsolicited/wrong-peer responses (and penalize
    /// the sender) before deciding what to do with the entries.
    public static func headerBatchResponseRequestID(_ payload: Data) -> Data? {
        guard payload.count >= 20 else { return nil }
        return Data(payload[payload.startIndex..<(payload.startIndex + 16)])
    }

    /// Parse a headerBatch response body. Fail closed: nil on truncation,
    /// malformation, or numHeaders > maxHeaders — never a truncated prefix.
    public static func parseHeaderBatch(_ payload: Data, maxHeaders: Int) -> [(cid: String, data: Data)]? {
        guard payload.count >= 20 else { return nil }
        let numHeaders = readUInt32LE(payload, at: 16)
        guard numHeaders <= maxHeaders else { return nil }

        var offset = 20
        var results: [(cid: String, data: Data)] = []
        results.reserveCapacity(numHeaders)
        for _ in 0..<numHeaders {
            guard let entry = parseHeaderEntry(payload, at: &offset) else { return nil }
            results.append(entry)
        }
        return results
    }

    /// Parse a headerBatch2 (proof-carrying) response body. Fail closed: nil
    /// on truncation, malformation, or numHeaders > maxHeaders — never a
    /// truncated prefix. A child header set with a missing tail must reject
    /// WHOLE so the syncing child fails closed instead of accepting a short
    /// anchored-header set.
    public static func parseHeaderBatch2(_ payload: Data, maxHeaders: Int) -> [(cid: String, data: Data, proof: Data?)]? {
        guard payload.count >= 20 else { return nil }
        let numHeaders = readUInt32LE(payload, at: 16)
        guard numHeaders <= maxHeaders else { return nil }

        var offset = 20
        var results: [(cid: String, data: Data, proof: Data?)] = []
        results.reserveCapacity(numHeaders)
        for _ in 0..<numHeaders {
            guard let entry = parseHeaderEntry(payload, at: &offset) else { return nil }
            guard offset + 4 <= payload.count else { return nil }
            let proofLen = readUInt32LE(payload, at: offset)
            offset += 4
            guard proofLen <= payload.count - offset else { return nil }
            let proof: Data? = proofLen > 0 ? subdata(payload, at: offset, count: proofLen) : nil
            offset += proofLen
            results.append((cid: entry.cid, data: entry.data, proof: proof))
        }
        return results
    }

    private static func parseHeaderEntry(_ payload: Data, at offset: inout Int) -> (cid: String, data: Data)? {
        guard offset + 2 <= payload.count else { return nil }
        let base = payload.startIndex
        let cidLen = Int(payload[base + offset]) | (Int(payload[base + offset + 1]) << 8)
        offset += 2
        guard offset + cidLen + 4 <= payload.count,
              let cid = String(data: payload[(base + offset)..<(base + offset + cidLen)], encoding: .utf8) else {
            return nil
        }
        offset += cidLen
        let dataLen = readUInt32LE(payload, at: offset)
        offset += 4
        guard dataLen <= payload.count - offset else { return nil }
        let data = subdata(payload, at: offset, count: dataLen)
        offset += dataLen
        return (cid: cid, data: data)
    }

    /// Slice-relative little-endian u32 read. `offset` is relative to
    /// `payload.startIndex` (slice-safe).
    private static func readUInt32LE(_ payload: Data, at offset: Int) -> Int {
        let raw = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return Int(UInt32(littleEndian: raw))
    }

    private static func subdata(_ payload: Data, at offset: Int, count: Int) -> Data {
        let base = payload.startIndex
        return Data(payload[(base + offset)..<(base + offset + count)])
    }

    public static func parseHeaderRequestPayload(_ payload: Data) -> HeaderRequestWireFrame? {
        guard payload.count >= 22 else { return nil }
        let requestID = Data(payload[payload.startIndex..<(payload.startIndex + 16)])
        let cidLength = Int(payload[payload.startIndex + 16]) | (Int(payload[payload.startIndex + 17]) << 8)
        guard payload.count >= 18 + cidLength + 4,
              let fromCID = String(data: payload[(payload.startIndex + 18)..<(payload.startIndex + 18 + cidLength)], encoding: .utf8) else {
            return nil
        }
        let countOffset = 18 + cidLength
        let countLE = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: countOffset, as: UInt32.self)
        }
        return HeaderRequestWireFrame(
            requestID: requestID,
            fromCID: fromCID,
            count: UInt32(littleEndian: countLE)
        )
    }

    public static func encodeMempoolFullPayload(cid: String, bodyData: Data, transactionData: Data) -> Data {
        let cidBytes = Data(cid.utf8)
        guard !cidBytes.isEmpty,
              cidBytes.count <= Int(UInt16.max),
              !bodyData.isEmpty,
              bodyData.count <= Int(UInt32.max) else { return Data() }

        var payload = Data(capacity: 2 + cidBytes.count + 4 + bodyData.count + transactionData.count)
        var cidLen = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLen, count: 2))
        payload.append(cidBytes)
        var bodyLen = UInt32(bodyData.count).littleEndian
        payload.append(Data(bytes: &bodyLen, count: 4))
        payload.append(bodyData)
        payload.append(transactionData)
        return payload
    }

    public static func decodeMempoolFullPayload(_ payload: Data) -> (cid: String, bodyData: Data, transactionData: Data)? {
        guard payload.count >= 6 else { return nil }
        // Index slice-relative (via `subdata` / `payload.startIndex + n`), never
        // with bare absolute offsets. `withUnsafeBytes`/`loadUnaligned` already
        // provide a logical 0-based view, but `Data`'s subscript is startIndex-
        // based, so `payload[2...]` reads the wrong bytes (or traps) when the
        // payload is a non-zero-based slice. Production ingress hands us a
        // zero-based `Data`, but normalize here so this can't break on a slice.
        let base = payload.startIndex
        let cidLenLE = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
        }
        let cidLen = Int(UInt16(littleEndian: cidLenLE))
        guard cidLen > 0, payload.count >= 2 + cidLen + 4 else { return nil }
        guard let cid = String(data: subdata(payload, at: 2, count: cidLen), encoding: .utf8) else { return nil }
        let bodyLenOffset = 2 + cidLen
        let bodyLenLE = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: bodyLenOffset, as: UInt32.self)
        }
        let bodyLen = Int(UInt32(littleEndian: bodyLenLE))
        let bodyStart = bodyLenOffset + 4
        guard bodyLen > 0, payload.count > bodyStart + bodyLen else { return nil }
        let bodyData = subdata(payload, at: bodyStart, count: bodyLen)
        let txData = Data(payload[(base + bodyStart + bodyLen)...])
        return (cid: cid, bodyData: bodyData, transactionData: txData)
    }

    public static func exerciseParserSurface(_ payload: Data) {
        _ = parseNewBlockPayload(payload)
        _ = parseChildBlockPayload(payload)
        _ = parseHeaderRequestPayload(payload)
        _ = decodeMempoolFullPayload(payload)
        _ = headerBatchResponseRequestID(payload)
        // 1_000 mirrors ChainNetwork.maxHeaderBatchSize (the production bound).
        _ = parseHeaderBatch(payload, maxHeaders: 1_000)
        _ = parseHeaderBatch2(payload, maxHeaders: 1_000)
        // The child-proof set codec is a peer-facing ingress parser; drive its
        // deserialize with raw fuzz input too (Module 7).
        _ = ChildBlockProofEnvelope.deserialize(payload)
    }
}
