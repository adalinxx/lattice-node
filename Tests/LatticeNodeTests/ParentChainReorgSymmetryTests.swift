import XCTest
@testable import LatticeNode

final class ParentChainExtractorStorageTests: XCTestCase {
    func testParentExtractorHoistsParentFetcherBroker() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LatticeNode/Network/ParentChainBlockExtractor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let parentFetcherBroker = MemoryBroker(capacity: 512)"))
        XCTAssertFalse(source.contains("IvyFetcher(ivy: ivy, broker: MemoryBroker(capacity: 512))"))
    }
}
