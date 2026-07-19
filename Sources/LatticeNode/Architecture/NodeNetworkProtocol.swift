import Foundation
import Ivy
import Lattice
import UInt256
import cashew

enum NodeNetworkTopic {
    enum Plane { case overlay, hierarchy }

    static let overlayHello = "lattice.overlay.hello.v1"
    static let blockAnnouncement = "lattice.overlay.block.v1"
    static let predecessorRequest = "lattice.overlay.predecessor.v1"
    static let hierarchyHello = "lattice.hierarchy.hello.v1"
    static let childEvidenceRequest = "lattice.hierarchy.evidence.request.v1"
    static let childEvidenceResponse = "lattice.hierarchy.evidence.response.v1"
    static let childEvidenceAvailable = "lattice.hierarchy.evidence.available.v1"
    static let childEvidenceIndexRequest = "lattice.hierarchy.evidence.index.request.v1"
    static let childEvidenceIndexResponse = "lattice.hierarchy.evidence.index.response.v1"
    static let childProofRootsRequest = "lattice.hierarchy.proof-roots.request.v1"
    static let childProofRootsResponse = "lattice.hierarchy.proof-roots.response.v1"
    static let childCandidateRequest = "lattice.hierarchy.child-candidate.request.v1"
    static let childCandidateResponse = "lattice.hierarchy.child-candidate.response.v1"
    static let coverageRequest = "lattice.hierarchy.coverage.v1"
    static let inheritedWorkResponse = "lattice.hierarchy.inherited-work.v1"

    static func plane(for topic: String) -> Plane? {
        switch topic {
        case overlayHello, blockAnnouncement, predecessorRequest: .overlay
        case hierarchyHello, childEvidenceRequest, childEvidenceResponse,
             childEvidenceAvailable,
             childEvidenceIndexRequest, childEvidenceIndexResponse,
             childProofRootsRequest, childProofRootsResponse,
             childCandidateRequest, childCandidateResponse,
             coverageRequest, inheritedWorkResponse: .hierarchy
        default: nil
        }
    }
}

enum NodeNetworkWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

private let _maximumNodeMessageSize = Int(IvyConfig.protocolMaxFrameSize) - 256

protocol NodeJSONMessage: Codable {
    func validate() throws
}

extension NodeJSONMessage {
    func encoded() throws -> Data {
        try validate()
        let data = try _canonicalJSONEncode(self)
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw NodeNetworkWireError.malformed
        }
        try value.validate()
        guard try value.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return value
    }
}

struct BlockAnnouncementMessage: NodeJSONMessage, Equatable, Sendable {
    let blockCID: String

    func validate() throws {
        guard _isBoundedWireAtom(blockCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct PredecessorRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let predecessorCID: String

    func validate() throws {
        guard _isBoundedWireAtom(predecessorCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

enum ChildEvidenceRequestKind: String, Codable, Sendable {
    case proof
    case parentCarrier
    case parentGenesis
}

struct ChildEvidenceRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let childCID: String
    let kind: ChildEvidenceRequestKind
    let proofRootCID: String?
    let carrierCID: String?
    let rootCID: String?
    let directory: String?
    let childGenesisCID: String?

    init?(
        requestID: UInt64,
        requirement: CrossChainEvidenceRequirement,
        expectedChildPath: [String],
        expectedChildCID: String,
        proofRootCID: String?
    ) {
        self.requestID = requestID
        childPath = expectedChildPath
        childCID = expectedChildCID
        self.proofRootCID = proofRootCID
        switch requirement {
        case .childProof(let path, let cid):
            guard path == expectedChildPath, cid == expectedChildCID else { return nil }
            kind = .proof
            carrierCID = nil
            rootCID = nil
            directory = nil
            childGenesisCID = nil
        case .parentCarrier(let parentPath, let carrier, let root):
            guard parentPath == Array(expectedChildPath.dropLast()) else { return nil }
            kind = .parentCarrier
            carrierCID = carrier
            rootCID = root
            directory = nil
            childGenesisCID = nil
        case .parentGenesis(let parentPath, let childDirectory, let genesisCID):
            guard parentPath == Array(expectedChildPath.dropLast()),
                  childDirectory == expectedChildPath.last else { return nil }
            kind = .parentGenesis
            carrierCID = nil
            rootCID = nil
            directory = childDirectory
            childGenesisCID = genesisCID
        }
        guard (try? validate()) != nil else { return nil }
    }

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath),
              childPath.count > 1,
              _isBoundedWireAtom(childCID) else {
            throw NodeNetworkWireError.malformed
        }
        let valid: Bool
        switch kind {
        case .proof:
            valid = (proofRootCID.map({ _isBoundedWireAtom($0) }) ?? true)
                && carrierCID == nil && rootCID == nil
                && directory == nil && childGenesisCID == nil
        case .parentCarrier:
            valid = proofRootCID.map({ _isBoundedWireAtom($0) }) == true
                && rootCID == proofRootCID
                && carrierCID.map({ _isBoundedWireAtom($0) }) == true
                && rootCID.map({ _isBoundedWireAtom($0) }) == true
                && directory == nil && childGenesisCID == nil
        case .parentGenesis:
            valid = proofRootCID.map({ _isBoundedWireAtom($0) }) == true
                && carrierCID == nil && rootCID == nil
                && directory == childPath.last
                && directory.map({ !$0.isEmpty && $0.utf8.count <= Int(UInt16.max) }) == true
                && childGenesisCID.map({ _isBoundedWireAtom($0) }) == true
        }
        guard valid else { throw NodeNetworkWireError.malformed }
    }
}

struct ChildEvidenceResponseMessage: Sendable {
    static let maximumAcquisitionEntries = Int(UInt16.max)

    let requestID: UInt64
    let childCID: String
    let candidateData: Data?
    let acquisitionEntries: [String: Data]
    let envelope: ChildValidationPackageEnvelope

    init(
        requestID: UInt64,
        childCID: String,
        candidateData: Data? = nil,
        acquisitionEntries: [String: Data] = [:],
        envelope: ChildValidationPackageEnvelope
    ) {
        self.requestID = requestID
        self.childCID = childCID
        self.candidateData = candidateData
        self.acquisitionEntries = acquisitionEntries
        self.envelope = envelope
    }

    func encoded() throws -> Data {
        guard requestID != 0, _isBoundedWireAtom(childCID),
              candidateData.map({ !$0.isEmpty }) ?? true,
              acquisitionEntries.count <= Self.maximumAcquisitionEntries,
              acquisitionEntries[childCID].map({ entry in
                  candidateData.map({ $0 == entry }) ?? true
              }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
        let childBytes = Data(childCID.utf8)
        let candidateBytes = candidateData ?? Data()
        let envelopeBytes = try envelope.encode()
        let sortedEntries = acquisitionEntries.sorted { $0.key < $1.key }
        var framedEntryBytes = 0
        for (cid, entry) in sortedEntries {
            guard _isBoundedWireAtom(cid),
                  !entry.isEmpty,
                  entry.count <= Int(UInt32.max) else {
                throw NodeNetworkWireError.malformed
            }
            framedEntryBytes += 6 + cid.utf8.count + entry.count
        }
        guard childBytes.count <= Int(UInt16.max),
              candidateBytes.count <= Int(UInt32.max),
              framedEntryBytes <= ChildAcquisitionPackage.maximumBytes,
              16 + childBytes.count + candidateBytes.count
                + framedEntryBytes + envelopeBytes.count
                <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(
            capacity: 16 + childBytes.count + candidateBytes.count
                + framedEntryBytes + envelopeBytes.count
        )
        data.appendUInt64(requestID)
        data.appendUInt16(UInt16(childBytes.count))
        data.append(childBytes)
        data.appendUInt32(UInt32(candidateBytes.count))
        data.append(candidateBytes)
        data.appendUInt16(UInt16(sortedEntries.count))
        for (cid, entry) in sortedEntries {
            let cidBytes = Data(cid.utf8)
            data.appendUInt16(UInt16(cidBytes.count))
            data.append(cidBytes)
            data.appendUInt32(UInt32(entry.count))
            data.append(entry)
        }
        data.append(envelopeBytes)
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let requestID = data.readUInt64(at: &position), requestID != 0,
              let childLength = data.readUInt16(at: &position),
              data.distance(from: position, to: data.endIndex) > Int(childLength) else {
            throw NodeNetworkWireError.malformed
        }
        let childEnd = data.index(position, offsetBy: Int(childLength))
        guard let childCID = String(data: data[position..<childEnd], encoding: .utf8),
              _isBoundedWireAtom(childCID) else {
            throw NodeNetworkWireError.malformed
        }
        position = childEnd
        guard let candidateLength = data.readUInt32(at: &position),
              data.distance(from: position, to: data.endIndex)
                > Int(candidateLength) else {
            throw NodeNetworkWireError.malformed
        }
        let candidateEnd = data.index(position, offsetBy: Int(candidateLength))
        let candidateData = candidateLength == 0
            ? nil
            : Data(data[position..<candidateEnd])
        position = candidateEnd
        guard let entryCount = data.readUInt16(at: &position),
              Int(entryCount) <= Self.maximumAcquisitionEntries else {
            throw NodeNetworkWireError.malformed
        }
        var acquisitionEntries: [String: Data] = [:]
        acquisitionEntries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            guard let cid = data.readString(at: &position),
                  _isBoundedWireAtom(cid),
                  let entry = data.readUInt32Bytes(at: &position),
                  !entry.isEmpty,
                  acquisitionEntries[cid] == nil else {
                throw NodeNetworkWireError.malformed
            }
            acquisitionEntries[cid] = entry
        }
        guard position < data.endIndex else {
            throw NodeNetworkWireError.malformed
        }
        let envelope = try ChildValidationPackageEnvelope.decode(Data(data[position...]))
        let message = Self(
            requestID: requestID,
            childCID: childCID,
            candidateData: candidateData,
            acquisitionEntries: acquisitionEntries,
            envelope: envelope
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }

    static func maximumAcquisitionBytes(
        childCID: String,
        candidateByteCount: Int = 0,
        envelopeByteCount: Int
    ) -> Int {
        min(
            ChildAcquisitionPackage.maximumBytes,
            max(
                0,
                _maximumNodeMessageSize - 16 - childCID.utf8.count
                    - candidateByteCount - envelopeByteCount
            )
        )
    }
}

struct ChildEvidenceAvailableMessage: NodeJSONMessage, Equatable, Sendable {
    let childPath: [String]
    let childCID: String
    let rootCID: String

    func validate() throws {
        guard _isAbsoluteChainPath(childPath), childPath.count > 1,
              _isBoundedWireAtom(childCID),
              _isBoundedWireAtom(rootCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildEvidenceIndexRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let after: IssuedChildEvidenceSummary?

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              after.map({
                  _isBoundedWireAtom($0.childCID)
                    && _isBoundedWireAtom($0.rootCID)
              }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildEvidenceIndexResponseMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumEntries = 64

    let requestID: UInt64
    let childPath: [String]
    let after: IssuedChildEvidenceSummary?
    let entries: [IssuedChildEvidenceSummary]
    let hasMore: Bool

    func validate() throws {
        let sorted = entries.sorted {
            ($0.childCID, $0.rootCID) < ($1.childCID, $1.rootCID)
        }
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              entries.count <= Self.maximumEntries,
              entries == sorted,
              Set(entries).count == entries.count,
              entries.allSatisfy({ entry in
                  _isBoundedWireAtom(entry.childCID)
                    && _isBoundedWireAtom(entry.rootCID)
                    && after.map({ cursor in
                        (entry.childCID, entry.rootCID)
                            > (cursor.childCID, cursor.rootCID)
                    }) ?? true
              }),
              !hasMore || !entries.isEmpty else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildProofRootsRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let childCID: String
    let afterRootCID: String?

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              _isBoundedWireAtom(childCID),
              afterRootCID.map({ _isBoundedWireAtom($0) }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildProofRootsResponseMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumRoots = 256

    let requestID: UInt64
    let childPath: [String]
    let childCID: String
    let afterRootCID: String?
    let rootCIDs: [String]
    let hasMore: Bool

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              _isBoundedWireAtom(childCID),
              afterRootCID.map({ _isBoundedWireAtom($0) }) ?? true,
              rootCIDs.count <= Self.maximumRoots,
              rootCIDs == Array(Set(rootCIDs)).sorted(),
              rootCIDs.allSatisfy({ _isBoundedWireAtom($0) }),
              rootCIDs.allSatisfy({ root in
                  afterRootCID.map({ root > $0 }) ?? true
              }),
              !hasMore || !rootCIDs.isEmpty else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// One provisional parent carrier context sent only to its immediate child.
struct ChildCandidateRequestMessage: Sendable {
    static let maximumBudgetMilliseconds: UInt32 = 60_000
    static let maximumRewards = 256
    static let maximumRewardBytes = ChainServiceLimits.maximumPayloadBytes
    static let maximumEncodedBytes = _maximumNodeMessageSize

    let requestID: UInt64
    let budgetMilliseconds: UInt32
    let childPath: [String]
    let parentCID: String
    let parentData: Data
    let rewards: [MiningReward]

    func encoded() throws -> Data {
        guard requestID != 0,
              (1...Self.maximumBudgetMilliseconds).contains(budgetMilliseconds),
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(parentCID),
              parentData.count <= Int(UInt32.max),
              _contentBoundBlock(cid: parentCID, data: parentData) != nil,
              rewards.count <= Self.maximumRewards else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let parentBytes = Data(parentCID.utf8)
        let rewardBytes = try _encodeMiningRewards(
            rewards,
            under: childPath
        )
        guard rewardBytes.count <= Self.maximumRewardBytes,
              rewardBytes.count <= Int(UInt32.max) else {
            throw NodeNetworkWireError.malformed
        }
        let size = 12 + 2 + pathBytes.reduce(0) { $0 + 2 + $1.count }
            + 2 + parentBytes.count + 4 + rewardBytes.count
            + 4 + parentData.count
        guard size <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(capacity: size)
        data.appendUInt64(requestID)
        data.appendUInt32(budgetMilliseconds)
        data.appendUInt16(UInt16(pathBytes.count))
        for component in pathBytes {
            data.appendUInt16(UInt16(component.count))
            data.append(component)
        }
        data.appendUInt16(UInt16(parentBytes.count))
        data.append(parentBytes)
        data.appendUInt32(UInt32(rewardBytes.count))
        data.append(rewardBytes)
        data.appendUInt32(UInt32(parentData.count))
        data.append(parentData)
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let requestID = data.readUInt64(at: &position), requestID != 0,
              let budgetMilliseconds = data.readUInt32(at: &position),
              let pathCount = data.readUInt16(at: &position), pathCount > 1 else {
            throw NodeNetworkWireError.malformed
        }
        var childPath: [String] = []
        childPath.reserveCapacity(Int(pathCount))
        for _ in 0..<pathCount {
            guard let length = data.readUInt16(at: &position), length > 0,
                  data.distance(from: position, to: data.endIndex) >= Int(length) else {
                throw NodeNetworkWireError.malformed
            }
            let end = data.index(position, offsetBy: Int(length))
            guard let component = String(
                data: data[position..<end],
                encoding: .utf8
            ) else {
                throw NodeNetworkWireError.malformed
            }
            childPath.append(component)
            position = end
        }
        guard let parentLength = data.readUInt16(at: &position), parentLength > 0,
              data.distance(from: position, to: data.endIndex) >= Int(parentLength) else {
            throw NodeNetworkWireError.malformed
        }
        let parentEnd = data.index(position, offsetBy: Int(parentLength))
        guard let parentCID = String(
            data: data[position..<parentEnd],
            encoding: .utf8
        ) else {
            throw NodeNetworkWireError.malformed
        }
        position = parentEnd
        guard let rewardLength = data.readUInt32(at: &position),
              rewardLength <= Self.maximumRewardBytes,
              data.distance(from: position, to: data.endIndex)
                > Int(rewardLength) + 4 else {
            throw NodeNetworkWireError.malformed
        }
        let rewardEnd = data.index(position, offsetBy: Int(rewardLength))
        guard let rewards = try? _decodeMiningRewards(
            Data(data[position..<rewardEnd]),
            under: childPath
        ) else {
            throw NodeNetworkWireError.malformed
        }
        position = rewardEnd
        guard let blockLength = data.readUInt32(at: &position), blockLength > 0,
              data.distance(from: position, to: data.endIndex) == Int(blockLength) else {
            throw NodeNetworkWireError.malformed
        }
        let message = Self(
            requestID: requestID,
            budgetMilliseconds: budgetMilliseconds,
            childPath: childPath,
            parentCID: parentCID,
            parentData: Data(data[position...]),
            rewards: rewards
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }
}

/// A contextual unmined child template returned to the exact requesting parent.
/// It is ephemeral mining input, never parent-owned child-chain state.
struct ChildCandidateResponseMessage: Sendable {
    let requestID: UInt64
    let childPath: [String]
    let parentCID: String
    let childCID: String
    let searchTarget: UInt256
    let blockData: Data
    let acquisitionEntries: [String: Data]

    func encoded() throws -> Data {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(parentCID), _isBoundedWireAtom(childCID),
              searchTarget > .zero,
              blockData.count <= Int(UInt32.max),
              let block = _contentBoundBlock(cid: childCID, data: blockData),
              searchTarget >= block.target,
              let package = try? ChildAcquisitionPackage(
                  entries: acquisitionEntries,
                  childCID: childCID,
                  childData: blockData,
                  maximumBytes: ChildAcquisitionPackage.maximumBytes
              ) else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let parentBytes = Data(parentCID.utf8)
        let childBytes = Data(childCID.utf8)
        let targetBytes = Data(searchTarget.toHexString().utf8)
        let extraEntries = acquisitionEntries
            .filter { $0.key != childCID }
            .sorted { $0.key < $1.key }
        guard targetBytes.count == 64 else { throw NodeNetworkWireError.malformed }
        let size = 8 + 2 + pathBytes.reduce(0) { $0 + 2 + $1.count }
            + 2 + parentBytes.count + 2 + childBytes.count
            + targetBytes.count + 4 + blockData.count + 2
            + package.framedByteCount - (6 + childBytes.count + blockData.count)
        guard extraEntries.count <= Int(UInt16.max),
              size <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(capacity: size)
        data.appendUInt64(requestID)
        data.appendUInt16(UInt16(pathBytes.count))
        for component in pathBytes {
            data.appendUInt16(UInt16(component.count))
            data.append(component)
        }
        data.appendUInt16(UInt16(parentBytes.count))
        data.append(parentBytes)
        data.appendUInt16(UInt16(childBytes.count))
        data.append(childBytes)
        data.append(targetBytes)
        data.appendUInt32(UInt32(blockData.count))
        data.append(blockData)
        data.appendUInt16(UInt16(extraEntries.count))
        for (cid, entry) in extraEntries {
            let cidBytes = Data(cid.utf8)
            data.appendUInt16(UInt16(cidBytes.count))
            data.append(cidBytes)
            data.appendUInt32(UInt32(entry.count))
            data.append(entry)
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let requestID = data.readUInt64(at: &position), requestID != 0,
              let childPath = data.readChainPath(at: &position),
              let parentCID = data.readString(at: &position),
              let childCID = data.readString(at: &position),
              data.distance(from: position, to: data.endIndex) >= 64 else {
            throw NodeNetworkWireError.malformed
        }
        let targetEnd = data.index(position, offsetBy: 64)
        guard let targetHex = String(
                data: data[position..<targetEnd],
                encoding: .utf8
              ), let searchTarget = UInt256.fromHexString(targetHex) else {
            throw NodeNetworkWireError.malformed
        }
        position = targetEnd
        guard let blockLength = data.readUInt32(at: &position), blockLength > 0,
              data.distance(from: position, to: data.endIndex) > Int(blockLength) else {
            throw NodeNetworkWireError.malformed
        }
        let blockEnd = data.index(position, offsetBy: Int(blockLength))
        let blockData = Data(data[position..<blockEnd])
        position = blockEnd
        guard let entryCount = data.readUInt16(at: &position) else {
            throw NodeNetworkWireError.malformed
        }
        var acquisitionEntries = [childCID: blockData]
        acquisitionEntries.reserveCapacity(Int(entryCount) + 1)
        for _ in 0..<entryCount {
            guard let cid = data.readString(at: &position), cid != childCID,
                  _isBoundedWireAtom(cid),
                  let entry = data.readUInt32Bytes(at: &position),
                  !entry.isEmpty,
                  acquisitionEntries[cid] == nil else {
                throw NodeNetworkWireError.malformed
            }
            acquisitionEntries[cid] = entry
        }
        guard position == data.endIndex else {
            throw NodeNetworkWireError.malformed
        }
        let message = Self(
            requestID: requestID,
            childPath: childPath,
            parentCID: parentCID,
            childCID: childCID,
            searchTarget: searchTarget,
            blockData: blockData,
            acquisitionEntries: acquisitionEntries
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }
}

struct ParentCoverageEntry: Codable, Equatable, Sendable {
    let childBlockCID: String
    let parentCarrierCIDs: [String]
}

struct CoverageRequestMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumBindings = 4_096

    let requestID: UInt64
    let childPath: [String]
    let entries: [ParentCoverageEntry]

    init(requestID: UInt64, childPath: [String], coverage: [String: Set<String>]) {
        self.requestID = requestID
        self.childPath = childPath
        entries = coverage.map { childCID, parentCIDs in
            ParentCoverageEntry(
                childBlockCID: childCID,
                parentCarrierCIDs: parentCIDs.sorted()
            )
        }.sorted { $0.childBlockCID < $1.childBlockCID }
    }

    var coverage: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: entries.map {
            ($0.childBlockCID, Set($0.parentCarrierCIDs))
        })
    }

    func validate() throws {
        let bindingCount = entries.reduce(0) { $0 + $1.parentCarrierCIDs.count }
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              entries.count <= Self.maximumBindings,
              bindingCount <= Self.maximumBindings,
              entries == entries.sorted(by: { $0.childBlockCID < $1.childBlockCID }),
              Set(entries.map(\.childBlockCID)).count == entries.count,
              entries.allSatisfy({ entry in
                  _isBoundedWireAtom(entry.childBlockCID)
                      && !entry.parentCarrierCIDs.isEmpty
                      && entry.parentCarrierCIDs == Array(Set(entry.parentCarrierCIDs)).sorted()
                      && entry.parentCarrierCIDs.allSatisfy({ _isBoundedWireAtom($0) })
              }) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct InheritedWorkResponseMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let snapshot: InheritedWorkSnapshot

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1 else {
            throw NodeNetworkWireError.malformed
        }
    }
}

private func _encodeMiningRewards(
    _ rewards: [MiningReward],
    under childPath: [String]
) throws -> Data {
    guard rewards.count <= ChildCandidateRequestMessage.maximumRewards,
          rewards.count <= Int(UInt16.max) else {
        throw NodeNetworkWireError.oversized
    }
    var seen: Set<String> = []
    for reward in rewards {
        let pathKey = reward.chainPath.joined(separator: "/")
        guard _isAbsoluteChainPath(reward.chainPath),
              reward.chainPath.count >= childPath.count,
              Array(reward.chainPath.prefix(childPath.count)) == childPath,
              seen.insert(pathKey).inserted,
              let body = reward.transaction.body.node,
              body.chainPath == reward.chainPath,
              (try? ContentBoundTransaction(
                transaction: reward.transaction
              )) != nil else {
            throw NodeNetworkWireError.malformed
        }
    }
    let data = try _canonicalJSONEncode(rewards)
    guard data.count <= ChildCandidateRequestMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    return data
}

private func _decodeMiningRewards(
    _ data: Data,
    under childPath: [String]
) throws -> [MiningReward] {
    guard data.count <= ChildCandidateRequestMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    guard let rewards = try? JSONDecoder().decode(
            [MiningReward].self,
            from: data
          ),
          rewards.count <= ChildCandidateRequestMessage.maximumRewards,
          try _encodeMiningRewards(rewards, under: childPath) == data else {
        throw NodeNetworkWireError.malformed
    }
    return rewards
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    func readUInt16(at position: inout Index) -> UInt16? {
        guard distance(from: position, to: endIndex) >= 2 else { return nil }
        let value = UInt16(self[position])
            | (UInt16(self[index(after: position)]) << 8)
        position = index(position, offsetBy: 2)
        return value
    }

    func readUInt64(at position: inout Index) -> UInt64? {
        guard distance(from: position, to: endIndex) >= 8 else { return nil }
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(self[position]) << UInt64(shift)
            position = index(after: position)
        }
        return value
    }

    func readUInt32(at position: inout Index) -> UInt32? {
        guard distance(from: position, to: endIndex) >= 4 else { return nil }
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(self[position]) << UInt32(shift)
            position = index(after: position)
        }
        return value
    }

    func readString(at position: inout Index) -> String? {
        guard let length = readUInt16(at: &position), length > 0,
              distance(from: position, to: endIndex) >= Int(length) else {
            return nil
        }
        let end = index(position, offsetBy: Int(length))
        guard let value = String(data: self[position..<end], encoding: .utf8) else {
            return nil
        }
        position = end
        return value
    }

    func readUInt32Bytes(at position: inout Index) -> Data? {
        guard let length = readUInt32(at: &position),
              distance(from: position, to: endIndex) >= Int(length) else {
            return nil
        }
        let end = index(position, offsetBy: Int(length))
        let bytes = Data(self[position..<end])
        position = end
        return bytes
    }

    func readChainPath(at position: inout Index) -> [String]? {
        guard let count = readUInt16(at: &position), count > 1 else { return nil }
        var path: [String] = []
        path.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let component = readString(at: &position) else { return nil }
            path.append(component)
        }
        return path
    }
}

func _contentBoundBlock(cid: String, data: Data) -> Block? {
    guard let block = Block(data: data), block.toData() == data,
          let header = try? BlockHeader(node: block), header.rawCID == cid else {
        return nil
    }
    return block
}
