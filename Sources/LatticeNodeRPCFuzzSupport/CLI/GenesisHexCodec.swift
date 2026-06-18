import Foundation
import Lattice

public struct GenesisHexEntry: Sendable, Equatable {
    public let cid: String
    public let data: Data

    public init(cid: String, data: Data) {
        self.cid = cid
        self.data = data
    }
}

public enum GenesisHexCodec {
    public enum ParseError: Error, Equatable {
        case tooLarge
        case malformed
    }

    public static let defaultMaxEntries = 4_096

    public static func parseHex(
        _ hex: String,
        maxPayloadBytes: Int? = nil,
        maxHexChars: Int? = nil,
        maxEntries: Int = defaultMaxEntries
    ) -> [GenesisHexEntry]? {
        try? parseHexThrowing(hex, maxPayloadBytes: maxPayloadBytes, maxHexChars: maxHexChars, maxEntries: maxEntries)
    }

    public static func parseHexThrowing(
        _ hex: String,
        maxPayloadBytes: Int? = nil,
        maxHexChars: Int? = nil,
        maxEntries: Int = defaultMaxEntries
    ) throws -> [GenesisHexEntry] {
        if let maxHexChars, hex.utf8.count > maxHexChars { throw ParseError.tooLarge }
        guard let payload = Data(hex: hex), payload.count >= 2 else { throw ParseError.malformed }
        if let maxPayloadBytes, payload.count > maxPayloadBytes { throw ParseError.tooLarge }
        return try parsePayloadThrowing(payload, maxPayloadBytes: maxPayloadBytes, maxEntries: maxEntries)
    }

    public static func parsePayload(
        _ payload: Data,
        maxPayloadBytes: Int? = nil,
        maxEntries: Int = defaultMaxEntries
    ) -> [GenesisHexEntry]? {
        try? parsePayloadThrowing(payload, maxPayloadBytes: maxPayloadBytes, maxEntries: maxEntries)
    }

    public static func parsePayloadThrowing(
        _ payload: Data,
        maxPayloadBytes: Int? = nil,
        maxEntries: Int = defaultMaxEntries
    ) throws -> [GenesisHexEntry] {
        guard payload.count >= 2 else { throw ParseError.malformed }
        if let maxPayloadBytes, payload.count > maxPayloadBytes { throw ParseError.tooLarge }

        var offset = payload.startIndex
        let entryCount = Int(payload[offset]) | (Int(payload[payload.index(after: offset)]) << 8)
        offset = payload.index(offset, offsetBy: 2)

        var entries: [GenesisHexEntry] = []
        let boundedCount = min(entryCount, maxEntries)
        entries.reserveCapacity(min(boundedCount, 1024))
        for _ in 0..<boundedCount {
            guard payload.distance(from: offset, to: payload.endIndex) > 2 else { break }
            let cidLength = Int(payload[offset]) | (Int(payload[payload.index(offset, offsetBy: 1)]) << 8)
            offset = payload.index(offset, offsetBy: 2)
            guard payload.distance(from: offset, to: payload.endIndex) >= cidLength,
                  let cid = String(data: payload[offset..<payload.index(offset, offsetBy: cidLength)], encoding: .utf8) else {
                break
            }
            offset = payload.index(offset, offsetBy: cidLength)
            guard payload.distance(from: offset, to: payload.endIndex) >= 4 else { break }
            let dataLength = Int(payload[offset]) | (Int(payload[payload.index(offset, offsetBy: 1)]) << 8)
                           | (Int(payload[payload.index(offset, offsetBy: 2)]) << 16)
                           | (Int(payload[payload.index(offset, offsetBy: 3)]) << 24)
            offset = payload.index(offset, offsetBy: 4)
            guard payload.distance(from: offset, to: payload.endIndex) >= dataLength else { break }
            entries.append(GenesisHexEntry(
                cid: cid,
                data: Data(payload[offset..<payload.index(offset, offsetBy: dataLength)])
            ))
            offset = payload.index(offset, offsetBy: dataLength)
        }
        return entries
    }

    public static func encodeEntries(_ entries: [GenesisHexEntry]) -> Data {
        var payload = Data()
        var entryCount = UInt16(min(entries.count, Int(UInt16.max))).littleEndian
        payload.append(Data(bytes: &entryCount, count: 2))
        for entry in entries.prefix(Int(UInt16.max)) {
            let cidBytes = Data(entry.cid.utf8.prefix(Int(UInt16.max)))
            var cidLength = UInt16(cidBytes.count).littleEndian
            payload.append(Data(bytes: &cidLength, count: 2))
            payload.append(cidBytes)
            var dataLength = UInt32(min(entry.data.count, Int(UInt32.max))).littleEndian
            payload.append(Data(bytes: &dataLength, count: 4))
            payload.append(entry.data.prefix(Int(UInt32.max)))
        }
        return payload
    }
}
