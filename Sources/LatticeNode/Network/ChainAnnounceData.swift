import Foundation
import Ivy
import Tally

public struct ChainAnnounceData: Sendable, Equatable {
    public let protocolVersion: UInt16
    public let chainDirectory: String
    public let tipHeight: UInt64
    public let tipCID: String
    public let specCID: String

    public init(chainDirectory: String, tipHeight: UInt64, tipCID: String, specCID: String, protocolVersion: UInt16 = LatticeProtocol.version) {
        self.protocolVersion = protocolVersion
        self.chainDirectory = chainDirectory
        self.tipHeight = tipHeight
        self.tipCID = tipCID
        self.specCID = specCID
    }

    public func serialize() -> Data {
        let dirBytes = Array(chainDirectory.utf8.prefix(Int(UInt16.max)))
        let tipCIDBytes = Array(tipCID.utf8.prefix(Int(UInt16.max)))
        let specCIDBytes = Array(specCID.utf8.prefix(Int(UInt16.max)))
        var buf = Data()
        var pv = protocolVersion.bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &pv) { Array($0) })
        var v1 = UInt16(dirBytes.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v1) { Array($0) })
        buf.append(contentsOf: dirBytes)
        var v2 = tipHeight.bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v2) { Array($0) })
        var v3 = UInt16(tipCIDBytes.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v3) { Array($0) })
        buf.append(contentsOf: tipCIDBytes)
        var v4 = UInt16(specCIDBytes.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v4) { Array($0) })
        buf.append(contentsOf: specCIDBytes)
        return buf
    }

    public static func deserialize(_ data: Data) -> ChainAnnounceData? {
        guard data.count >= 2 else { return nil }
        var offset = 0

        func readUInt16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let b0 = data[data.startIndex + offset]
            let b1 = data[data.startIndex + offset + 1]
            offset += 2
            return UInt16(b0) << 8 | UInt16(b1)
        }
        func readUInt64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            var val: UInt64 = 0
            for i in 0..<8 {
                val = val << 8 | UInt64(data[data.startIndex + offset + i])
            }
            offset += 8
            return val
        }
        func readString() -> String? {
            guard let len = readUInt16(), offset + Int(len) <= data.count else { return nil }
            let str = String(data: data[data.startIndex + offset ..< data.startIndex + offset + Int(len)], encoding: .utf8)
            offset += Int(len)
            return str
        }

        guard let protoVer = readUInt16(),
              let dir = readString(),
              let tipIdx = readUInt64(),
              let tipCID = readString(),
              let specCID = readString() else { return nil }
        return ChainAnnounceData(
            chainDirectory: dir,
            tipHeight: tipIdx,
            tipCID: tipCID,
            specCID: specCID,
            protocolVersion: protoVer
        )
    }
}

