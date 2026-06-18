import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import UInt256

private struct HeaderDataFetcher: Fetcher {
    let dataByCID: [String: Data]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = dataByCID[rawCid] else {
            throw NSError(domain: "HeaderDataFetcher", code: 1)
        }
        return data
    }
}

private actor HeaderStoreRecorder {
    private var stored: [(cid: String, data: Data)] = []

    func store(cid: String, data: Data) {
        stored.append((cid, data))
    }

    func storedCIDs() -> [String] {
        stored.map(\.cid)
    }
}

final class HeaderChainContentAddressingTests: XCTestCase {
    func testAcceptedHeaderCarriesConsensusRetargetMetadata() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: f
        )
        let expectedCID = try VolumeImpl<Block>(node: block).rawCID

        let accepted = try HeaderChain.acceptedHeader(
            expectedCID: expectedCID,
            receivedCID: expectedCID,
            data: block.toData()!
        )

        XCTAssertEqual(accepted.header.nextTarget, block.nextTarget)
        XCTAssertEqual(accepted.header.specCID, block.spec.rawCID)
    }

    func testAcceptedHeaderRejectsBytesThatDoNotHashToExpectedCID() async throws {
        let f = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        let actualCID = try VolumeImpl<Block>(node: block).rawCID
        let forgedCID = "\(actualCID)-forged"

        do {
            _ = try HeaderChain.acceptedHeader(
                expectedCID: forgedCID,
                receivedCID: forgedCID,
                data: block.toData()!
            )
            XCTFail("header acceptance must reject bytes whose canonical CID differs from the expected CID")
        } catch HeaderChain.HeaderChainError.cidMismatch(let expected, let actual) {
            XCTAssertEqual(expected, forgedCID)
            XCTAssertEqual(actual, actualCID)
        } catch {
            XCTFail("expected cidMismatch, got \(error)")
        }
    }

    func testAcceptedHeaderRejectsWrongNextCIDBeforeContentCheck() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: f
        )
        let expectedCID = try VolumeImpl<Block>(node: genesis).rawCID
        let receivedCID = try VolumeImpl<Block>(node: block).rawCID

        do {
            _ = try HeaderChain.acceptedHeader(
                expectedCID: expectedCID,
                receivedCID: receivedCID,
                data: block.toData()!
            )
            XCTFail("bulk header acceptance must reject tuples that are not the next expected CID")
        } catch HeaderChain.HeaderChainError.chainContinuityBroken(let expected, let got) {
            XCTAssertEqual(expected, expectedCID)
            XCTAssertEqual(got, receivedCID)
        } catch {
            XCTFail("expected chainContinuityBroken, got \(error)")
        }
    }

    func testAcceptedHeaderPreservesConsensusFields() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max - UInt256(1),
            nonce: 1,
            fetcher: f
        )
        let cid = try VolumeImpl<Block>(node: block).rawCID

        let accepted = try HeaderChain.acceptedHeader(
            expectedCID: cid,
            receivedCID: cid,
            data: block.toData()!
        )

        XCTAssertEqual(accepted.header.nextTarget, block.nextTarget)
        XCTAssertEqual(accepted.header.specCID, block.spec.rawCID)
        XCTAssertNil(accepted.header.spec, "block-byte headers carry the spec CID, not recursive spec bytes")
    }

    func testHeadersFirstSyncInheritsMissingSpecCIDBeforeConsensusValidation() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let genesisCID = try VolumeImpl<Block>(node: genesis).rawCID

        let block = try await buildRetargetedTestBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            nonce: 1,
            fetcher: f
        )
        try await storeBlockFixture(block, to: f)
        let blockCID = try VolumeImpl<Block>(node: block).rawCID
        let accepted = try HeaderChain.acceptedHeader(
            expectedCID: blockCID,
            receivedCID: blockCID,
            data: block.toData()!
        )
        let missingSpecHeader = headerReplacingSpecCID(accepted.header, specCID: nil)

        let headers = HeaderChain.headersByInheritingMissingSpecCIDs(
            [missingSpecHeader],
            initialSpecCID: genesis.spec.rawCID
        )
        XCTAssertEqual(headers.first?.specCID, genesis.spec.rawCID)

        let syncer = ChainSyncer(
            fetcher: f,
            store: { _, _ in },
            genesisBlockHash: genesisCID,
            validateBlockConsensus: true
        )
        let result = try await syncer.syncFromHeaders(headers, cumulativeWork: .zero)

        XCTAssertEqual(result.tipBlockHash, blockCID)
        XCTAssertEqual(result.tipBlockHeight, block.height)
    }

    func testHeadersFirstSyncRejectsWrongSpecCID() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        try await storeBlockFixture(genesis, to: f)
        let genesisCID = try VolumeImpl<Block>(node: genesis).rawCID

        let block = try await buildRetargetedTestBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            nonce: 1,
            fetcher: f
        )
        try await storeBlockFixture(block, to: f)
        let blockCID = try VolumeImpl<Block>(node: block).rawCID
        let accepted = try HeaderChain.acceptedHeader(
            expectedCID: blockCID,
            receivedCID: blockCID,
            data: block.toData()!
        )
        let wrongSpecHeader = headerReplacingSpecCID(
            accepted.header,
            specCID: "\(genesis.spec.rawCID)-wrong"
        )

        let headers = HeaderChain.headersByInheritingMissingSpecCIDs(
            [wrongSpecHeader],
            initialSpecCID: genesis.spec.rawCID
        )
        XCTAssertEqual(headers.first?.specCID, "\(genesis.spec.rawCID)-wrong")

        let syncer = ChainSyncer(
            fetcher: f,
            store: { _, _ in },
            genesisBlockHash: genesisCID,
            validateBlockConsensus: true
        )
        do {
            _ = try await syncer.syncFromHeaders(headers, cumulativeWork: .zero)
            XCTFail("explicit wrong specCID must fail closed instead of being inherited over")
        } catch SyncError.invalidBlock(let height) {
            XCTAssertEqual(height, block.height)
        } catch {
            XCTFail("expected invalidBlock(\(block.height)), got \(error)")
        }
    }

    func testSequentialDownloadRejectsFetchedBytesForDifferentCID() async throws {
        let f = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        let actualCID = try VolumeImpl<Block>(node: block).rawCID
        let forgedCID = "\(actualCID)-forged"
        let fetcher = HeaderDataFetcher(dataByCID: [forgedCID: block.toData()!])
        let headerChain = HeaderChain()

        do {
            _ = try await headerChain.downloadHeaders(
                peerTipCID: forgedCID,
                fetcher: fetcher,
                genesisBlockHash: actualCID,
                localWork: .zero
            )
            XCTFail("sequential header sync must reject bytes that do not hash to the requested CID")
        } catch HeaderChain.HeaderChainError.cidMismatch(let expected, let actual) {
            XCTAssertEqual(expected, forgedCID)
            XCTAssertEqual(actual, actualCID)
        } catch {
            XCTFail("expected cidMismatch, got \(error)")
        }
    }

    func testBulkHeaderBatchDoesNotStoreBytesUnderMismatchedCID() async throws {
        let f = cas()
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: f
        )
        let actualCID = try VolumeImpl<Block>(node: block).rawCID
        let forgedCID = "\(actualCID)-forged"
        let headerChain = HeaderChain()
        let recorder = HeaderStoreRecorder()

        do {
            _ = try await headerChain.acceptHeaderBatch(
                [(cid: forgedCID, data: block.toData()!)],
                startingAt: forgedCID,
                totalHeight: block.height,
                genesisBlockHash: actualCID,
                knownBlockCIDs: [],
                store: { cid, data in
                    await recorder.store(cid: cid, data: data)
                }
            )
            XCTFail("bulk header sync must reject bytes that do not hash to the tuple CID")
        } catch HeaderChain.HeaderChainError.cidMismatch(let expected, let actual) {
            XCTAssertEqual(expected, forgedCID)
            XCTAssertEqual(actual, actualCID)
        } catch {
            XCTFail("expected cidMismatch, got \(error)")
        }

        let storedCIDs = await recorder.storedCIDs()
        XCTAssertTrue(storedCIDs.isEmpty, "bulk header sync must not store bytes under a mismatched CID")
    }

    func testBulkHeaderBatchDoesNotStoreUnexpectedNextCID() async throws {
        let f = cas()
        let timestamp = now() - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            nonce: 1,
            fetcher: f
        )
        let expectedCID = try VolumeImpl<Block>(node: genesis).rawCID
        let receivedCID = try VolumeImpl<Block>(node: block).rawCID
        let headerChain = HeaderChain()
        let recorder = HeaderStoreRecorder()

        do {
            _ = try await headerChain.acceptHeaderBatch(
                [(cid: receivedCID, data: block.toData()!)],
                startingAt: expectedCID,
                totalHeight: block.height,
                genesisBlockHash: expectedCID,
                knownBlockCIDs: [],
                store: { cid, data in
                    await recorder.store(cid: cid, data: data)
                }
            )
            XCTFail("bulk header sync must reject a tuple that is not the next expected CID")
        } catch HeaderChain.HeaderChainError.chainContinuityBroken(let expected, let got) {
            XCTAssertEqual(expected, expectedCID)
            XCTAssertEqual(got, receivedCID)
        } catch {
            XCTFail("expected chainContinuityBroken, got \(error)")
        }

        let storedCIDs = await recorder.storedCIDs()
        XCTAssertTrue(storedCIDs.isEmpty, "bulk header sync must not store an unexpected next CID")
    }

    private func headerReplacingSpecCID(_ header: SyncBlockHeader, specCID: String?) -> SyncBlockHeader {
        SyncBlockHeader(
            cid: header.cid,
            height: header.height,
            previousBlockCID: header.previousBlockCID,
            target: header.target,
            nextTarget: header.nextTarget,
            timestamp: header.timestamp,
            specCID: specCID,
            spec: header.spec
        )
    }
}
