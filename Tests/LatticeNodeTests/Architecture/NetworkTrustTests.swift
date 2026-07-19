import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import XCTest
import cashew
@testable import LatticeNode

private enum NetworkTestError: Error {
    case failedStart
}

private enum NetworkRuntimeStartOutcome: Equatable, Sendable {
    case started
    case failed(NodeNetworkRuntimeError)
    case unexpected(String)
}

private actor NetworkEventRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ContentRequestRecorder {
    private var values: [(String, [String])] = []
    func append(root: String, cids: [String]) { values.append((root, cids)) }
    func snapshot() -> [(String, [String])] { values }
}

private actor NetworkTestContentStore: Fetcher, Storer {
    private var values: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = values[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func store(entries: [String: Data]) {
        values.merge(entries) { existing, _ in existing }
    }

    func allEntries() -> [String: Data] { values }
}

final class NetworkTrustTests: XCTestCase {
    private let nexusCID = "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let minimumRootWork = String(repeating: "0", count: 63) + "1"

    func testChainHelloPinsNexusPathAndWorkFloor() throws {
        let hello = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"],
            minimumRootWorkHex: minimumRootWork
        )
        let decoded = try ChainHello.decode(hello.encode())
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"],
            expectedMinimumRootWorkHex: minimumRootWork
        ))

        XCTAssertThrowsError(try decoded.validateCompatibility(
            expectedNexusGenesisCID: "different-nexus",
            expectedChainPath: ["Nexus"],
            expectedMinimumRootWorkHex: minimumRootWork
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .wrongNexusGenesis)
        }
    }

    func testChildValidationPackageEnvelopeRoundTripsAndRejectsTrailingBytes() throws {
        let package = ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(
                parentPath: ["Nexus"], carrierCID: "carrier", rootCID: "root"
            ),
            parentGenesisLink: try genesisLink(
                parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
            )
        )
        let encoded = try ChildValidationPackageEnvelope(package).encode()
        let decoded = try ChildValidationPackageEnvelope.decode(encoded)
            .makeValidationPackage()

        XCTAssertEqual(try decoded.proof.serialize(), try package.proof.serialize())
        XCTAssertEqual(decoded.parentCarrierLink, package.parentCarrierLink)
        XCTAssertEqual(decoded.parentGenesisLink, package.parentGenesisLink)

        var trailing = encoded
        trailing.append(0)
        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(trailing))

        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(
            Data(repeating: 0, count: ChildValidationPackageEnvelope.maximumEncodedSize + 1)
        )) { error in
            XCTAssertEqual(error as? ChildValidationPackageEnvelopeError, .oversized)
        }
    }

    func testParentFactGateRequiresConfiguredImmediateParentAndExactEmbeddedPath() throws {
        let nexus = signingKey(31)
        let other = signingKey(32)
        let gate = try AuthenticatedParentFactGate(
            childPath: ["Nexus", "Payments"],
            configuredParentIvyPeerKey: peerKey(nexus).hex
        )
        let validEnvelope = try envelope(parentPath: ["Nexus"])

        XCTAssertNoThrow(try gate.accept(
            validEnvelope,
            from: authenticatedPeer(nexus, role: .endpoint)
        ))

        XCTAssertThrowsError(try gate.accept(
            validEnvelope,
            from: authenticatedPeer(other, role: .endpoint)
        )) { error in
            XCTAssertEqual(error as? AuthenticatedParentFactGateError, .unauthenticatedParent)
        }

        XCTAssertThrowsError(try gate.accept(
            try envelope(parentPath: ["Nexus", "Other"]),
            from: authenticatedPeer(nexus, role: .endpoint)
        )) { error in
            XCTAssertEqual(error as? AuthenticatedParentFactGateError, .wrongParentPath)
        }

        XCTAssertThrowsError(try gate.accept(
            validEnvelope,
            from: AuthenticatedPeer(
                key: peerKey(nexus),
                role: .carrier,
                route: .direct,
                metadata: PeerMetadata()
            )
        )) { error in
            XCTAssertEqual(
                error as? AuthenticatedParentFactGateError,
                .unauthenticatedParent
            )
        }
    }

    func testTwoPlanesHaveDisjointTopologyAndSharedIdentity() throws {
        let parent = signingKey(41)
        let bootstrap = signingKey(46)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-plane-test"),
            privateKeyHex: String(repeating: "2a", count: 32),
            listenPort: 4101,
            factListenPort: 4102,
            rpcPort: 8100,
            bootstrapPeers: [PeerEndpoint(
                publicKey: peerKey(bootstrap).hex,
                host: "overlay.example",
                port: 4101
            )],
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4102
            ),
            minPeerKeyBits: 17
        )
        let planes = try NodeNetworkPlaneConfigurations(configuration)

        XCTAssertEqual(planes.overlay.mode, .overlay)
        XCTAssertEqual(planes.overlay.listenPort, 4101)
        XCTAssertEqual(planes.overlay.minPeerKeyBits, 17)
        XCTAssertEqual(planes.overlay.bootstrapPeers.count, 1)

        XCTAssertEqual(planes.hierarchy.mode, .privateNetwork)
        XCTAssertEqual(planes.hierarchy.listenPort, 4102)
        XCTAssertEqual(planes.hierarchy.minPeerKeyBits, 0)
        XCTAssertEqual(planes.hierarchy.bootstrapPeers, [configuration.parentEndpoint!.ivy])
        XCTAssertTrue(planes.hierarchy.stunServers.isEmpty)
        XCTAssertTrue(planes.hierarchy.carriers.isEmpty)
        XCTAssertFalse(planes.hierarchy.relayEnabled)
        XCTAssertEqual(
            planes.hierarchy.maxConnectionsPerNetgroup,
            IvyConfig.defaultMaxConnections
        )
        XCTAssertEqual(planes.overlay.publicKey, planes.hierarchy.publicKey)

        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.blockAnnouncement),
            .overlay
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.childEvidenceRequest),
            .hierarchy
        )
        XCTAssertNil(NodeNetworkTopic.plane(for: "unknown"))
    }

    func testHierarchyHelloGrantsOnlyExactParentOrImmediateChildRole() throws {
        let parent = signingKey(43)
        let other = signingKey(44)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            minimumRootWork: UInt256(1),
            storagePath: URL(fileURLWithPath: "/tmp/lattice-hierarchy-hello-test"),
            privateKeyHex: String(repeating: "2d", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4002
            )
        )
        let work = configuration.minimumRootWork.toHexString()
        let parentHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: ["Nexus"],
            minimumRootWorkHex: work
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: parentHello,
                peerKey: peerKey(parent).hex,
                configuration: configuration
            ),
            .parent
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: parentHello,
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))

        let childPath = ["Nexus", "Payments", "Receipts"]
        let childHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: childPath,
            minimumRootWorkHex: work
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: childHello,
                peerKey: peerKey(other).hex,
                configuration: configuration
            ),
            .child(childPath)
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus", "Other", "Receipts"],
                minimumRootWorkHex: work
            ),
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))
    }

    func testRootScopedContentKeepsRootAcrossDescendantWavesAndAttribution() async {
        let recorder = ContentRequestRecorder()
        let servingKey = peerKey(signingKey(45)).hex
        let source = IvyRootContentSource { root, cids in
            await recorder.append(root: root, cids: cids)
            var entries = [root: Data("root".utf8)]
            for cid in cids { entries[cid] = Data(cid.utf8) }
            return AttributedContentResponse(
                entries: entries,
                servedBy: PeerID(publicKey: servingKey)
            )
        }

        let unscoped = await source.fetch(["root"])
        XCTAssertTrue(unscoped.isEmpty)
        let result = await source.withRootTracing("root") {
            let root = await source.fetch(["root"])
            let descendants = await source.fetch(["left", "right"])
            return (root, descendants)
        }

        XCTAssertEqual(result.value.0, ["root": Data("root".utf8)])
        XCTAssertEqual(result.value.1, [
            "left": Data("left".utf8),
            "right": Data("right".utf8),
        ])
        XCTAssertEqual(result.attribution.servedByPublicKeys, [servingKey])
        XCTAssertTrue(result.attribution.allResponsesComplete)
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].0, "root")
        XCTAssertEqual(requests[0].1, [])
        XCTAssertEqual(requests[1].0, "root")
        XCTAssertEqual(requests[1].1, ["left", "right"])
    }

    func testEvidenceMergeAccumulatesCarrierAndGenesisWithoutAlternating() throws {
        let proof = proof()
        let carrier = try carrierLink(
            parentPath: ["Nexus"], carrierCID: "carrier", rootCID: "root"
        )
        let genesis = try genesisLink(
            parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
        )
        let proofOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof
        ))
        let carrierOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof,
            parentCarrierLink: carrier
        ))
        let genesisOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof,
            parentGenesisLink: genesis
        ))

        let withCarrier = NodeNetworkRuntime.merging(proofOnly, with: carrierOnly)
        let complete = withCarrier.flatMap {
            NodeNetworkRuntime.merging($0, with: genesisOnly)
        }
        XCTAssertEqual(complete?.package.parentCarrierLink, carrier)
        XCTAssertEqual(complete?.package.parentGenesisLink, genesis)
    }

    func testEvidenceFollowupsPinTheSelectedProofRoot() throws {
        let carrier = ChildEvidenceRequestMessage(
            requestID: 1,
            requirement: .parentCarrier(
                parentPath: ["Nexus"],
                carrierCID: "carrier",
                rootCID: "root-a"
            ),
            expectedChildPath: ["Nexus", "Payments"],
            expectedChildCID: "child",
            proofRootCID: "root-a"
        )
        let decodedCarrier = try carrier.map {
            try ChildEvidenceRequestMessage.decoded($0.encoded())
        }
        XCTAssertEqual(decodedCarrier?.proofRootCID, "root-a")
        XCTAssertNil(ChildEvidenceRequestMessage(
            requestID: 2,
            requirement: .parentCarrier(
                parentPath: ["Nexus"],
                carrierCID: "carrier",
                rootCID: "root-a"
            ),
            expectedChildPath: ["Nexus", "Payments"],
            expectedChildCID: "child",
            proofRootCID: "root-b"
        ))

        let genesis = ChildEvidenceRequestMessage(
            requestID: 3,
            requirement: .parentGenesis(
                parentPath: ["Nexus"],
                directory: "Payments",
                childGenesisCID: "child"
            ),
            expectedChildPath: ["Nexus", "Payments"],
            expectedChildCID: "child",
            proofRootCID: "root-a"
        )
        let decodedGenesis = try genesis.map {
            try ChildEvidenceRequestMessage.decoded($0.encoded())
        }
        XCTAssertEqual(decodedGenesis?.proofRootCID, "root-a")
    }

    func testProofRootPagesCorrelateEveryCursorAndBackpressureOneRoot() throws {
        let request = ChildProofRootsRequestMessage(
            requestID: 10,
            childPath: ["Nexus", "Payments"],
            childCID: "child",
            afterRootCID: "root-a"
        )
        let response = ChildProofRootsResponseMessage(
            requestID: 10,
            childPath: ["Nexus", "Payments"],
            childCID: "child",
            afterRootCID: "root-a",
            rootCIDs: ["root-b"],
            hasMore: true
        )
        let decoded = try ChildProofRootsResponseMessage.decoded(response.encoded())
        XCTAssertTrue(NodeNetworkRuntime.matches(decoded, request: request))
        XCTAssertFalse(NodeNetworkRuntime.matches(
            ChildProofRootsResponseMessage(
                requestID: 10,
                childPath: ["Nexus", "Payments"],
                childCID: "child",
                afterRootCID: "root-b",
                rootCIDs: ["root-c"],
                hasMore: false
            ),
            request: request
        ))
        XCTAssertThrowsError(try ChildProofRootsResponseMessage(
            requestID: 10,
            childPath: ["Nexus", "Payments"],
            childCID: "child",
            afterRootCID: "root-a",
            rootCIDs: [],
            hasMore: true
        ).encoded())
    }

    func testEvidenceIndexPagesAreCanonicalAndCursorBound() throws {
        let cursor = IssuedChildEvidenceSummary(
            childCID: "child-a",
            rootCID: "root-a"
        )
        let request = ChildEvidenceIndexRequestMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor
        )
        XCTAssertEqual(
            try ChildEvidenceIndexRequestMessage.decoded(request.encoded()),
            request
        )
        let response = ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: [
                IssuedChildEvidenceSummary(childCID: "child-b", rootCID: "root-a"),
                IssuedChildEvidenceSummary(childCID: "child-b", rootCID: "root-b"),
            ],
            hasMore: true
        )
        XCTAssertEqual(
            try ChildEvidenceIndexResponseMessage.decoded(response.encoded()),
            response
        )
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: Array(response.entries.reversed()),
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            after: cursor,
            entries: [],
            hasMore: true
        ).encoded())
    }

    func testContextualCandidateWireBindsCarrierRewardSubtreeAndSearchTarget() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let childReward = MiningReward(
            chainPath: ["Nexus", "Payments"],
            transaction: try unsignedTransaction(path: ["Nexus", "Payments"])
        )
        let descendantReward = MiningReward(
            chainPath: ["Nexus", "Payments", "Receipts"],
            transaction: try unsignedTransaction(
                path: ["Nexus", "Payments", "Receipts"]
            )
        )
        let request = ChildCandidateRequestMessage(
            requestID: 11,
            budgetMilliseconds: 750,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
            rewards: [childReward, descendantReward]
        )
        let decodedRequest = try ChildCandidateRequestMessage.decoded(
            request.encoded()
        )
        XCTAssertEqual(decodedRequest.budgetMilliseconds, 750)
        XCTAssertEqual(decodedRequest.rewards.map(\.chainPath), [
            ["Nexus", "Payments"],
            ["Nexus", "Payments", "Receipts"],
        ])
        XCTAssertNotNil(decodedRequest.rewards[0].transaction.body.node)

        let response = ChildCandidateResponseMessage(
            requestID: 11,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: parentCID,
            searchTarget: parent.target,
            blockData: parentData,
            acquisitionEntries: [parentCID: parentData]
        )
        let decodedResponse = try ChildCandidateResponseMessage.decoded(
            response.encoded()
        )
        XCTAssertEqual(decodedResponse.parentCID, parentCID)
        XCTAssertEqual(decodedResponse.searchTarget, parent.target)
        XCTAssertEqual(decodedResponse.acquisitionEntries[parentCID], parentData)

        XCTAssertThrowsError(try ChildCandidateRequestMessage(
            requestID: 12,
            budgetMilliseconds: 750,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
            rewards: [MiningReward(
                chainPath: ["Nexus", "Other"],
                transaction: try unsignedTransaction(path: ["Nexus", "Other"])
            )]
        ).encoded())
    }

    func testCandidateAndEvidencePackagesRejectMissingMismatchedAndOversizedContent() async throws {
        let block = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let blockData = try XCTUnwrap(block.toData())
        func candidate(_ entries: [String: Data]) -> ChildCandidateResponseMessage {
            ChildCandidateResponseMessage(
                requestID: 19,
                childPath: ["Nexus", "Payments"],
                parentCID: childCID,
                childCID: childCID,
                searchTarget: block.target,
                blockData: blockData,
                acquisitionEntries: entries
            )
        }

        XCTAssertThrowsError(try candidate([:]).encoded())
        XCTAssertThrowsError(try candidate([
            childCID: blockData + Data([0]),
        ]).encoded())
        let oversizedEntries = [
            childCID: blockData,
            "extra": Data(
                repeating: 0,
                count: ChildAcquisitionPackage.maximumBytes
            ),
        ]
        XCTAssertThrowsError(try candidate(oversizedEntries).encoded())

        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        XCTAssertThrowsError(try ChildEvidenceResponseMessage(
            requestID: 20,
            childCID: childCID,
            acquisitionEntries: oversizedEntries,
            envelope: envelope
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }
    }

    func testCandidateRequestEnforcesRewardAndActualFrameBounds() async throws {
        XCTAssertEqual(
            ChildCandidateRequestMessage.maximumRewardBytes,
            ChainServiceLimits.maximumPayloadBytes
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let rewardData = try _canonicalJSONEncode([MiningReward]())
        let fixedBytes = 12 + 2
            + 2 + parentCID.utf8.count
            + 4 + rewardData.count
            + 4 + parentData.count
        let exactPath = wirePath(
            encodedContribution: ChildCandidateRequestMessage.maximumEncodedBytes
                - fixedBytes
        )
        let exact = try ChildCandidateRequestMessage(
            requestID: 15,
            budgetMilliseconds: 750,
            childPath: exactPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: []
        ).encoded()
        XCTAssertEqual(
            exact.count,
            ChildCandidateRequestMessage.maximumEncodedBytes
        )

        let oversizedPath = wirePath(
            encodedContribution: ChildCandidateRequestMessage.maximumEncodedBytes
                - fixedBytes + 1
        )
        XCTAssertThrowsError(try ChildCandidateRequestMessage(
            requestID: 16,
            budgetMilliseconds: 750,
            childPath: oversizedPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: []
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }
    }

    func testCandidateSlotsGiveEveryPathOnePeerBeforeDuplicateClaims() {
        let slots = NodeNetworkRuntime.interleavedChildPeerIndices(
            peerCounts: [4] + Array(repeating: 1, count: 63),
            limit: 64
        )
        XCTAssertEqual(slots.count, 64)
        XCTAssertEqual(Set(slots.map(\.path)).count, 64)
        XCTAssertTrue(slots.allSatisfy { $0.peer == 0 })
    }

    func testProofPreparationRotatesAcrossMoreThanSixtyFourChildPaths() {
        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: 0,
            limit: 64
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: first.next,
            limit: 64
        )
        XCTAssertEqual(first.indices.count, 64)
        XCTAssertFalse(first.indices.contains(64))
        XCTAssertTrue(second.indices.contains(64))
        XCTAssertFalse(second.indices.contains(0))
    }

    func testDisconnectedChildPathsCannotAccumulatePeerRotationState() {
        var rotations = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("Nexus/stale-\($0)", $0)
        })
        rotations["Nexus/active"] = 3
        NodeNetworkRuntime.pruneChildPeerRotations(
            &rotations,
            activeRoles: [.child(["Nexus", "active"])]
        )
        XCTAssertEqual(rotations, ["Nexus/active": 3])
    }

    func testCandidateBudgetsShrinkAndPeerPriorityRotates() {
        let childBudget = NodeNetworkRuntime.remoteChildCandidateBudget(
            parentWaitMilliseconds: 1_000
        )
        let grandchildBudget = childBudget.flatMap {
            NodeNetworkRuntime.remoteChildCandidateBudget(
                parentWaitMilliseconds: UInt64($0)
            )
        }
        XCTAssertEqual(childBudget, 750)
        XCTAssertEqual(grandchildBudget, 563)

        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: 0,
            limit: 2
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: first.next,
            limit: 2
        )
        XCTAssertEqual(first.indices, [0, 1])
        XCTAssertEqual(second.indices, [1, 2])
    }

    func testEvidenceResponseStructurallyCarriesOptionalCandidateBytes() async throws {
        let block = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let childData = try XCTUnwrap(block.toData())
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        let response = ChildEvidenceResponseMessage(
            requestID: 13,
            childCID: childCID,
            candidateData: childData,
            envelope: envelope
        )
        let decoded = try ChildEvidenceResponseMessage.decoded(response.encoded())
        let gated = AuthenticatedChildPackage(
            package: try decoded.envelope.makeValidationPackage()
        )
        let attached = NodeNetworkRuntime.attachingEvidenceContent(
            decoded.candidateData,
            acquisitionEntries: decoded.acquisitionEntries,
            childCID: childCID,
            to: gated
        )
        XCTAssertEqual(attached?.acquisitionEntries[childCID], childData)

        var malformed = childData
        malformed.append(0)
        let deferred = try ChildEvidenceResponseMessage.decoded(
            ChildEvidenceResponseMessage(
            requestID: 14,
            childCID: childCID,
            candidateData: malformed,
            envelope: envelope
            ).encoded()
        )
        XCTAssertEqual(deferred.candidateData, malformed)
    }

    func testEvidenceAcquisitionEntriesAreCanonicalAndAttemptLocal() async throws {
        let process = try await canonicalNetworkProcess()
        let block = try await process.canonicalTipBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let entries = try await process.durableAdmissionEntries(
            for: block,
            maximumBytes: ChainServiceLimits.maximumPayloadBytes
        )
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        let response = ChildEvidenceResponseMessage(
            requestID: 17,
            childCID: childCID,
            acquisitionEntries: entries,
            envelope: envelope
        )
        let decoded = try ChildEvidenceResponseMessage.decoded(response.encoded())
        let attached = NodeNetworkRuntime.attachingEvidenceContent(
            decoded.candidateData,
            acquisitionEntries: decoded.acquisitionEntries,
            childCID: childCID,
            to: AuthenticatedChildPackage(
                package: try decoded.envelope.makeValidationPackage()
            )
        )
        XCTAssertEqual(attached?.acquisitionEntries, entries)

        let extraTransaction = try unsignedTransaction(path: ["Nexus"])
        let extraBody = try XCTUnwrap(extraTransaction.body.node)
        let extraCID = extraTransaction.body.rawCID
        var expanded = entries
        expanded[extraCID] = try XCTUnwrap(extraBody.toData())
        let expandedAttachment = NodeNetworkRuntime.attachingEvidenceContent(
            nil,
            acquisitionEntries: expanded,
            childCID: childCID,
            to: AuthenticatedChildPackage(
                package: try decoded.envelope.makeValidationPackage()
            )
        )
        XCTAssertEqual(expandedAttachment?.acquisitionEntries, expanded)

        var mismatched = entries
        mismatched[childCID]?.append(0)
        let deferred = try ChildEvidenceResponseMessage.decoded(
            ChildEvidenceResponseMessage(
            requestID: 18,
            childCID: childCID,
            acquisitionEntries: mismatched,
            envelope: envelope
            ).encoded()
        )
        XCTAssertEqual(deferred.acquisitionEntries, mismatched)
        do {
            _ = try await BlockHeader(
                rawCID: childCID,
                node: nil,
                encryptionInfo: nil
            ).resolveBlockContent(source: InMemoryContentSource(mismatched))
            XCTFail("accessed mismatched content must fail CID verification")
        } catch {}
    }

    func testPolicyChildBootstrapsFromRestartedParentPackageWithoutOverlay() async throws {
        let source = NetworkTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let module = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0, 0, 0]))
        )
        try await module.storeRecursively(storer: source)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .transaction
        )
        let base = NexusGenesis.spec
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock:
                base.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: base.maxStateGrowth,
            maxBlockSize: base.maxBlockSize,
            premine: 0,
            targetBlockTime: base.targetBlockTime,
            initialReward: base.initialReward,
            halvingInterval: base.halvingInterval,
            retargetWindow: base.retargetWindow,
            wasmPolicies: [policy]
        )
        let child = try await BlockBuilder.buildChildGenesis(
            spec: spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let childData: Data = try XCTUnwrap(child.toData())
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let collector = NetworkTestContentStore()
        try await childHeader.storeBlock(fetcher: source, storer: collector)
        let authoredEntries = await collector.allEntries()
        XCTAssertNotNil(authoredEntries[policy.moduleCID])

        let candidateWire = try ChildCandidateResponseMessage(
            requestID: 91,
            childPath: ["Nexus", "Payments"],
            parentCID: carrierHeader.rawCID,
            childCID: childHeader.rawCID,
            searchTarget: child.target,
            blockData: childData,
            acquisitionEntries: authoredEntries
        ).encoded()
        let candidate = try ChildCandidateResponseMessage.decoded(candidateWire)
        XCTAssertEqual(candidate.acquisitionEntries[policy.moduleCID],
                       authoredEntries[policy.moduleCID])

        let parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-parent-package-\(UUID().uuidString)")
        let childDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-package-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parentDirectory)
            try? FileManager.default.removeItem(at: childDirectory)
        }
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: parentDirectory,
            privateKeyHex: String(repeating: "6a", count: 32)
        )
        var parentStore: NodeStore? = try NodeStore(
            databasePath: parentDirectory.appendingPathComponent("state.db"),
            nexusGenesisCID: parentConfiguration.nexusGenesisCID,
            chainPath: parentConfiguration.chainPath,
            minimumRootWork: parentConfiguration.minimumRootWork
        )
        let carrierLink = try carrierLink(
            parentPath: ["Nexus"],
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let genesisLink = try genesisLink(
            parentPath: ["Nexus"],
            directory: "Payments",
            cid: childHeader.rawCID
        )
        try await parentStore!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Payments",
                child: child,
                proof: proof,
                acquisitionEntries: candidate.acquisitionEntries
            )],
            capacity: 16
        )
        try await parentStore!.persistIssuedParentCarrierLink(
            carrierLink,
            issuerKey: parentConfiguration.processPublicKey
        )
        try await parentStore!.persistIssuedParentGenesisLink(
            genesisLink,
            issuerKey: parentConfiguration.processPublicKey
        )
        parentStore = nil

        let parent = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let recoveredEvidence = try await parent.issuedChildEvidence(
            childCID: childHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let recovered = try XCTUnwrap(recoveredEvidence)
        XCTAssertEqual(recovered.acquisitionEntries[policy.moduleCID],
                       authoredEntries[policy.moduleCID])
        let summaries = try await parent.issuedChildEvidenceSummaries(
            directory: "Payments",
            after: nil,
            limit: 2
        )
        XCTAssertEqual(
            summaries,
            [IssuedChildEvidenceSummary(
                childCID: childHeader.rawCID,
                rootCID: carrierHeader.rawCID
            )]
        )

        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(
                proof: recovered.proof,
                parentCarrierLink: carrierLink,
                parentGenesisLink: genesisLink
            )
        )
        let response = try ChildEvidenceResponseMessage.decoded(
            ChildEvidenceResponseMessage(
                requestID: 92,
                childCID: childHeader.rawCID,
                acquisitionEntries: recovered.acquisitionEntries,
                envelope: envelope
            ).encoded()
        )
        let childProcess = try await ChainProcess.open(configuration:
            NodeConfiguration(
                chainPath: ["Nexus", "Payments"],
                minimumRootWork: UInt256(1),
                storagePath: childDirectory,
                privateKeyHex: String(repeating: "6b", count: 32),
                parentEndpoint: ParentEndpoint(
                    publicKey: parentConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: 4002
                )
            )
        )
        let outcome = try await childProcess.admit(
            BlockHeader(
                rawCID: childHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            authenticatedChildPackage: AuthenticatedChildPackage(
                package: try response.envelope.makeValidationPackage(),
                acquisitionEntries: response.acquisitionEntries
            )
        )
        XCTAssertTrue(outcome.decision.isAccepted)
        let childStatus = await childProcess.status()
        XCTAssertEqual(childStatus.phase, .active)
    }

    func testCanonicalNetworkMessagesRejectAlternateEncodings() throws {
        let message = BlockAnnouncementMessage(blockCID: "candidate")
        let encoded = try message.encoded()
        XCTAssertEqual(try BlockAnnouncementMessage.decoded(encoded), message)

        var padded = encoded
        padded.append(0x20)
        XCTAssertThrowsError(try BlockAnnouncementMessage.decoded(padded)) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testPlaneLifecycleStartsPrivateFirstAndStopsInReverse() async throws {
        let success = NetworkEventRecorder()
        try await NodeNetworkRuntime.startPlanes(
            startHierarchy: { await success.append("start-hierarchy") },
            startOverlay: { await success.append("start-overlay") },
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        await NodeNetworkRuntime.stopPlanes(
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        let successEvents = await success.snapshot()
        XCTAssertEqual(successEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])

        let failure = NetworkEventRecorder()
        do {
            try await NodeNetworkRuntime.startPlanes(
                startHierarchy: { await failure.append("start-hierarchy") },
                startOverlay: {
                    await failure.append("start-overlay")
                    throw NetworkTestError.failedStart
                },
                stopOverlay: { await failure.append("stop-overlay") },
                stopHierarchy: { await failure.append("stop-hierarchy") }
            )
            XCTFail("expected overlay start failure")
        } catch NetworkTestError.failedStart {}
        let failureEvents = await failure.snapshot()
        XCTAssertEqual(failureEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])
    }

    func testRealNetworkRuntimeStartsStopsAndRestartsBothPlanes() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5b", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration,
            remoteSource: runtime.remoteContentSource
        )

        do {
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }

            var startOutcomes: [NetworkRuntimeStartOutcome] = []
            await withTaskGroup(of: NetworkRuntimeStartOutcome.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await runtime.start(process: process)
                            return .started
                        } catch let error as NodeNetworkRuntimeError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }
                }
                for await outcome in group { startOutcomes.append(outcome) }
            }
            XCTAssertEqual(startOutcomes.filter { $0 == .started }.count, 1)
            XCTAssertEqual(
                startOutcomes.filter { $0 == .failed(.alreadyRunning) }.count,
                1
            )
            try await runtime.canonicalTipDidChange()

            await runtime.stop()
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
            await runtime.stop()

            try await runtime.start(process: process)
            try await runtime.canonicalTipDidChange()
            await runtime.stop()

            let starting = await runtime.enqueueStart(process: process)
            await runtime.stop()
            try await starting.value
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("stop queued during start must leave the runtime stopped")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func envelope(parentPath: [String]) throws -> ChildValidationPackageEnvelope {
        try ChildValidationPackageEnvelope(ChildValidationPackage(
            proof: proof(),
            parentCarrierLink: try carrierLink(
                parentPath: parentPath, carrierCID: "carrier", rootCID: "root"
            ),
            parentGenesisLink: try genesisLink(
                parentPath: parentPath, directory: "Payments", cid: "child-genesis"
            )
        ))
    }

    private func proof() -> ChildBlockProof {
        ChildBlockProof(
            rootCID: "proof-root",
            directoryPath: ["Payments"],
            entries: []
        )
    }

    private func canonicalNetworkBlock() async throws -> Block {
        let process = try await canonicalNetworkProcess()
        return try await process.canonicalTipBlock()
    }

    private func canonicalNetworkProcess() async throws -> ChainProcess {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-block-\(UUID().uuidString)",
            isDirectory: true
        )
        return try await ChainProcess.open(configuration: try NodeConfiguration(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            storagePath: storage,
            privateKeyHex: String(repeating: "5a", count: 32)
        ))
    }

    private func unsignedTransaction(path: [String]) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: path
        )
        return Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
    }

    private func wirePath(encodedContribution: Int) -> [String] {
        // Every component contributes a two-byte length and its UTF-8 bytes.
        // "Nexus" is fixed, and an absolute path needs at least one child.
        var remaining = encodedContribution - 7
        var contributions: [Int] = []
        while remaining > Int(UInt16.max) + 2 {
            contributions.append(Int(UInt16.max) + 2)
            remaining -= Int(UInt16.max) + 2
        }
        if remaining >= 3 {
            contributions.append(remaining)
        } else {
            precondition(!contributions.isEmpty)
            contributions[contributions.count - 1] -= 3 - remaining
            contributions.append(3)
        }
        return ["Nexus"] + contributions.map {
            String(repeating: "x", count: $0 - 2)
        }
    }

    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    private func authenticatedPeer(
        _ key: Curve25519.Signing.PrivateKey,
        role: AuthenticatedPeerRole
    ) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: peerKey(key),
            role: role,
            route: .direct,
            metadata: PeerMetadata()
        )
    }

    private func carrierLink(
        parentPath: [String],
        carrierCID: String,
        rootCID: String
    ) throws -> ParentCarrierLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let carrierCID: String
            let rootCID: String
        }
        return try JSONDecoder().decode(
            ParentCarrierLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                carrierCID: carrierCID,
                rootCID: rootCID
            ))
        )
    }

    private func genesisLink(
        parentPath: [String],
        directory: String,
        cid: String
    ) throws -> ParentGenesisLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let directory: String
            let childGenesisCID: String
        }
        return try JSONDecoder().decode(
            ParentGenesisLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                directory: directory,
                childGenesisCID: cid
            ))
        )
    }
}
